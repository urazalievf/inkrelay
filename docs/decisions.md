# Decisions

Settled choices and the reasons for them. Change one only when the reason no longer holds, and say so here.

## Product

- **The folder export route always works; cloud connectors speed it up.** Every tablet can export to Google Drive, Dropbox or OneDrive. Tablet clouds are unofficial APIs that can break with any portal update, so a broken connector must never leave someone with nothing.
- **Recognition stays on the device by default.** Vision on the Mac or iPhone; nothing is uploaded. AI transcription is opt-in, uses the person's own Anthropic key with a monthly budget, and falls back to Vision.
- **One engine for every front end.** The CLI, menu bar app, iPhone app and MCP server all call `InkRelayCore`. Features land in the core first.
- **The review stack is for a person's own ink.** It shows notebook pages, planner to-dos and suggested events as cards, Imprint style. It doesn't touch third-party content.
- **Google Keep is out.** Its API is for Workspace administrators only.
- **reMarkable Cloud is deferred.** Its sync API is unofficial and has changed versions several times, and there's no account or device to test with. PDF export covers reMarkable.
- **Pricing to test:** a free core (folder sources, Obsidian, Apple Notes) and a one-time $29 Pro unlock for cloud sources, the Google, Microsoft and Notion destinations, AI transcription and the review stack. See [launch/pricing.md](launch/pricing.md). Not decided until the waitlist answers.

## Behaviour

- **Nothing is ever erased for good.** Deleting goes to the Trash, Notes' Recently Deleted or the Drive trash. `onDelete` defaults to `keep`. A source folder that turns up empty deletes nothing, because that is usually an unmounted cloud drive.
- **InkRelay owns only its part of an Obsidian note:** the text between the markers and its own frontmatter keys. Everything else the person writes survives every sync.
- **Planner events are titled "Daily plan" (0.7.0).** The first recognized line made titles like "Daily plan: ter те". Neither Vision's confidence nor a word list nor the spell checker could tell misreads apart ([field-notes.md](field-notes.md)). AI transcription's title is used when there is one. If titles from the text come back, gate them on something that actually works.
- **Blank detection is conservative.** A page counts as blank only with no recognized text and next to no ink. Templates and ruled lines count as ink, so the rule can only keep a page, never drop a written one. A note already filed keeps following its export even if it's erased.
- **Open at login is asked, not assumed.** The app asks once on its first launch from Applications. Registering a login item without the person's click is not acceptable.

## Apple platforms

- **Apple Notes, Calendar and Reminders go through AppleScript.** They have no public API on the Mac. On iOS the app hands notes to Shortcuts, because there's no Notes API there either.
- **Shared state is plain JSON in iCloud Drive, not an iCloud container.** This needs no entitlement or provisioning. The Mac sees iCloud Drive as a folder, and the phone reaches it through the Files app.
- **Every shared file has exactly one writer.** For the review stack, the Mac writes `Review/stack.json` and the images, and each phone writes only its own `decisions-<device>.json`. iCloud therefore never has two versions to reconcile. The ledger is the exception (several writers), so it merges conflict copies.
- **Viwoods sign-in happens in the portal's own page** inside the app, and the token is read from its `localStorage`. The login has a slider captcha, and InkRelay never handles a password.

## Engineering

- **No third-party packages.** Foundation, Vision, PDFKit, CryptoKit, AppKit and SwiftUI cover everything. EPUB zips are written by hand (`ZipWriter`).
- **AppleScripts are tested by compiling them** with `osacompile` exactly as shipped, because escaping mistakes in Swift string literals otherwise only show up at run time.
- **CI runs on pull requests and by hand only.** macOS runner minutes cost ten times as much on a private repo.
- **Workflow:** one pull request per round of work, a commit per area, squash merges, branches deleted on merge. Only the owner merges. Commits are authored by the owner, with no co-author trailers or tool credits in commits, PRs or docs.
- **Versions** are `MAJOR.MINOR.PATCH`, plus a fourth `.FIX` number only for bug fixes.
  - MINOR is a feature round, and PATCH a small change. MINOR and PATCH both drop FIX.
  - Versions only move forward, and the bump is committed with the change.
  - The Mac app's build number packs all four parts: `MAJOR*1000000 + MINOR*10000 + PATCH*100 + FIX`.
  - iOS shows `MAJOR.MINOR.PATCH`, with FIX in the build number.
- **Releases are signed and notarized or not published.** The release workflow stops before building if any signing secret is missing.
