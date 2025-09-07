#!/bin/bash

# NittyMail Async Job Queue Archive Script
# Processes email UIDs using an async job queue for continuous streaming
# No waiting for batches - workers process jobs as soon as they're available

set -e  # Exit on any error

# Configuration
MAX_WORKERS=5
BATCH_SIZE=50  # UIDs per job
QUEUE_DIR="./archive_queue"
DOCKER_COMPOSE_CMD="docker compose run --rm -T cli"
DEBUG=false

# Debug function
debug() {
    if [ "$DEBUG" = "true" ]; then
        echo "DEBUG: $*" >&2
    fi
}

# Create queue directory structure
setup_queue_dirs() {
    mkdir -p "$QUEUE_DIR/pending"
    mkdir -p "$QUEUE_DIR/processing"
    mkdir -p "$QUEUE_DIR/failed"

    debug "Created queue directories: $QUEUE_DIR/{pending,processing,failed}"
}

# Clean up queue directories
cleanup_queue() {
    if [ -d "$QUEUE_DIR" ]; then
        # Only remove pending and processing directories, keep failed jobs for inspection
        rm -rf "$QUEUE_DIR/pending" "$QUEUE_DIR/processing" "$QUEUE_DIR/queue_state.json"
        # Remove the directory if it's now empty
        if [ -z "$(ls -A "$QUEUE_DIR" 2>/dev/null)" ]; then
            rm -rf "$QUEUE_DIR"
        fi
        debug "Cleaned up queue directories (preserved failed jobs)"
    fi
}

# Initialize queue state
init_queue_state() {
    local total_uids=$1
    local total_batches=$2

    cat > "$QUEUE_DIR/queue_state.json" << EOF
{
  "total_batches": $total_batches,
  "total_uids": $total_uids,
  "completed_batches": 0,
  "completed_uids": 0,
  "pending_batches": $total_batches,
  "processing_batches": 0,
  "start_time": "$(date -Iseconds)",
  "workers_active": 0,
  "workers_total": $MAX_WORKERS,
  "status": "running"
}
EOF

    debug "Initialized queue state with $total_batches batches ($total_uids UIDs)"
}

# Update queue state
update_queue_state() {
    local completed_batches=$1
    local completed_uids=$2
    local processing_batches=$3
    local workers_active=$4

    local pending_batches=$(( $(ls "$QUEUE_DIR/pending"/*.job 2>/dev/null | wc -l) ))

    # Calculate progress
    local total_batches=$(jq -r '.total_batches' "$QUEUE_DIR/queue_state.json")
    local total_uids=$(jq -r '.total_uids' "$QUEUE_DIR/queue_state.json")

    # Update state file
    jq --arg cb "$completed_batches" \
       --arg cu "$completed_uids" \
       --arg pb "$pending_batches" \
       --arg prb "$processing_batches" \
       --arg wa "$workers_active" \
       '.completed_batches = ($cb | tonumber) |
        .completed_uids = ($cu | tonumber) |
        .pending_batches = ($pb | tonumber) |
        .processing_batches = ($prb | tonumber) |
        .workers_active = ($wa | tonumber)' \
       "$QUEUE_DIR/queue_state.json" > "$QUEUE_DIR/queue_state.tmp" && \
    mv "$QUEUE_DIR/queue_state.tmp" "$QUEUE_DIR/queue_state.json"

    debug "Updated queue state: completed=$completed_batches, pending=$pending_batches, processing=$processing_batches, workers=$workers_active"
}

# Create a job file for a batch of UIDs
create_job() {
    local batch_id=$1
    local uids=$2
    local uid_count=$3
    local uidvalidity=$4

    local job_file="$QUEUE_DIR/pending/${batch_id}.job"

    cat > "$job_file" << EOF
{
  "batch_id": "$batch_id",
  "uids": "$uids",
  "uid_count": $uid_count,
  "uidvalidity": "$uidvalidity",
  "created_at": "$(date -Iseconds)",
  "worker_pid": null,
  "started_at": null,
  "retry_count": 0
}
EOF

    # Ensure file is written to disk
    sync "$job_file" 2>/dev/null || true

    debug "Created job: $batch_id with $uid_count UIDs (UIDVALIDITY=$uidvalidity)"
}

# Get UIDs from preflight
get_uids_from_preflight() {
    local output
    local cmd_result

    debug "Running preflight command: $DOCKER_COMPOSE_CMD mailbox archive --only-preflight --output ./archives $@"

    if [ "$DEBUG" = "true" ]; then
        output=$($DOCKER_COMPOSE_CMD mailbox archive --only-preflight --output ./archives "$@" 2>&1)
    else
        output=$($DOCKER_COMPOSE_CMD mailbox archive --only-preflight --output ./archives "$@" 2>/dev/null)
    fi
    cmd_result=$?

    if [ $cmd_result -ne 0 ]; then
        echo "Error: Preflight command failed" >&2
        return 1
    fi

    local uids_line
    uids_line=$(echo "$output" | grep "^UIDs:" | sed 's/UIDs: //' | tr -d ' ')

    local uidvalidity_line
    uidvalidity_line=$(echo "$output" | grep "^UIDVALIDITY=" | sed 's/UIDVALIDITY=//' | tr -d ' ')

    debug "Extracted UIDs: $uids_line"
    debug "Extracted UIDVALIDITY: $uidvalidity_line"

    # Return both values separated by a delimiter
    echo "${uids_line}|${uidvalidity_line}"
}

# Split UIDs into batches and create jobs
create_jobs_from_uids() {
    local all_uids=$1
    local uidvalidity=$2
    local batch_index=1

    # Convert to array
    IFS=',' read -ra UID_ARRAY <<< "$all_uids"
    local total_uids=${#UID_ARRAY[@]}

    debug "Creating jobs from $total_uids UIDs in batches of $BATCH_SIZE (UIDVALIDITY=$uidvalidity)"

    local i=0
    while [ $i -lt $total_uids ]; do
        local batch_uids=()
        local batch_count=0

        # Collect UIDs for this batch
        while [ $batch_count -lt $BATCH_SIZE ] && [ $i -lt $total_uids ]; do
            batch_uids+=("${UID_ARRAY[$i]}")
            batch_count=$((batch_count + 1))
            i=$((i + 1))
        done

        # Create job for this batch
        local batch_id=$(printf "batch_%04d" $batch_index)
        local uids_string=$(IFS=','; echo "${batch_uids[*]}")

        create_job "$batch_id" "$uids_string" "$batch_count" "$uidvalidity"
        batch_index=$((batch_index + 1))

        # Small delay to prevent overwhelming the filesystem
        if [ $((batch_index % 100)) -eq 0 ]; then
            sleep 0.01
        fi
    done

    local total_batches=$((batch_index - 1))
    echo "$total_batches"
}

# Worker function to process jobs
worker_process() {
    local worker_id=$1
    local mailbox_args=("${@:2}")

    debug "Worker $worker_id started"

    while true; do
        # Find next pending job with retry logic to handle race conditions
        local job_file=""
        local retry_count=0
        local max_retries=10

        while [ $retry_count -lt $max_retries ]; do
            job_file=$(find "$QUEUE_DIR/pending" -name "*.job" | head -1)

            if [ -n "$job_file" ]; then
                break
            fi

            # Small delay before retrying
            sleep 0.1
            retry_count=$((retry_count + 1))
        done

        if [ -z "$job_file" ]; then
            debug "Worker $worker_id: No more jobs available after $max_retries retries"
            break
        fi

        local batch_id=$(basename "$job_file" .job)

        # Move job to processing with error handling
        local processing_file="$QUEUE_DIR/processing/${batch_id}.job"
        if ! mv "$job_file" "$processing_file" 2>/dev/null; then
            debug "Worker $worker_id: Failed to move $batch_id to processing (likely grabbed by another worker)"
            continue
        fi

        # Update queue state for job moved to processing
        local current_processing=$(jq -r '.processing_batches' "$QUEUE_DIR/queue_state.json")
        local current_workers=$(jq -r '.workers_active' "$QUEUE_DIR/queue_state.json")
        update_queue_state 0 0 $((current_processing + 1)) $((current_workers + 1))

        # Update job with worker info
        jq --arg pid "$$" --arg started "$(date -Iseconds)" \
           '.worker_pid = ($pid | tonumber) | .started_at = $started' \
           "$processing_file" > "${processing_file}.tmp" && \
        mv "${processing_file}.tmp" "$processing_file"

        debug "Worker $worker_id processing $batch_id"

        # Extract UIDs from job
        local uids=$(jq -r '.uids' "$processing_file")
        local uid_count=$(jq -r '.uid_count' "$processing_file")
        local retry_count=$(jq -r '.retry_count' "$processing_file")
        local uidvalidity=$(jq -r '.uidvalidity' "$processing_file")

        # Check if job has been retried too many times
        if [ "$retry_count" -ge "$max_retries" ]; then
            echo "Worker $worker_id: Job $batch_id has failed $retry_count times, giving up"
            # Update queue state for permanently failed job
            local current_processing=$(jq -r '.processing_batches' "$QUEUE_DIR/queue_state.json")
            update_queue_state 0 0 $((current_processing - 1)) 0
            # Move to a failed directory for manual inspection
            mkdir -p "$QUEUE_DIR/failed"
            mv "$processing_file" "$QUEUE_DIR/failed/${batch_id}.job"
            continue
        else
            # Process the batch
            if process_batch "$uids" "$uidvalidity" "${mailbox_args[@]}"; then
                debug "Worker $worker_id completed $batch_id"
                # Update queue state for completed job
                local current_completed=$(jq -r '.completed_batches' "$QUEUE_DIR/queue_state.json")
                local current_completed_uids=$(jq -r '.completed_uids' "$QUEUE_DIR/queue_state.json")
                update_queue_state $((current_completed + 1)) $((current_completed_uids + uid_count)) 0 0
                # Delete completed job file
                rm "$processing_file"
            else
                debug "Worker $worker_id failed $batch_id (attempt $((retry_count + 1))/$max_retries)"
                # Update queue state for failed job (back to pending)
                local current_processing=$(jq -r '.processing_batches' "$QUEUE_DIR/queue_state.json")
                update_queue_state 0 0 $((current_processing - 1)) 0
                # Move back to pending for retry and increment retry count
                jq '.retry_count += 1' "$processing_file" > "${QUEUE_DIR}/pending/${batch_id}.job.tmp" && \
                mv "${QUEUE_DIR}/pending/${batch_id}.job.tmp" "$QUEUE_DIR/pending/${batch_id}.job" && \
                rm "$processing_file"
            fi
        fi
    done

    # Update queue state when worker finishes
    local current_workers=$(jq -r '.workers_active' "$QUEUE_DIR/queue_state.json")
    if [ "$current_workers" -gt 0 ]; then
        update_queue_state 0 0 0 $((current_workers - 1))
    fi
    debug "Worker $worker_id finished"
}

# Process a batch of UIDs
process_batch() {
    local uids=$1
    local uidvalidity=$2
    shift 2
    local mailbox_args=("$@")

    debug "Processing batch with UIDs: $uids (UIDVALIDITY=$uidvalidity)"

    # Run the archive command with pre-known UIDVALIDITY to avoid IMAP lookup
    if [ "$DEBUG" = "true" ]; then
        $DOCKER_COMPOSE_CMD mailbox archive --only-ids "$uids" --uidvalidity "$uidvalidity" --yes --output ./archives "${mailbox_args[@]}" 2>&1
        return $?
    else
        $DOCKER_COMPOSE_CMD mailbox archive --only-ids "$uids" --uidvalidity "$uidvalidity" --yes --output ./archives "${mailbox_args[@]}" >/dev/null 2>&1
        return $?
    fi
}

# Monitor and display progress
monitor_progress() {
    local start_time=$1

    while true; do
        if [ ! -f "$QUEUE_DIR/queue_state.json" ]; then
            break
        fi

        local completed=$(jq -r '.completed_batches' "$QUEUE_DIR/queue_state.json")
        local total=$(jq -r '.total_batches' "$QUEUE_DIR/queue_state.json")
        local processing=$(jq -r '.processing_batches' "$QUEUE_DIR/queue_state.json")
        local workers=$(jq -r '.workers_active' "$QUEUE_DIR/queue_state.json")

        local elapsed=$(( $(date +%s) - $(date -d "$start_time" +%s) ))
        local progress=$(( completed * 100 / total ))

        echo -ne "\rProgress: $completed/$total batches ($progress%) | Workers: $workers | Processing: $processing | Elapsed: ${elapsed}s"

        sleep 2
    done
    echo ""  # New line after progress
}

# Cleanup function for interruptions
cleanup_interrupt() {
    echo -e "\nReceived interrupt signal. Cleaning up..."

    # Kill all worker processes
    if [ -d "$QUEUE_DIR/processing" ]; then
        for job_file in "$QUEUE_DIR/processing"/*.job; do
            if [ -f "$job_file" ]; then
                local worker_pid=$(jq -r '.worker_pid' "$job_file")
                if [ "$worker_pid" != "null" ] && kill -0 "$worker_pid" 2>/dev/null; then
                    debug "Killing worker process $worker_pid"
                    kill "$worker_pid" 2>/dev/null || true
                fi
                # Move job back to pending
                local batch_id=$(basename "$job_file" .job)
                mv "$job_file" "$QUEUE_DIR/pending/${batch_id}.job"
            fi
        done
    fi

    # Update state to interrupted
    if [ -f "$QUEUE_DIR/queue_state.json" ]; then
        jq '.status = "interrupted"' "$QUEUE_DIR/queue_state.json" > "$QUEUE_DIR/queue_state.tmp" && \
        mv "$QUEUE_DIR/queue_state.tmp" "$QUEUE_DIR/queue_state.json"
    fi

    echo "Cleanup complete. You can resume with: $0 --resume"
    exit 1
}

# Main function
main() {
    local mailbox_args=()
    local resume_mode=false

    # Set up signal handlers
    trap cleanup_interrupt INT TERM HUP

    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --debug)
                DEBUG=true
                shift
                ;;
            --resume)
                resume_mode=true
                shift
                ;;
            --cleanup)
                cleanup_queue
                echo "Queue cleaned up."
                exit 0
                ;;
            --)
                shift
                mailbox_args=("$@")
                break
                ;;
            *)
                echo "Usage: $0 [--debug] [--resume] [--cleanup] [-- <mailbox arguments>]"
                echo "Examples:"
                echo "  $0 -- --mailbox INBOX"
                echo "  $0 --debug -- --mailbox '[Gmail]/All Mail'"
                echo "  $0 --resume  # Resume after interruption"
                echo "  $0 --cleanup # Clean up queue"
                exit 1
                ;;
        esac
    done

    if [ "$resume_mode" = "true" ]; then
        if [ ! -d "$QUEUE_DIR" ]; then
            echo "Error: No queue directory found to resume from."
            exit 1
        fi
        echo "Resuming from previous session..."

        # Clean up any jobs stuck in processing from previous interruption
        if [ -d "$QUEUE_DIR/processing" ]; then
            local stuck_jobs=$(ls "$QUEUE_DIR/processing"/*.job 2>/dev/null | wc -l)
            if [ "$stuck_jobs" -gt 0 ]; then
                echo "Found $stuck_jobs jobs stuck in processing. Moving back to pending..."
                for job_file in "$QUEUE_DIR/processing"/*.job; do
                    if [ -f "$job_file" ]; then
                        local batch_id=$(basename "$job_file" .job)
                        mv "$job_file" "$QUEUE_DIR/pending/${batch_id}.job"
                        debug "Moved stuck job $batch_id back to pending"
                    fi
                done
            fi
        fi

        # Verify there are jobs to process
        local pending_jobs=$(ls "$QUEUE_DIR/pending"/*.job 2>/dev/null | wc -l)
        if [ "$pending_jobs" -eq 0 ]; then
            echo "No pending jobs found to resume. All jobs may have been completed."
            echo "If you want to start fresh, run without --resume flag."
            cleanup_queue
            exit 0
        fi

        echo "Found $pending_jobs pending jobs to resume."

        # Show current progress if state file exists
        if [ -f "$QUEUE_DIR/queue_state.json" ]; then
            local completed=$(jq -r '.completed_batches' "$QUEUE_DIR/queue_state.json")
            local total=$(jq -r '.total_batches' "$QUEUE_DIR/queue_state.json")
            local progress=$(( completed * 100 / total ))
            echo "Progress: $completed/$total batches completed ($progress%)"
        fi
    else
        echo "Starting async job queue email archiving..."
        echo "Max workers: $MAX_WORKERS"
        echo "Batch size: $BATCH_SIZE"
        echo "Mailbox args: ${mailbox_args[*]}"
        echo

        # Check for existing queue and clean it for fresh start
        if [ -d "$QUEUE_DIR" ]; then
            local existing_jobs=$(ls "$QUEUE_DIR/pending"/*.job 2>/dev/null | wc -l)
            if [ "$existing_jobs" -gt 0 ]; then
                echo "Found $existing_jobs existing jobs from previous run. Clearing for fresh start..."
            fi
        fi

        # Set up queue
        cleanup_queue  # Clean any existing queue
        setup_queue_dirs

        # Get UIDs from preflight
        echo "Running preflight to discover UIDs..."
        local all_uids
        # Filter out --only-preflight from mailbox args since we add it in get_uids_from_preflight
        local filtered_args=()
        for arg in "${mailbox_args[@]}"; do
            if [ "$arg" != "--only-preflight" ]; then
                filtered_args+=("$arg")
            fi
        done
        local preflight_result
        preflight_result=$(get_uids_from_preflight "${filtered_args[@]}")

        # Split the result into UIDs and UIDVALIDITY
        local all_uids=$(echo "$preflight_result" | cut -d'|' -f1)
        local uidvalidity=$(echo "$preflight_result" | cut -d'|' -f2)

        if [ -z "$all_uids" ] || [ "$all_uids" = "no UIDs found" ]; then
            echo "No UIDs available for archiving."
            cleanup_queue
            return
        fi

        debug "Preflight result: UIDs=$all_uids, UIDVALIDITY=$uidvalidity"

        # Create jobs from UIDs
        echo "Creating job queue..."
        local total_batches
        total_batches=$(create_jobs_from_uids "$all_uids" "$uidvalidity")

        # Initialize state
        local total_uids=$(echo "$all_uids" | tr ',' '\n' | wc -l)
        init_queue_state "$total_uids" "$total_batches"

        echo "Created $total_batches batches for $total_uids UIDs"

        # Ensure all job files are written and synced to disk before starting workers
        sync
        local expected_jobs=$total_batches
        local actual_jobs=$(ls "$QUEUE_DIR/pending"/*.job 2>/dev/null | wc -l)

        echo "Verifying job creation: expected $expected_jobs, found $actual_jobs"
        if [ "$actual_jobs" -ne "$expected_jobs" ]; then
            echo "Error: Job creation failed. Expected $expected_jobs jobs, found $actual_jobs."
            cleanup_queue
            exit 1
        fi

        echo "Job queue ready. Starting workers..."
    fi

    # Start progress monitoring in background
    local start_time=$(date -Iseconds)
    monitor_progress "$start_time" &
    local monitor_pid=$!

    # Start worker pool
    local worker_pids=()
    local worker_id=1

    echo "Starting $MAX_WORKERS workers..."
    while [ $worker_id -le $MAX_WORKERS ]; do
        worker_process "$worker_id" "${mailbox_args[@]}" &
        worker_pids+=($!)
        worker_id=$((worker_id + 1))
    done

    # Wait for all workers to complete
    local failed_workers=0
    for pid in "${worker_pids[@]}"; do
        if ! wait "$pid"; then
            failed_workers=$((failed_workers + 1))
        fi
    done

    # Stop progress monitoring
    kill "$monitor_pid" 2>/dev/null || true
    wait "$monitor_pid" 2>/dev/null || true

    # Check if all jobs completed
    local remaining_jobs=$(ls "$QUEUE_DIR/pending"/*.job 2>/dev/null | wc -l)
    local processing_jobs=$(ls "$QUEUE_DIR/processing"/*.job 2>/dev/null | wc -l)
    local failed_jobs=$(ls "$QUEUE_DIR/failed"/*.job 2>/dev/null | wc -l)

    if [ "$remaining_jobs" -eq 0 ] && [ "$processing_jobs" -eq 0 ]; then
        echo "Archiving complete!"
        local final_state=$(cat "$QUEUE_DIR/queue_state.json")
        echo "Final stats: $(echo "$final_state" | jq -r '.completed_batches')/$(echo "$final_state" | jq -r '.total_batches') batches completed"

        if [ "$failed_jobs" -gt 0 ]; then
            echo "Warning: $failed_jobs jobs failed after maximum retries."
            echo "Failed jobs are saved in: $QUEUE_DIR/failed/"
        fi

        # Clean up queue
        cleanup_queue
    else
        echo "Archiving incomplete."
        echo "  - $remaining_jobs jobs remaining"
        echo "  - $processing_jobs jobs in progress"
        if [ "$failed_jobs" -gt 0 ]; then
            echo "  - $failed_jobs jobs failed"
        fi
        echo "You can resume with: $0 --resume"
    fi

    if [ $failed_workers -gt 0 ]; then
        echo "Warning: $failed_workers workers failed."
    fi
}

# Run main function
main "$@"
