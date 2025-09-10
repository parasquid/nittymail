#!/bin/bash

# NittyMail Async Job Queue Download Script
# Processes email UIDs using an async job queue for continuous streaming
# No waiting for batches - workers process jobs as soon as they're available

set -e  # Exit on any error

# Source the common library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/async_common.sh"

# Configuration specific to download
MAX_WORKERS=5
BATCH_SIZE=100  # UIDs per job
QUEUE_DIR="./download_queue"
DOCKER_COMPOSE_CMD="bundle exec ruby cli.rb"
OPERATION_TYPE="email downloading"
DEBUG=false

# Get UIDs from preflight (download-specific)
get_uids_from_preflight() {
    local output
    local cmd_result

    debug "Running preflight command: $DOCKER_COMPOSE_CMD mailbox download --only-preflight $@"

    if [ "$DEBUG" = "true" ]; then
        output=$($DOCKER_COMPOSE_CMD mailbox download --only-preflight "$@" 2>&1)
    else
        output=$($DOCKER_COMPOSE_CMD mailbox download --only-preflight "$@" 2>/dev/null)
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

# Process a batch of UIDs (download-specific)
process_batch() {
    local uids=$1
    local uidvalidity=$2
    shift 2
    local mailbox_args=("$@")

    debug "Processing batch with UIDs: $uids (UIDVALIDITY=$uidvalidity)"

    # Run the download command with pre-known UIDVALIDITY to avoid IMAP lookup
    if [ "$DEBUG" = "true" ]; then
        $DOCKER_COMPOSE_CMD mailbox download --only-ids "$uids" --uidvalidity "$uidvalidity" --yes "${mailbox_args[@]}" 2>&1
        return $?
    else
        $DOCKER_COMPOSE_CMD mailbox download --only-ids "$uids" --uidvalidity "$uidvalidity" --yes "${mailbox_args[@]}" >/dev/null 2>&1
        return $?
    fi
}

# Main function - delegates to common library
main() {
    main_common "$@"
}

# Run main function
main "$@"
