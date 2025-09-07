#!/bin/bash

# NittyMail Parallel Archive Script
# This script parallelizes email archiving by spawning multiple processes
# to download emails in batches, improving performance for large archives.

set -e  # Exit on any error

# Configuration
MAX_PROCESSES=5
BATCH_SIZE=100
DOCKER_COMPOSE_CMD="docker compose run --rm -T cli bundle exec ruby cli.rb"
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

    debug "Running command: $DOCKER_COMPOSE_CMD mailbox archive --only-preflight" "$@"

    # Capture both stdout and stderr, and exit status
    if [ "$DEBUG" = "true" ]; then
        output=$($DOCKER_COMPOSE_CMD mailbox archive --only-preflight "$@" 2>&1)
    else
        output=$($DOCKER_COMPOSE_CMD mailbox archive --only-preflight "$@" 2>/dev/null)
    fi
    cmd_result=$?

    debug "Command exit status: $cmd_result"
    debug "Command output:"
    debug "$output"
    debug "End of output"

    if [ $cmd_result -ne 0 ]; then
        echo "Error: Preflight command failed with exit status $cmd_result" >&2
        echo "Command: $DOCKER_COMPOSE_CMD mailbox archive --only-preflight $*" >&2
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

# Function to run archive for a chunk of UIDs
run_archive_chunk() {
    local uid_chunk=$1
    shift
    local mailbox_args=("$@")

    echo "Starting archive process for UIDs: $uid_chunk"

    # Debug: show the full command
    debug "Archive command: $DOCKER_COMPOSE_CMD mailbox archive --only-ids \"$uid_chunk\" --yes --output ./archives ${mailbox_args[*]}"

    # Run the archive command with error capture
    local output
    local cmd_result

    if [ "$DEBUG" = "true" ]; then
        output=$($DOCKER_COMPOSE_CMD mailbox archive --only-ids "$uid_chunk" --yes --output ./archives "${mailbox_args[@]}" 2>&1)
        cmd_result=$?
        debug "Archive command output for chunk $uid_chunk:"
        debug "$output"
        debug "Archive command exit status: $cmd_result"
    else
        $DOCKER_COMPOSE_CMD mailbox archive --only-ids "$uid_chunk" --yes --output ./archives "${mailbox_args[@]}" >/dev/null 2>&1
        cmd_result=$?
    fi

    if [ $cmd_result -eq 0 ]; then
        echo "Completed archive process for UIDs: $uid_chunk"
        return 0
    else
        echo "Failed archive process for UIDs: $uid_chunk"
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

    echo "Starting parallel email archiving..."
    echo "Max processes: $MAX_PROCESSES"
    echo "Batch size: $BATCH_SIZE"
    echo "Mailbox args: ${mailbox_args[*]}"
    echo

    while true; do
        echo "Running preflight to check for available UIDs..."

        # Get UIDs from preflight
        local uids
        uids=$(get_uids_from_preflight "${mailbox_args[@]}")

        if [ -z "$uids" ] || [ "$uids" = "no UIDs found" ]; then
            echo "No more UIDs available for archiving."
            break
        fi

        echo "Found UIDs: $uids"

        # Convert to array and limit to batch size
        IFS=',' read -ra UID_ARRAY <<< "$uids"
        local total_available=${#UID_ARRAY[@]}

        if [ $total_available -eq 0 ]; then
            echo "No UIDs to process."
            break
        fi

        # Limit to batch size
        local process_count=$(( total_available < BATCH_SIZE ? total_available : BATCH_SIZE ))
        local uids_to_process="${UID_ARRAY[@]:0:$process_count}"
        uids_to_process=$(echo "$uids_to_process" | tr ' ' ',')

        echo "Processing $process_count UIDs in this batch..."

        # Split UIDs into chunks for parallel processing
        local chunks
        mapfile -t chunks < <(split_uids "$uids_to_process" "$MAX_PROCESSES")

        echo "Spawning ${#chunks[@]} parallel processes..."

        # Start parallel processes
        local pids=()
        local chunk_index=0

        for chunk in "${chunks[@]}"; do
            if [ -n "$chunk" ]; then
                run_archive_chunk "$chunk" "${mailbox_args[@]}" &
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

        total_processed=$((total_processed + process_count))
        echo "Completed batch. Total processed so far: $total_processed"
        echo "----------------------------------------"
    done

    echo "Archiving complete! Total emails processed: $total_processed"
}

# Run main function with all arguments
main "$@"
