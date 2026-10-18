#!/bin/bash
# Regenerates the iPhone and iPad project from iOS/project.yml (XcodeGen) and builds it for the simulator.
#   scripts/build-ios.sh            build only
#   scripts/build-ios.sh --run      also install and launch it in an iPhone simulator
#   scripts/build-ios.sh --archive  archive for devices and upload to TestFlight; needs the App Store Connect
#                                   key in NOTARY_KEY_P8 (path), NOTARY_KEY_ID and NOTARY_ISSUER_ID, the same
#                                   key the Mac release uses, and the app record in App Store Connect
set -euo pipefail
cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null || { echo "Install XcodeGen first: brew install xcodegen" >&2; exit 1; }
(cd iOS && xcodegen generate --spec project.yml --quiet)
if [[ "${1:-}" == "--archive" ]]; then
    : "${NOTARY_KEY_P8:?path to the App Store Connect .p8}" "${NOTARY_KEY_ID:?}" "${NOTARY_ISSUER_ID:?}"
    # The iPhone app shows MAJOR.MINOR.PATCH; the FIX number is its build number, so a bug-fix release uploads a new build.
    VERSION=$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/InkRelayCore/InkRelayCore.swift)
    IFS=. read -r MAJOR MINOR PATCH FIX <<< "$VERSION"
    SHORT="$MAJOR.$MINOR.$PATCH"; FIX="${FIX:-0}"
    ARCHIVE=.build/ios/InkRelayMobile.xcarchive
    xcodebuild -project iOS/InkRelayMobile.xcodeproj -scheme InkRelayMobile -configuration Release \
        MARKETING_VERSION="$SHORT" CURRENT_PROJECT_VERSION="$FIX" \
        -destination "generic/platform=iOS" -archivePath "$ARCHIVE" -derivedDataPath .build/ios \
        -allowProvisioningUpdates -authenticationKeyPath "$NOTARY_KEY_P8" -authenticationKeyID "$NOTARY_KEY_ID" -authenticationKeyIssuerID "$NOTARY_ISSUER_ID" \
        archive -quiet
    xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist iOS/ExportOptions.plist -exportPath .build/ios/export \
        -allowProvisioningUpdates -authenticationKeyPath "$NOTARY_KEY_P8" -authenticationKeyID "$NOTARY_KEY_ID" -authenticationKeyIssuerID "$NOTARY_ISSUER_ID" -quiet
    echo "Uploaded to App Store Connect; it shows up in TestFlight after processing."
    exit 0
fi
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
