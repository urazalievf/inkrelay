# Releasing InkRelay

A release is a signed, notarized `InkRelay.app` (with the `inkrelay` command inside) attached to a GitHub Release. Pushing a version tag does all of it through `.github/workflows/release.yml`.

## Versions

`MAJOR.MINOR.PATCH`, plus a fourth `.FIX` number only for bug fixes:

- **MAJOR**: a huge change, such as a rebrand or a complete overhaul. Resets the rest (`2.0.0`).
- **MINOR**: a feature-level change. Resets PATCH and drops FIX (`1.3.0`).
- **PATCH**: a small change. Drops FIX (`1.2.4`).
- **FIX**: a bug fix on the current version adds `.1`; each further fix raises it (`1.2.3.1` → `1.2.3.2`).

Versions only move forward. The version lives in `InkRelayCore.version`; bump it and commit the bump with the change.

The app shows `MAJOR.MINOR.PATCH` as its version. Its build number has to keep rising across all versions, so it packs all four numbers: `MAJOR*1000000 + MINOR*10000 + PATCH*100 + FIX` (`1.3.0.1` → `1030001`). `scripts/build-app.sh` computes both.

## One-time setup

Needs an Apple Developer Program membership. One App Store Connect API key covers everything:

1. App Store Connect → Users and Access → Integrations → [App Store Connect API](https://appstoreconnect.apple.com/access/integrations/api) → Team Keys → **+**, with the **Admin** role (Developer is enough if a Developer ID Application certificate already exists). Download the `.p8`, and copy the Issuer ID shown above the list.
2. Run:

```bash
swift scripts/setup-releases.swift ~/Downloads/AuthKey_XXXXXXXXXX.p8 <issuer-id> --tag
```

The script checks the key, uses the "Developer ID Application" certificate in your keychain or creates one through the API (a fresh key pair, imported into the login keychain), exports it with a random password (macOS asks you to allow the export), stores the six repository secrets with `gh secret set`, and with `--tag` tags the current version and pushes the tag. Nothing is printed or written to the repository. `--dry-run` only checks the key.

Apple never lets an API key create a Developer ID certificate, even an Admin one ("This operation can only be performed by the Account Holder"). Make it as the Account Holder instead, then run the script again:

- on the website: Certificates → **+** → **Developer ID Application** → **G2 Sub-CA** → upload a signing request made with `openssl req -new -newkey rsa:2048 -nodes -keyout developer-id.key -out developer-id.csr -subj "/CN=Developer ID"`, download the `.cer`, and import it with its key into the login keychain; or
- in Xcode → Settings → Accounts → team DT9JP293AM → Manage Certificates → + → **Developer ID Application**.

For this repository that's done: the certificate expires November 17, 2027, and the six secrets are set.

### By hand

The workflow reads these secrets (Settings → Secrets and variables → Actions):

```bash
gh secret set DEVELOPER_ID_P12_BASE64 < <(base64 -i developer-id.p12)
gh secret set DEVELOPER_ID_P12_PASSWORD
gh secret set DEVELOPER_ID_NAME --body "Developer ID Application: Your Name (TEAMID)"
gh secret set NOTARY_KEY_P8_BASE64 < <(base64 -i AuthKey_XXXXXXXXXX.p8)
gh secret set NOTARY_KEY_ID --body "XXXXXXXXXX"
gh secret set NOTARY_ISSUER_ID --body "00000000-0000-0000-0000-000000000000"
```

None of these ever go in the repository. If any is missing the workflow stops before building, so nothing unsigned is published.

## Cutting a release

Write the notes first, in `docs/release-notes/<version>.md`: what changed for someone using InkRelay, in plain words. They're the release page's text, and the app's update alert shows their first 600 characters, so no Markdown emphasis. The workflow stops before building when the file is missing, and a test fails when the current version has none.

```bash
scripts/check-version.sh v0.10.2   # the tag must match InkRelayCore.version
git tag v0.10.2
git push origin v0.10.2
```

The workflow checks the notes, tests, builds a universal (Apple silicon and Intel) app with the hardened runtime, signs it with the Developer ID, notarizes and staples it, checks it with Gatekeeper, and creates the GitHub Release here with `InkRelay-0.10.2.zip` and the notes.

### When Apple takes longer than 30 minutes

Apple usually notarizes in a few minutes, but it can hold a submission for hours, especially a new team's first ones. v0.10.0's first run timed out that way after 30 minutes. The workflow waits 30 minutes, then stops with the submission id and keeps the signed app as the run's `signed-app` artifact for 14 days. To finish:

```bash
# from the release-signing folder, with the App Store Connect key
xcrun notarytool info <submission-id> --key AuthKey_XXXXXXXXXX.p8 --key-id XXXXXXXXXX --issuer <issuer-id>
# once it says Accepted:
gh workflow run release.yml -f run_id=<the tag's run id> -f tag=v0.10.0
```

That run checks the tag's run built that tag, staples the same app Apple accepted, and publishes the release. Nothing is rebuilt or re-signed. If Apple says Invalid instead, the failed run prints Apple's log.

## Local builds

`scripts/build-app.sh` builds an ad-hoc signed app for this Mac. `SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh` signs it like a release, without notarizing.
