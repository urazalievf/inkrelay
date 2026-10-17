#!/bin/bash
# Builds build/InkRelay.app: the menu bar app, with the inkrelay command inside it.
#   scripts/build-app.sh                                         ad-hoc signed, for this Mac
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh   signed for distribution
#   UNIVERSAL=1 scripts/build-app.sh                             Apple silicon and Intel in one binary
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/InkRelayCore/InkRelayCore.swift)
IFS=. read -r MAJOR MINOR PATCH FIX <<< "$VERSION"
FIX=${FIX:-0}
SHORT="$MAJOR.$MINOR.$PATCH"
# A Mac app's build number has to keep rising across versions, so it packs all four parts.
BUILD=$((MAJOR * 1000000 + MINOR * 10000 + PATCH * 100 + FIX))

ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then ARCH_FLAGS=(--arch arm64 --arch x86_64); fi
swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --product InkRelayBar
swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --product inkrelay
BIN=$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)

APP=build/InkRelay.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/InkRelayBar" "$APP/Contents/MacOS/InkRelay"
cp "$BIN/inkrelay" "$APP/Contents/Resources/inkrelay"
sed -e "s/__SHORT_VERSION__/$SHORT/" -e "s/__BUILD_NUMBER__/$BUILD/" App/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

IDENTITY="${SIGN_IDENTITY:--}"
SIGN=(codesign --force --timestamp=none --options runtime --sign "$IDENTITY")
if [[ "$IDENTITY" != "-" ]]; then SIGN=(codesign --force --timestamp --options runtime --sign "$IDENTITY"); fi
"${SIGN[@]}" "$APP/Contents/Resources/inkrelay"
"${SIGN[@]}" --entitlements App/InkRelay.entitlements "$APP"
codesign --verify --strict --verbose=1 "$APP"

echo "Built $APP ($SHORT, build $BUILD, signed with ${IDENTITY/#-/ad-hoc})"
