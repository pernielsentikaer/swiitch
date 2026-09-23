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

# Both release modes preserve the dirty-source gate; unknown flags never opt out.
for swiitch_option in --unnotarized --skip-notarization; do
    if bash "$swiitch_temp/dirty/Scripts/build_release.sh" 0.2.0 21 "$swiitch_option" >"$swiitch_temp/dirty-output" 2>&1; then
        echo "Expected packaging rejection" >&2
        exit 1
    fi
    if [ "$swiitch_option" = --unnotarized ]; then
        [[ "$(< "$swiitch_temp/dirty-output")" == *"Working tree is dirty"* ]]
    else
        [[ "$(< "$swiitch_temp/dirty-output")" == *"Unknown release option"* ]]
    fi
    swiitch_checks=$((swiitch_checks + 1))
done

# These are metadata fixtures, not real certificates or signing operations.
swiitch_developer_id=$'Authority=Developer ID Application: Example\nCodeDirectory flags=0x10000(runtime)'
swiitch_development=$'Authority=Apple Development: Example\nCodeDirectory flags=0x10000(runtime)'
swiitch_adhoc=$'Signature=adhoc\nCodeDirectory flags=0x2(adhoc)'
expect_signature() {
    local expected="$1" mode="$2" metadata="$3" actual=fail
    if printf '%s\n' "$metadata" | bash "$swiitch_scripts/validate_release_signature.sh" "$mode" >"$swiitch_temp/output" 2>&1; then
        actual=pass
    fi
    if [ "$actual" != "$expected" ]; then
        echo "Unexpected signature policy result for $mode: $actual" >&2
        exit 1
    fi
    swiitch_checks=$((swiitch_checks + 1))
}
expect_signature pass notarized "$swiitch_developer_id"
expect_signature fail notarized "$swiitch_development"
expect_signature fail notarized "$swiitch_adhoc"
expect_signature fail notarized 'Authority=Developer ID Application: Example'
expect_signature fail notarized ''
expect_signature pass unnotarized "$swiitch_adhoc"
expect_signature fail unnotarized "$swiitch_development"
expect_signature fail unnotarized "$swiitch_developer_id"
expect_signature fail unnotarized ''
expect_signature fail unnotarized "$swiitch_adhoc"$'\nAuthority=Apple Development: Example'
expect_signature fail unknown "$swiitch_adhoc"
printf '%s release-gate checks passed. Fixtures retained at %s\n' "$swiitch_checks" "$swiitch_temp"
