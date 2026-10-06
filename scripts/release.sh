#!/bin/zsh
# Builds a signed Release, packages it as a DMG, publishes it as a GitHub
# Release and updates appcast.xml so installed copies pick it up via Sparkle.
#
# Before running: bump CFBundleShortVersionString and CFBundleVersion in
# SnapCast/Info.plist. Sparkle compares CFBundleVersion, so it must grow.
#
# Usage: scripts/release.sh ["release notes"]
set -euo pipefail

cd "${0:A:h}/.."

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Volumes/KINGSTON/Developer/Applications/Xcode.app/Contents/Developer}"
SIGN_IDENTITY="${SIGN_IDENTITY:-Apple Development: jakub.hutecka@gmail.com (VL52UU55N4)}"
TEAM_ID="${TEAM_ID:-8T9RVGUF2N}"
REPO="Dahutis/NxCapture"
KEY_ACCOUNT="snapcast"
NOTES="${1:-}"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" SnapCast/Info.plist)
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" SnapCast/Info.plist)
TAG="v$VERSION"
DMG_NAME="SnapCast-$VERSION.dmg"

if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    echo "Release $TAG already exists — bump the version in SnapCast/Info.plist first." >&2
    exit 1
fi

echo "==> Building SnapCast $VERSION ($BUILD)"
xcodebuild -project SnapCast.xcodeproj -scheme SnapCast -configuration Release \
    -derivedDataPath build/DerivedData \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    PROVISIONING_PROFILE_SPECIFIER="" \
    build -quiet
APP=build/DerivedData/Build/Products/Release/SnapCast.app
codesign --verify --strict --deep "$APP"

echo "==> Packaging $DMG_NAME"
STAGE=build/dmg-stage
rm -rf "$STAGE" && mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="build/$DMG_NAME"
rm -f "$DMG"
hdiutil create -volname SnapCast -srcfolder "$STAGE" -format UDZO "$DMG" -quiet
codesign --sign "$SIGN_IDENTITY" --timestamp "$DMG"

echo "==> Signing update for Sparkle"
SPARKLE_BIN=build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin
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
