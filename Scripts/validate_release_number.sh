#!/usr/bin/env bash
# Read-only gate. Accept an explicit positive build number newer than every supplied feed.
set -euo pipefail
if [ "$#" -lt 2 ] || [[ ! "$1" =~ ^[1-9][0-9]{0,8}$ ]]; then
    echo "Usage: $0 <positive build number, up to 9 digits> <appcast.xml> [published.xml]" >&2
    exit 1
fi
swiitch_build="$1"
shift
swiitch_versions='/*[local-name()="rss"]/*[local-name()="channel"]/*[local-name()="item"]/*[local-name()="version" and namespace-uri()="http://www.andymatuschak.org/xml-namespaces/sparkle"]'
for swiitch_feed in "$@"; do
    xmllint --nonet --noout "$swiitch_feed"
    swiitch_channels="$(xmllint --nonet --xpath 'count(/rss/channel)' "$swiitch_feed")"
    swiitch_items="$(xmllint --nonet --xpath 'count(/rss/channel/item)' "$swiitch_feed")"
    swiitch_count="$(xmllint --nonet --xpath "count($swiitch_versions)" "$swiitch_feed")"
    if [ "$swiitch_channels" != 1 ] || [ "$swiitch_count" != "$swiitch_items" ]; then
        echo "Invalid appcast or missing/duplicate build numbers; release refused." >&2
        exit 1
    fi
    for ((swiitch_index = 1; swiitch_index <= swiitch_count; swiitch_index++)); do
        swiitch_item_count="$(xmllint --nonet --xpath "count(/rss/channel/item[$swiitch_index]/*[local-name()='version' and namespace-uri()='http://www.andymatuschak.org/xml-namespaces/sparkle'])" "$swiitch_feed")"
        if [ "$swiitch_item_count" != 1 ]; then
            echo "Each appcast item must have exactly one build number." >&2
            exit 1
        fi
        swiitch_previous="$(xmllint --nonet --xpath "string(($swiitch_versions)[$swiitch_index])" "$swiitch_feed")"
        if [[ ! "$swiitch_previous" =~ ^[1-9][0-9]{0,8}$ ]] || [ "$swiitch_build" -le "$swiitch_previous" ]; then
            echo "Build number must be greater than every local and published release." >&2
            exit 1
        fi
    done
done
printf 'Release build number %s passed the appcast gate.\n' "$swiitch_build"
