#!/usr/bin/env bash
# Runs entirely against fixtures. No network, signing, notarization, or real repo commit.
set -euo pipefail
swiitch_scripts="$(cd "$(dirname "$0")" && pwd)"
swiitch_temp="$(mktemp -d "${TMPDIR:-/tmp}/swiitch-release-tests.XXXXXX")"
swiitch_checks=0
expect_pass() {
    bash "$swiitch_scripts/validate_release_number.sh" "$@" >"$swiitch_temp/output" 2>&1
    swiitch_checks=$((swiitch_checks + 1))
}
expect_fail() {
    if bash "$swiitch_scripts/validate_release_number.sh" "$@" >"$swiitch_temp/output" 2>&1; then
        echo "Expected release gate failure" >&2
        exit 1
    fi
    swiitch_checks=$((swiitch_checks + 1))
}
swiitch_local="$swiitch_scripts/fixtures/local-appcast.xml"
swiitch_published="$swiitch_scripts/fixtures/published-appcast.xml"
expect_pass 21 "$swiitch_local" "$swiitch_published"
expect_pass 16 "$swiitch_local"
for swiitch_bad in 0 -1 015 15 14 1.2 1000000000; do expect_fail "$swiitch_bad" "$swiitch_local"; done
expect_fail 16 "$swiitch_local" "$swiitch_published"
expect_fail 20 "$swiitch_published"
for swiitch_invalid in missing-build.xml invalid-build.xml not-appcast.xml duplicate-build.xml; do
    expect_fail 21 "$swiitch_scripts/fixtures/$swiitch_invalid"
done
expect_fail 21 "$swiitch_temp/nonexistent.xml"

# Prove the packaging script stops at the dirty-tree gate before asking for credentials
# or contacting the feed. The fixture repository has no commits and no remote.
git init -q "$swiitch_temp/dirty"
mkdir -p "$swiitch_temp/dirty/Scripts"
cp "$swiitch_scripts/build_release.sh" "$swiitch_temp/dirty/Scripts/build_release.sh"
if bash "$swiitch_temp/dirty/Scripts/build_release.sh" 0.2.0 21 >"$swiitch_temp/dirty-output" 2>&1; then
    echo "Expected dirty tree rejection" >&2
    exit 1
fi
[[ "$(< "$swiitch_temp/dirty-output")" == *"Working tree is dirty"* ]]
swiitch_checks=$((swiitch_checks + 1))
printf '%s release-gate checks passed. Fixtures retained at %s\n' "$swiitch_checks" "$swiitch_temp"
