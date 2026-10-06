#!/bin/zsh
# Builds a signed Release, packages it as a DMG, publishes it as a GitHub
# Release and updates appcast.xml so installed copies pick it up via Sparkle.
#
# Before running: bump CFBundleShortVersionString and CFBundleVersion in
# SnapCast/Info.plist. Sparkle compares CFBundleVersion, so it must grow.
#
# Usage: scripts/release.sh [--app path/to/SnapCast.app] ["release notes"]
#
# --app takes an app that was already exported with Developer ID, notarized
# and stapled (Xcode → Archive → Distribute App → Direct Distribution) and
# skips the local build. Without it the app is built here and signed with
# the local Apple Development certificate — fine for this Mac only.
set -euo pipefail

cd "${0:A:h}/.."

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Volumes/KINGSTON/Developer/Applications/Xcode.app/Contents/Developer}"
SIGN_IDENTITY="${SIGN_IDENTITY:-Apple Development: jakub.hutecka@gmail.com (VL52UU55N4)}"
TEAM_ID="${TEAM_ID:-8T9RVGUF2N}"
REPO="Dahutis/NxCapture"
KEY_ACCOUNT="snapcast"
PREBUILT_APP=""
if [[ "${1:-}" == "--app" ]]; then
    PREBUILT_APP="$2"
    shift 2
fi
NOTES="${1:-}"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" SnapCast/Info.plist)
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" SnapCast/Info.plist)
TAG="v$VERSION"
DMG_NAME="SnapCast-$VERSION.dmg"

if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    echo "Release $TAG already exists — bump the version in SnapCast/Info.plist first." >&2
    exit 1
fi

if [[ -n "$PREBUILT_APP" ]]; then
    APP="${PREBUILT_APP%/}"
    echo "==> Using notarized app $APP"
    APP_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
    APP_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")
    if [[ "$APP_VERSION" != "$VERSION" || "$APP_BUILD" != "$BUILD" ]]; then
        echo "App is $APP_VERSION ($APP_BUILD) but Info.plist says $VERSION ($BUILD)." >&2
        exit 1
    fi
    # Refuses anything that isn't Developer ID signed, notarized and stapled.
    xcrun stapler validate "$APP"
    spctl --assess --type execute -vv "$APP"
else
    echo "==> Building SnapCast $VERSION ($BUILD)"
    xcodebuild -project SnapCast.xcodeproj -scheme SnapCast -configuration Release \
        -derivedDataPath build/DerivedData \
        CODE_SIGN_STYLE=Manual \
        CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
        DEVELOPMENT_TEAM="$TEAM_ID" \
        PROVISIONING_PROFILE_SPECIFIER="" \
        build -quiet
    APP=build/DerivedData/Build/Products/Release/SnapCast.app
fi
codesign --verify --strict --deep "$APP"

echo "==> Packaging $DMG_NAME"
STAGE=build/dmg-stage
rm -rf "$STAGE" && mkdir -p "$STAGE"
ditto "$APP" "$STAGE/SnapCast.app"
ln -s /Applications "$STAGE/Applications"
DMG="build/$DMG_NAME"
rm -f "$DMG"
hdiutil create -volname SnapCast -srcfolder "$STAGE" -format UDZO "$DMG" -quiet
# A notarized app carries its own stapled ticket, so its DMG stays unsigned.
if [[ -z "$PREBUILT_APP" ]]; then
    codesign --sign "$SIGN_IDENTITY" --timestamp "$DMG"
fi

echo "==> Signing update for Sparkle"
SPARKLE_BIN=build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin
if [[ ! -x "$SPARKLE_BIN/sign_update" ]]; then
    xcodebuild -resolvePackageDependencies -project SnapCast.xcodeproj -scheme SnapCast \
        -derivedDataPath build/DerivedData -quiet
fi
# Prints: sparkle:edSignature="…" length="…"
SIGNATURE_ATTRS=$("$SPARKLE_BIN/sign_update" --account "$KEY_ACCOUNT" "$DMG")

echo "==> Publishing GitHub release $TAG"
gh release create "$TAG" "$DMG" --repo "$REPO" --title "SnapCast $VERSION" --notes "${NOTES:-SnapCast $VERSION}"

echo "==> Writing appcast.xml"
PUB_DATE=$(LC_ALL=en_US.UTF-8 date -u "+%a, %d %b %Y %H:%M:%S +0000")
cat > appcast.xml <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>SnapCast</title>
    <item>
      <title>SnapCast $VERSION</title>
      <pubDate>$PUB_DATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <enclosure url="https://github.com/$REPO/releases/download/$TAG/$DMG_NAME" $SIGNATURE_ATTRS type="application/octet-stream"/>
    </item>
  </channel>
</rss>
EOF

# Keep the download link on the presentation page current.
cp "$DMG" Presentation/SnapCast.dmg

git add appcast.xml Presentation/SnapCast.dmg SnapCast/Info.plist
git commit -m "Release $VERSION"
echo
echo "Done. Push to main to make the update live:  git push origin HEAD:main"
