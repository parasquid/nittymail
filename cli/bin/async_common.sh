#!/bin/bash

# NittyMail Async Job Queue Common Library
# Shared functionality for download_async.sh and archive_async.sh

# Generate random sleep time between min and max seconds
random_sleep() {
    local min=$1
    local max=$2
    local range=$((max - min + 1))
    local random_value=$((RANDOM % range + min))
    sleep "$random_value"
}

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

    debug "Initializing queue state with $total_batches batches ($total_uids UIDs)"
    debug "Writing to $QUEUE_DIR/queue_state.json"

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

    debug "Queue state file written, size: $(wc -c < "$QUEUE_DIR/queue_state.json") bytes"
    debug "Initialized queue state with $total_batches batches ($total_uids UIDs)"
}

# Update queue state with file locking
update_queue_state() {
    local delta_completed_batches=$1
    local delta_completed_uids=$2
    local delta_processing_batches=$3
    local delta_workers_active=$4

    local lock_file="$QUEUE_DIR/queue_state.lock"
    local max_attempts=10
    local attempt=1

    # Acquire lock with retry
    while [ $attempt -le $max_attempts ]; do
        if (set -o noclobber; echo "$$" > "$lock_file") 2>/dev/null; then
            break
        fi
        debug "Waiting for queue state lock (attempt $attempt/$max_attempts)"
        random_sleep 1 3  # Random backoff between 1-3 seconds
        attempt=$((attempt + 1))
    done

    if [ $attempt -gt $max_attempts ]; then
        echo "ERROR: Could not acquire queue state lock after $max_attempts attempts"
        return 1
    fi

    # Ensure cleanup on exit
    trap "rm -f '$lock_file'" EXIT

    # Read current values inside lock
    local current_completed=$(jq -r '.completed_batches' "$QUEUE_DIR/queue_state.json" 2>/dev/null || echo "0")
    local current_completed_uids=$(jq -r '.completed_uids' "$QUEUE_DIR/queue_state.json" 2>/dev/null || echo "0")
    local current_processing=$(jq -r '.processing_batches' "$QUEUE_DIR/queue_state.json" 2>/dev/null || echo "0")
    local current_workers=$(jq -r '.workers_active' "$QUEUE_DIR/queue_state.json" 2>/dev/null || echo "0")

    local pending_batches=$(( $(ls "$QUEUE_DIR/pending"/*.job 2>/dev/null | wc -l) ))

    # Check if queue_state.json exists and is readable
    if [ ! -f "$QUEUE_DIR/queue_state.json" ]; then
        echo "ERROR: queue_state.json does not exist!"
        rm -f "$lock_file"
        return 1
    fi

    if [ ! -s "$QUEUE_DIR/queue_state.json" ]; then
        echo "ERROR: queue_state.json is empty!"
        rm -f "$lock_file"
        return 1
    fi

    # Calculate new values
    local new_completed=$((current_completed + delta_completed_batches))
    local new_completed_uids=$((current_completed_uids + delta_completed_uids))
    local new_processing=$((current_processing + delta_processing_batches))
    local new_workers=$((current_workers + delta_workers_active))

    # Calculate progress
    local total_batches=$(jq -r '.total_batches' "$QUEUE_DIR/queue_state.json" 2>/dev/null)
    local total_uids=$(jq -r '.total_uids' "$QUEUE_DIR/queue_state.json" 2>/dev/null)

    if [ -z "$total_batches" ] || [ "$total_batches" = "null" ]; then
        echo "ERROR: Could not read total_batches from JSON"
        rm -f "$lock_file"
        return 1
    fi

    # Update state file atomically
    if jq --arg cb "$new_completed" \
           --arg cu "$new_completed_uids" \
           --arg pb "$pending_batches" \
           --arg prb "$new_processing" \
           --arg wa "$new_workers" \
           '.completed_batches = ($cb | tonumber) |
            .completed_uids = ($cu | tonumber) |
            .pending_batches = ($pb | tonumber) |
            .processing_batches = ($prb | tonumber) |
            .workers_active = ($wa | tonumber)' \
           "$QUEUE_DIR/queue_state.json" > "$QUEUE_DIR/queue_state.new" 2>/dev/null; then

        mv "$QUEUE_DIR/queue_state.new" "$QUEUE_DIR/queue_state.json"
    else
        echo "ERROR: Failed to update queue state with jq"
        rm -f "$lock_file"
        return 1
    fi

    # Release lock
    rm -f "$lock_file"

    debug "Updated queue state: completed=$new_completed (+$delta_completed_batches), pending=$pending_batches, processing=$new_processing (+$delta_processing_batches), workers=$new_workers (+$delta_workers_active)"
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

        # Small random delay to prevent overwhelming the filesystem
        if [ $((batch_index % 100)) -eq 0 ]; then
            random_sleep 0 1  # Random backoff between 0-1 seconds
        fi
    done

    local total_batches=$((batch_index - 1))
    echo "$total_batches"
}

# Worker function to process jobs
worker_process() {
    local worker_id=$1
    local mailbox_args=("${@:2}")
    local worker_started=false

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

            # Random delay before retrying to prevent thundering herd
            random_sleep 0 1  # Random backoff between 0-1 seconds
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
        if [ "$worker_started" = "false" ]; then
            update_queue_state 0 0 1 1
            worker_started=true
        else
            update_queue_state 0 0 1 0
        fi

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
            update_queue_state 0 0 -1 0
            # Move to a failed directory for manual inspection
            mkdir -p "$QUEUE_DIR/failed"
            mv "$processing_file" "$QUEUE_DIR/failed/${batch_id}.job"
            continue
        else
            # Process the batch
            if process_batch "$uids" "$uidvalidity" "${mailbox_args[@]}"; then
                debug "Worker $worker_id completed $batch_id"
                # Update queue state for completed job
                update_queue_state 1 "$uid_count" -1 0
                # Delete completed job file
                rm "$processing_file"
            else
                debug "Worker $worker_id failed $batch_id (attempt $((retry_count + 1))/$max_retries)"
                # Update queue state for failed job (back to pending)
                update_queue_state 0 0 -1 0
                # Move back to pending for retry and increment retry count
                jq '.retry_count += 1' "$processing_file" > "${QUEUE_DIR}/pending/${batch_id}.job.tmp" && \
                mv "${QUEUE_DIR}/pending/${batch_id}.job.tmp" "$QUEUE_DIR/pending/${batch_id}.job" && \
                rm "$processing_file"
            fi
        fi
    done

    # Update queue state when worker finishes
    update_queue_state 0 0 0 -1
    debug "Worker $worker_id finished"
}

# Monitor and display progress
monitor_progress() {
    local start_time=$1

    while true; do
        if [ ! -f "$QUEUE_DIR/queue_state.json" ]; then
            break
        fi

        local completed=$(jq -r '.completed_batches' "$QUEUE_DIR/queue_state.json" 2>/dev/null || echo "0")
        local total=$(jq -r '.total_batches' "$QUEUE_DIR/queue_state.json" 2>/dev/null || echo "0")
        local processing=$(jq -r '.processing_batches' "$QUEUE_DIR/queue_state.json" 2>/dev/null || echo "0")
        local workers=$(jq -r '.workers_active' "$QUEUE_DIR/queue_state.json" 2>/dev/null || echo "0")

        local elapsed=$(( $(date +%s) - $(date -d "$start_time" +%s) ))

        # Prevent division by zero
        if [ "$total" -gt 0 ] 2>/dev/null; then
            local progress=$(( completed * 100 / total ))
        else
            local progress=0
        fi

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

# Common main function logic
main_common() {
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
        echo "Starting async job queue $OPERATION_TYPE..."
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
        local preflight_result
        preflight_result=$(get_uids_from_preflight "${mailbox_args[@]}")

        # Split the result into UIDs and UIDVALIDITY
        local all_uids=$(echo "$preflight_result" | cut -d'|' -f1)
        local uidvalidity=$(echo "$preflight_result" | cut -d'|' -f2)

        if [ -z "$all_uids" ] || [ "$all_uids" = "no UIDs found" ]; then
            echo "No UIDs available for $OPERATION_TYPE."
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
        echo "$OPERATION_TYPE complete!"

        # Wait for any remaining locks to be released
        local lock_file="$QUEUE_DIR/queue_state.lock"
        local wait_count=0
        while [ -f "$lock_file" ] && [ $wait_count -lt 50 ]; do
            random_sleep 0 1  # Random backoff between 0-1 seconds
            wait_count=$((wait_count + 1))
        done

        # Read final stats safely
        local completed_batches=$(jq -r '.completed_batches' "$QUEUE_DIR/queue_state.json" 2>/dev/null || echo "0")
        local total_batches=$(jq -r '.total_batches' "$QUEUE_DIR/queue_state.json" 2>/dev/null || echo "0")
        echo "Final stats: $completed_batches/$total_batches batches completed"

        if [ "$failed_jobs" -gt 0 ]; then
            echo "Warning: $failed_jobs jobs failed after maximum retries."
            echo "Failed jobs are saved in: $QUEUE_DIR/failed/"
        fi

        # Clean up queue
        cleanup_queue
    else
        echo "$OPERATION_TYPE incomplete."
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