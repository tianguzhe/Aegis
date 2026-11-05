#!/bin/bash
# Shared paths and failure-preserving registration cleanup for development tools.
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
artifact_root="$project_root/.build/artifacts.noindex"
isolation_script="$project_root/Scripts/build_isolation.py"
python3 "$isolation_script" prepare --root "$project_root" >/dev/null || exit $?
cd "$project_root"

aegis_cleanup() {
    local code=$?
    trap - EXIT
    if ! python3 "$isolation_script" cleanup --root "$project_root"; then
        [[ "$code" -ne 0 ]] || code=1
    fi
    exit "$code"
}
trap aegis_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
