#!/usr/bin/env bash
set -euo pipefail

script_root=$(cd "$(dirname "$0")" && pwd)
source "$script_root/retry-command.sh"

manifest=${1:?manifest path required}
destination_root=${2:?destination root required}

mkdir -p "$destination_root"

jq -r '.[] | [.url, .path, .commit] | @tsv' "$manifest" |
while IFS=$'\t' read -r upstream_url relative_path commit; do
    if [[ "$relative_path" == "pEpForiOS-intern" ]]; then
        echo "Skipping private upstream dependency: $relative_path"
        continue
    fi

    clone_url=${upstream_url/ssh:\/\/git@codeberg.org\//https:\/\/codeberg.org\/}
    target="$destination_root/$relative_path"

    if [[ ! -d "$target/.git" ]]; then
        echo "Cloning $relative_path"
        retry_command git clone --filter=blob:none --no-checkout \
            "$clone_url" "$target"
    fi

    retry_command git -C "$target" fetch --filter=blob:none origin "$commit"
    git -C "$target" checkout --detach "$commit"
done
