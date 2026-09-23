#!/usr/bin/env bash
set -euo pipefail
swiitch_repo="$(cd "$(dirname "$0")/.." && pwd)"
swiitch_lock_dir="$swiitch_repo/Swiitch.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
test -s "$swiitch_repo/Package.resolved"
mkdir -p "$swiitch_lock_dir"
cp "$swiitch_repo/Package.resolved" "$swiitch_lock_dir/Package.resolved"
cmp "$swiitch_repo/Package.resolved" "$swiitch_lock_dir/Package.resolved"
