#!/usr/bin/env bash

retry_command() {
    local max_attempts=${RETRY_MAX_ATTEMPTS:-4}
    local delay_seconds=${RETRY_INITIAL_DELAY_SECONDS:-5}
    local attempt=1

    until "$@"; do
        if (( attempt >= max_attempts )); then
            echo "Command failed after $attempt attempts: $*" >&2
            return 1
        fi

        echo "Command failed (attempt $attempt/$max_attempts); retrying in ${delay_seconds}s" >&2
        sleep "$delay_seconds"
        attempt=$((attempt + 1))
        delay_seconds=$((delay_seconds * 2))
    done
}
