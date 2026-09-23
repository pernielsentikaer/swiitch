#!/usr/bin/env bash
# Validate codesign -dv metadata after codesign --verify --deep --strict succeeds.
# This read-only policy check does not sign, notarize, or change system settings.
set -euo pipefail
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <notarized|unnotarized> < codesign-metadata" >&2
    exit 1
fi
swiitch_signing_info="$(cat)"
case "$1" in
    notarized)
        if ! printf '%s\n' "$swiitch_signing_info" | grep -q '^Authority=Developer ID Application:'; then
            echo "Default release requires a Developer ID Application signature." >&2
            exit 1
        fi
        if ! printf '%s\n' "$swiitch_signing_info" | grep -q 'flags=.*runtime'; then
            echo "Notarized release requires hardened runtime." >&2
            exit 1
        fi
        ;;
    unnotarized)
        if ! printf '%s\n' "$swiitch_signing_info" | grep -qx 'Signature=adhoc' ||
            printf '%s\n' "$swiitch_signing_info" | grep -q '^Authority='; then
            echo "Explicit unnotarized releases require ad-hoc signing, not a development certificate." >&2
            exit 1
        fi
        ;;
    *)
        echo "Unknown release signing mode: $1" >&2
        exit 1
        ;;
esac
