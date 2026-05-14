#!/usr/bin/env bash
#
# Builds a Release-config Swiitch.app, zips it, signs the zip with Sparkle's
# `sign_update`, and prints an <item> block you can paste into appcast.xml.
#
# Prerequisites:
#   - Sparkle has been resolved by Xcode at least once (so its bin tools exist on
#     disk under SourcePackages/artifacts/sparkle/Sparkle/bin/).
#   - You ran `generate_keys` once and pasted the public key into Info.plist.
#     See CONTRIBUTING.md "Releases" for the one-time key setup.
#
# Usage:
#   Scripts/build_release.sh <version>
# Example:
#   Scripts/build_release.sh 0.1.0

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 <version>" >&2
    exit 1
fi

VERSION="$1"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/build"
RELEASE_DIR="$BUILD_DIR/Release"
DIST_DIR="$BUILD_DIR/dist"
ZIP_NAME="Swiitch-v${VERSION}.zip"

cd "$REPO_ROOT"

# Build number = total git commit count. Monotonically increases with every commit
# so each release gets a unique, larger CFBundleVersion than the last. Without this,
# Sparkle compares appcast `sparkle:version` against installed `CFBundleVersion` and
# misclassifies the installed binary as "older" forever, causing an update loop.
BUILD_NUMBER="$(git rev-list --count HEAD)"
echo "==> Build number (git commit count): $BUILD_NUMBER"

echo "==> Regenerating project"
xcodegen generate >/dev/null

echo "==> Building Release config"
xcodebuild \
    -project Swiitch.xcodeproj \
    -scheme Swiitch \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR/DerivedData" \
    SYMROOT="$BUILD_DIR" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    MARKETING_VERSION="$VERSION" \
    build | tail -5

APP_PATH="$RELEASE_DIR/Swiitch.app"
if [ ! -d "$APP_PATH" ]; then
    echo "Build did not produce $APP_PATH" >&2
    exit 1
fi

mkdir -p "$DIST_DIR"
ZIP_PATH="$DIST_DIR/$ZIP_NAME"
rm -f "$ZIP_PATH"

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

PUB_DATE="$(LC_ALL=en_US.UTF-8 date "+%a, %d %b %Y %H:%M:%S %z")"

echo ""
echo "============================================================"
echo "Release artifact: $ZIP_PATH"
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
