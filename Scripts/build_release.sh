#!/usr/bin/env bash
#
# Builds a universal Release app, signs the zip with Sparkle's `sign_update`,
# and prints an <item> block for appcast.xml. By default the app is Developer ID
# signed, notarized, and stapled. --unnotarized explicitly selects ad-hoc signing
# without Apple's notarization service; Sparkle signing remains mandatory.
#
# Prerequisites:
#   - Sparkle has been resolved by Xcode at least once (so its bin tools exist on
#     disk under SourcePackages/artifacts/sparkle/Sparkle/bin/).
#   - You ran `generate_keys` once and pasted the public key into Info.plist.
#     See CONTRIBUTING.md "Releases" for the one-time key setup.
#   - For the default notarized mode only: Config/Signing.local.xcconfig selects
#     a Developer ID Application identity and SWIITCH_NOTARY_PROFILE names
#     credentials stored with `notarytool store-credentials`.
#
# Usage:
#   Scripts/build_release.sh <version> <build-number> [--unnotarized]
# Example:
#   Scripts/build_release.sh 0.2.0 48

set -euo pipefail

if [ $# -lt 2 ] || [ $# -gt 3 ]; then
    echo "Usage: $0 <version> <build-number> [--unnotarized]" >&2
    exit 1
fi
RELEASE_MODE=notarized
if [ $# -eq 3 ]; then
    if [ "$3" != --unnotarized ]; then
        echo "Unknown release option: $3" >&2
        exit 1
    fi
    RELEASE_MODE=unnotarized
fi

VERSION="$1"
BUILD_NUMBER="$2"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
    echo "Version must look like 1.2.3 or 1.2.3-beta.1 (got: $VERSION)" >&2
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/build"
RELEASE_DIR="$BUILD_DIR/Release"
DIST_DIR="$BUILD_DIR/dist"
ZIP_NAME="Swiitch-v${VERSION}.zip"

cd "$REPO_ROOT"

# Release source must be reviewed/committed, and the explicit number must exceed both
# the local feed and the actual published feed. A failed download fails closed.
if [ -n "$(git status --porcelain --untracked-files=normal)" ]; then
    echo "Working tree is dirty. Commit and review the release source before packaging." >&2
    exit 1
fi
bash Scripts/validate_release_number.sh "$BUILD_NUMBER" appcast.xml
mkdir -p "$DIST_DIR"
if [ -e "$DIST_DIR/$ZIP_NAME" ]; then
    echo "Release artifact already exists. Refusing to overwrite it." >&2
    exit 1
fi
swiitch_gate_dir="$(mktemp -d "$BUILD_DIR/release-gate.XXXXXX")"
swiitch_feed_url="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' Swiitch/Resources/Info.plist)"
curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --max-time 20 \
    "$swiitch_feed_url" --output "$swiitch_gate_dir/published.xml"
bash Scripts/validate_release_number.sh "$BUILD_NUMBER" appcast.xml "$swiitch_gate_dir/published.xml"
if [ "$RELEASE_MODE" = notarized ] && [ -z "${SWIITCH_NOTARY_PROFILE:-}" ]; then
    echo "SWIITCH_NOTARY_PROFILE must name a notarytool Keychain profile." >&2
    exit 1
fi

# Do not inject Xcode's development/debugger entitlement into public artifacts.
SIGNING_OVERRIDES=(CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO)
if [ "$RELEASE_MODE" = unnotarized ]; then
    echo "==> Explicit unnotarized release: ad-hoc app signature; Sparkle signature required"
    echo "    macOS may require manual approval and renewed Accessibility/Screen Recording grants."
    # Never leak the maintainer's local development identity into a public build.
    # Ad-hoc apps have no Team ID for hardened-runtime library validation, which
    # otherwise prevents loading Sparkle. This changes this build only, not macOS
    # security settings or the contributor's persistent signing configuration.
    SIGNING_OVERRIDES+=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= ENABLE_HARDENED_RUNTIME=NO)
fi

echo "==> Regenerating project"
xcodegen generate >/dev/null

echo "==> Building Release config"
xcodebuild \
    -project Swiitch.xcodeproj \
    -scheme Swiitch \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR/DerivedData" \
    -onlyUsePackageVersionsFromResolvedFile \
    SYMROOT="$BUILD_DIR" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    MARKETING_VERSION="$VERSION" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    "${SIGNING_OVERRIDES[@]}" \
    clean build | tail -5

APP_PATH="$RELEASE_DIR/Swiitch.app"
if [ ! -d "$APP_PATH" ]; then
    echo "Build did not produce $APP_PATH" >&2
    exit 1
fi
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist")" = "$BUILD_NUMBER"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")" = "$VERSION"

echo "==> Verifying universal architecture"
BUILT_ARCHS="$(lipo -archs "$APP_PATH/Contents/MacOS/Swiitch")"
for REQUIRED_ARCH in arm64 x86_64; do
    if [[ " $BUILT_ARCHS " != *" $REQUIRED_ARCH "* ]]; then
        echo "Release is missing $REQUIRED_ARCH (built: $BUILT_ARCHS)" >&2
        exit 1
    fi
done

echo "==> Verifying app signature ($RELEASE_MODE)"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
SIGNING_INFO="$(codesign -dv --verbose=4 "$APP_PATH" 2>&1)"
printf '%s\n' "$SIGNING_INFO" | bash Scripts/validate_release_signature.sh "$RELEASE_MODE"
codesign -d --entitlements :- "$APP_PATH" >"$swiitch_gate_dir/entitlements.plist" 2>/dev/null
if [ -s "$swiitch_gate_dir/entitlements.plist" ]; then
    plutil -lint "$swiitch_gate_dir/entitlements.plist" >/dev/null
    DEBUG_ENTITLEMENT="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.get-task-allow' "$swiitch_gate_dir/entitlements.plist" 2>/dev/null || true)"
    if [ -n "$DEBUG_ENTITLEMENT" ] && [ "$DEBUG_ENTITLEMENT" != false ]; then
        echo "Release has the development debugger entitlement. Refusing to package it." >&2
        exit 1
    fi
fi

mkdir -p "$DIST_DIR"
ZIP_PATH="$DIST_DIR/$ZIP_NAME"

if [ "$RELEASE_MODE" = notarized ]; then
    NOTARY_ZIP="$swiitch_gate_dir/notarization.zip"
    echo "==> Submitting app for notarization"
    ( cd "$RELEASE_DIR" && /usr/bin/ditto -c -k --sequesterRsrc --keepParent Swiitch.app "$NOTARY_ZIP" )
    xcrun notarytool submit "$NOTARY_ZIP" \
        --keychain-profile "$SWIITCH_NOTARY_PROFILE" \
        --wait

    echo "==> Stapling notarization ticket"
    xcrun stapler staple "$APP_PATH"
    xcrun stapler validate "$APP_PATH"
fi

test ! -e "$ZIP_PATH"
echo "==> Zipping app to $ZIP_PATH"
( cd "$RELEASE_DIR" && /usr/bin/ditto -c -k --sequesterRsrc --keepParent Swiitch.app "$ZIP_PATH" )

SIZE=$(stat -f%z "$ZIP_PATH")

# Locate Sparkle's sign_update tool. SPM caches binary tools under SourcePackages.
SIGN_UPDATE="$(find "$BUILD_DIR/DerivedData" -type f -name sign_update -perm +111 2>/dev/null | head -1)"
if [ -z "$SIGN_UPDATE" ]; then
    SIGN_UPDATE="$(find ~/Library/Developer/Xcode/DerivedData -type f -name sign_update -perm +111 2>/dev/null | head -1)"
fi
if [ -z "$SIGN_UPDATE" ]; then
    echo "Could not locate Sparkle's sign_update tool. Build at least once in Xcode so SPM materializes the Sparkle artifacts." >&2
    exit 1
fi

echo "==> Checking the existing Sparkle public key"
EXPECTED_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP_PATH/Contents/Info.plist")"
EXISTING_KEY="$("$(dirname "$SIGN_UPDATE")/generate_keys" -p)"
if [ -z "$EXPECTED_KEY" ] || [ "$EXISTING_KEY" != "$EXPECTED_KEY" ]; then
    echo "Existing Sparkle key does not match the built app. Refusing to sign with a different key." >&2
    exit 1
fi

echo "==> Signing update zip with $SIGN_UPDATE"
SIGN_OUTPUT="$("$SIGN_UPDATE" "$ZIP_PATH")"
# sign_update prints: sparkle:edSignature="..." length="..."
# Extract just the edSignature attribute — we emit `length` separately from the
# file size so we don't accidentally duplicate the attribute.
ED_SIGNATURE="$(printf '%s' "$SIGN_OUTPUT" | sed -nE 's/.*sparkle:edSignature="([^"]+)".*/\1/p')"
if [ -z "$ED_SIGNATURE" ]; then
    echo "Failed to parse edSignature from sign_update output: $SIGN_OUTPUT" >&2
    exit 1
fi
"$SIGN_UPDATE" --verify "$ZIP_PATH" "$ED_SIGNATURE"

PUB_DATE="$(LC_ALL=en_US.UTF-8 date "+%a, %d %b %Y %H:%M:%S %z")"

echo ""
echo "============================================================"
echo "Release artifact: $ZIP_PATH"
echo "Release mode:     $RELEASE_MODE"
echo "Size:             $SIZE bytes"
echo ""
echo "Paste this <item> into appcast.xml inside <channel>:"
echo "============================================================"
cat <<EOF
        <item>
            <title>$VERSION</title>
            <pubDate>$PUB_DATE</pubDate>
            <sparkle:version>$BUILD_NUMBER</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <description><![CDATA[Release $VERSION]]></description>
            <enclosure
                url="https://github.com/pernielsentikaer/swiitch/releases/download/v$VERSION/$ZIP_NAME"
                length="$SIZE"
                type="application/octet-stream"
                sparkle:edSignature="$ED_SIGNATURE" />
        </item>
EOF
echo "============================================================"
echo ""
echo "Next steps:"
echo "  1. Upload $ZIP_PATH to the GitHub release at"
echo "     https://github.com/pernielsentikaer/swiitch/releases/new?tag=v$VERSION"
echo "  2. Paste the <item> block above into appcast.xml."
echo "  3. Commit appcast.xml + push to main."
echo "  4. Existing installs will see the update on next launch (or 24h check)."
