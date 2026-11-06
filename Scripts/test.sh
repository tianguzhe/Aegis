#!/bin/bash
set -euo pipefail
if [[ "$#" -gt 2 || ( "$#" -gt 0 && "$1" != --ui ) || "$#" -eq 1 ]]; then
    printf 'Usage: %s [--ui <simulator-UDID>]\n' "$0" >&2
    exit 2
fi
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
python3 -m unittest discover -s Scripts/tests -p 'test_*.py'
python3 Scripts/check_localizations.py
python3 Scripts/generate_localizations.py --check
python3 "$isolation_script" exec --root "$project_root" --lane core-test -- \
    swift test --build-system native --manifest-cache local --package-path Packages/AegisKit
if [[ "$#" -eq 2 ]]; then
    python3 "$isolation_script" exec --root "$project_root" --lane ios-ui-test -- \
        xcodebuild -project Aegis.xcodeproj -scheme Aegis-iOS -configuration Debug \
        -destination "platform=iOS Simulator,id=$2" CODE_SIGNING_ALLOWED=NO test
fi
