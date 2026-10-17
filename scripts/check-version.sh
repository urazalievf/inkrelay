#!/bin/bash
# Fails unless a release tag matches InkRelayCore.version: v0.4.0 for 0.4.0, v1.2.3.1 for a fix release.
#   scripts/check-version.sh v0.4.0
set -euo pipefail
cd "$(dirname "$0")/.."
TAG="${1:?usage: scripts/check-version.sh vMAJOR.MINOR.PATCH[.FIX]}"
VERSION=$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/InkRelayCore/InkRelayCore.swift)
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
    echo "InkRelayCore.version \"$VERSION\" isn't MAJOR.MINOR.PATCH or MAJOR.MINOR.PATCH.FIX." >&2
    exit 1
fi
if [[ "$TAG" != "v$VERSION" ]]; then
    echo "Tag $TAG doesn't match InkRelayCore.version $VERSION. Bump the version (and commit it) or tag v$VERSION." >&2
    exit 1
fi
echo "$VERSION"
