#!/bin/bash
# Regenerates the iPhone and iPad project from iOS/project.yml (XcodeGen) and builds it for the simulator.
#   scripts/build-ios.sh            build only
#   scripts/build-ios.sh --run      also install and launch it in an iPhone simulator
set -euo pipefail
cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null || { echo "Install XcodeGen first: brew install xcodegen" >&2; exit 1; }
(cd iOS && xcodegen generate --spec project.yml --quiet)
DEVICE=$(xcrun simctl list devices available | sed -n 's/^ *\(iPhone[^(]*\) (\([0-9A-F-]*\)).*/\2/p' | head -1)
xcodebuild -project iOS/InkRelayMobile.xcodeproj -scheme InkRelayMobile -configuration Debug \
    -destination "id=$DEVICE" -derivedDataPath .build/ios CODE_SIGNING_ALLOWED=NO build -quiet
APP=.build/ios/Build/Products/Debug-iphonesimulator/InkRelay.app
echo "Built $APP"
if [[ "${1:-}" == "--run" ]]; then
    xcrun simctl boot "$DEVICE" 2>/dev/null || true
    open -a Simulator
    xcrun simctl install "$DEVICE" "$APP"
    xcrun simctl launch "$DEVICE" io.github.urazalievf.InkRelay.mobile
fi
