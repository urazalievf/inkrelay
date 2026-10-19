#!/bin/bash
# Publishes a notarized build to the public releases repository. The source repository is private, so its own
# releases answer 404 to customers; the site's Download button and the app's update check read this one.
#   scripts/publish-release.sh --check v0.10.1             # before building: notes, token, not yet published
#   scripts/publish-release.sh v0.10.1 InkRelay-0.10.1.zip  # after notarizing
# Uses RELEASES_TOKEN when it's set (the release workflow), otherwise gh's own login. See RELEASING.md.
set -euo pipefail
cd "$(dirname "$0")/.."

# Keep in step with UpdateChecker.releasesRepository; a test checks they match.
REPOSITORY="urazalievf/inkrelay-releases"

CHECK_ONLY=0
if [[ "${1:-}" == "--check" ]]; then
    CHECK_ONLY=1
    shift
fi
TAG="${1:?usage: scripts/publish-release.sh [--check] vMAJOR.MINOR.PATCH[.FIX] [zip]}"
VERSION=$(scripts/check-version.sh "$TAG")
NOTES="docs/release-notes/$VERSION.md"
if [[ -n "${RELEASES_TOKEN:-}" ]]; then
    export GH_TOKEN="$RELEASES_TOKEN"
fi

# Customers read these notes on the release page and in the app's update alert; generated notes would list
# private pull requests they can't open.
if [[ ! -s "$NOTES" ]]; then
    echo "::error::$NOTES is missing or empty. Write what changed for customers, commit it, and tag again." >&2
    exit 1
fi
if ! gh api "repos/$REPOSITORY" --jq .full_name > /dev/null; then
    echo "::error::Can't reach $REPOSITORY. RELEASES_TOKEN needs Contents read and write on that repository (RELEASING.md)." >&2
    exit 1
fi
if gh release view "$TAG" --repo "$REPOSITORY" > /dev/null 2>&1; then
    echo "::error::$REPOSITORY already has $TAG. Releases are never replaced; bump the version." >&2
    exit 1
fi
if (( CHECK_ONLY )); then
    echo "$TAG can be published to $REPOSITORY."
    exit 0
fi

ZIP="${2:?usage: scripts/publish-release.sh vMAJOR.MINOR.PATCH[.FIX] InkRelay-VERSION.zip}"
# The same zip under a fixed name too, so releases/latest/download/InkRelay.zip always fetches the newest.
STABLE="$(mktemp -d)/InkRelay.zip"
cp "$ZIP" "$STABLE"
# The tag in the releases repository points at its README commit; the private repository's tag is the source.
gh release create "$TAG" "$ZIP" "$STABLE" --repo "$REPOSITORY" --target main \
    --title "InkRelay $VERSION" --notes-file "$NOTES"
echo "Published https://github.com/$REPOSITORY/releases/tag/$TAG"
