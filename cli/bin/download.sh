#!/bin/bash

# NittyMail Parallel Download Script
# This script parallelizes email downloading by spawning multiple processes
# to download emails in batches, improving performance for large downloads.
#
# Optimization: Runs preflight once to get all UIDs, then processes them
# in batches without re-running IMAP queries for each batch.

set -e  # Exit on any error

# Configuration
MAX_PROCESSES=5
BATCH_SIZE=100
DOCKER_COMPOSE_CMD="docker compose run --rm -T cli"
DEBUG=false

# Debug function
debug() {
    if [ "$DEBUG" = "true" ]; then
        echo "DEBUG: $*" >&2
    fi
}

# Function to get UIDs from preflight output
get_uids_from_preflight() {
    local output
    local cmd_result

    debug "Running command: $DOCKER_COMPOSE_CMD mailbox download --only-preflight" "$@"

    # Capture both stdout and stderr, and exit status
    if [ "$DEBUG" = "true" ]; then
        output=$($DOCKER_COMPOSE_CMD mailbox download --only-preflight "$@" 2>&1)
    else
        output=$($DOCKER_COMPOSE_CMD mailbox download --only-preflight "$@" 2>/dev/null)
    fi
    cmd_result=$?

    debug "Command exit status: $cmd_result"
    debug "Command output:"
    debug "$output"
    debug "End of output"

    if [ $cmd_result -ne 0 ]; then
        echo "Error: Preflight command failed with exit status $cmd_result" >&2
        echo "Command: $DOCKER_COMPOSE_CMD mailbox download --only-preflight $*" >&2
        echo "Error output: $output" >&2
        return 1
    fi

    local uids_line
    uids_line=$(echo "$output" | grep "^UIDs:" | sed 's/UIDs: //' | tr -d ' ')

    debug "Extracted UIDs line: '$uids_line'"

    echo "$uids_line"
}

# Function to split UIDs into chunks for parallel processing
split_uids() {
    local uids=$1
    local num_processes=$2

    # Convert comma-separated string to array
    IFS=',' read -ra UID_ARRAY <<< "$uids"

    local total_uids=${#UID_ARRAY[@]}
    local chunk_size=$(( (total_uids + num_processes - 1) / num_processes ))

    # Create chunks
    local chunk_index=0
    local current_chunk=""

    for uid in "${UID_ARRAY[@]}"; do
        if [ -n "$current_chunk" ]; then
            current_chunk="$current_chunk,$uid"
        else
            current_chunk="$uid"
        fi

        chunk_index=$((chunk_index + 1))

        if [ $chunk_index -eq $chunk_size ]; then
            echo "$current_chunk"
            current_chunk=""
            chunk_index=0
        fi
    done

    # Output remaining chunk if any
    if [ -n "$current_chunk" ]; then
        echo "$current_chunk"
    fi
}

# Function to run download for a chunk of UIDs
run_download_chunk() {
    local uid_chunk=$1
    shift
    local mailbox_args=("$@")

    echo "Starting download process for UIDs: $uid_chunk"

    # Debug: show the full command
    debug "Download command: $DOCKER_COMPOSE_CMD mailbox download --only-ids \"$uid_chunk\" --yes ${mailbox_args[*]}"

    # Run the download command with error capture
    local output
    local cmd_result

    if [ "$DEBUG" = "true" ]; then
        output=$($DOCKER_COMPOSE_CMD mailbox download --only-ids "$uid_chunk" --yes "${mailbox_args[@]}" 2>&1)
        cmd_result=$?
        debug "Download command output for chunk $uid_chunk:"
        debug "$output"
        debug "Download command exit status: $cmd_result"
    else
        $DOCKER_COMPOSE_CMD mailbox download --only-ids "$uid_chunk" --yes "${mailbox_args[@]}" >/dev/null 2>&1
        cmd_result=$?
    fi

    if [ $cmd_result -eq 0 ]; then
        echo "Completed download process for UIDs: $uid_chunk"
        return 0
    else
        echo "Failed download process for UIDs: $uid_chunk"
        if [ "$DEBUG" != "true" ]; then
            echo "Run with --debug to see error details"
        fi
        return 1
    fi
}

# Main function
main() {
    local mailbox_args=()
    local total_processed=0

    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --debug)
                DEBUG=true
                shift
                ;;
            --)
                shift
                mailbox_args=("$@")
                break
                ;;
            *)
                echo "Usage: $0 [--debug] [-- <mailbox arguments>]"
                echo "Example: $0 -- --mailbox INBOX"
                echo "Example: $0 --debug -- --mailbox '[Gmail]/All Mail'"
                exit 1
                ;;
        esac
    done

    echo "Starting parallel email downloading..."
    echo "Max processes: $MAX_PROCESSES"
    echo "Batch size: $BATCH_SIZE"
    echo "Mailbox args: ${mailbox_args[*]}"
    echo


    # Run preflight once to get all available UIDs
    echo "DEBUG: About to run preflight with mailbox args: ${mailbox_args[*]}"
    echo "Running preflight to get all available UIDs..."

    local all_uids
    all_uids=$(get_uids_from_preflight "${mailbox_args[@]}")

    debug "Raw preflight output UIDs: '$all_uids'"

    if [ -z "$all_uids" ] || [ "$all_uids" = "no UIDs found" ]; then
        echo "No UIDs available for downloading."
        return
    fi

    echo "DEBUG: First 20 UIDs from preflight: $(echo "$all_uids" | cut -d',' -f1-20)"

    # Convert to array
    IFS=',' read -ra ALL_UID_ARRAY <<< "$all_uids"
    local total_uids=${#ALL_UID_ARRAY[@]}

    echo "Found ${total_uids} UIDs total to process"
    echo "Processing in batches of ${BATCH_SIZE} UIDs..."
    echo


    # Process UIDs in batches
    local batch_start=0
    while [ $batch_start -lt $total_uids ]; do
        # Calculate batch end
        local batch_end=$((batch_start + BATCH_SIZE))
        if [ $batch_end -gt $total_uids ]; then
            batch_end=$total_uids
        fi

        local batch_count=$((batch_end - batch_start))
        echo "Processing batch: UIDs $((batch_start + 1))-${batch_end} (${batch_count} UIDs)"

        # Extract UIDs for this batch
        local batch_uids=("${ALL_UID_ARRAY[@]:$batch_start:$batch_count}")
        local uids_to_process
        uids_to_process=$(IFS=','; echo "${batch_uids[*]}")

        # Split UIDs into chunks for parallel processing
        local chunks
        mapfile -t chunks < <(split_uids "$uids_to_process" "$MAX_PROCESSES")

        echo "Spawning ${#chunks[@]} parallel processes..."

        # Start parallel processes
        local pids=()
        local chunk_index=0

        for chunk in "${chunks[@]}"; do
            if [ -n "$chunk" ]; then
                run_download_chunk "$chunk" "${mailbox_args[@]}" &
                pids+=($!)
                chunk_index=$((chunk_index + 1))
            fi
        done

        # Wait for all processes to complete
        local failed_processes=0
        for pid in "${pids[@]}"; do
            if ! wait "$pid"; then
                failed_processes=$((failed_processes + 1))
            fi
        done

        if [ $failed_processes -gt 0 ]; then
            echo "Warning: $failed_processes processes failed. Continuing..."
        fi

        total_processed=$((total_processed + batch_count))
        echo "Completed batch. Total processed so far: $total_processed/${total_uids}"
        echo "----------------------------------------"

        batch_start=$batch_end
    done

    echo "Downloading complete! Total emails processed: $total_processed"
}

# Run main function with all arguments
main "$@"