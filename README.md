# InkRelay

Handwritten notes from any e-ink tablet, delivered into the notes apps you already use.

E-ink tablets (Viwoods, Supernote, Boox, Kindle Scribe, reMarkable) each sync to their own cloud, or to Google Drive, Dropbox and OneDrive. None of them reach Apple Notes, and each one reaches Obsidian through a different plugin, if at all. InkRelay watches the folder your tablet exports to, reads the handwriting on your Mac, and files each notebook into Apple Notes and Obsidian. When you add a page on the tablet, the same note updates.

For the Viwoods AiPaper it goes one step further: with Viwoods Cloud turned on (firmware 3.15 or later), InkRelay pulls every notebook, memo and the Daily planner straight from the cloud. No export step on the tablet, no Drive app on the Mac.

Destinations cover all three ecosystems: Apple Notes and Apple Calendar, Google Docs and Google Calendar, OneNote and Outlook Calendar, plus Obsidian. Planner pages and to-dos go to whichever calendars you pick.

And everything that arrives also lands in the **review stack**: a read-later queue of bite-sized cards, one page or one to-do each, that you flip through in the browser and mark Done or Later. Only pages that changed come back, so adding page 12 to a notebook brings one card, not twelve.

```
tablet ──export──▶ Google Drive / Dropbox / OneDrive / iCloud Drive folder on your Mac
                                │
Viwoods Cloud ──pull──▶ local cache of PDFs (one per notebook, memo and planner day)
                                │
                     inkrelay watch (FSEvents + periodic rescan + cloud poll)
                                │
                  Vision handwriting recognition, on device
                                │
     ┌──────────────┬───────────┼───────────┬──────────────┐
  Obsidian       Apple Notes   Google Docs   OneNote     Review stack
                 (notes: every notebook)                (cards at 127.0.0.1)
     └──────── Apple Calendar · Google Calendar · Outlook ────────┘
                 (planner day pages and to-dos only)
```

## Status

Version 0.3.0 is a command-line tool and background agent for macOS. A menu bar app, more destinations and an iPhone app are planned. See the [issues](../../issues) and [milestones](../../milestones).

| Piece | State |
|---|---|
| Folder sources (any tablet that exports PDF or PNG) | Working, covered by tests |
| Viwoods Cloud source (Paper, Meeting, Memo, Daily) | Built against the cloud's real responses and covered by tests; a full pull on a live account still to be run |
| Apple Calendar destination (Daily planner) | Built and unit-tested with a fake AppleScript runner; not yet run against Calendar |
| Google Calendar and Google Docs destinations | Built and tested against recorded API shapes; sign-in flow tested end to end on loopback; not yet run against a real Google account |
| Outlook Calendar and OneNote destinations | Built and tested against recorded Graph shapes; device-code sign-in tested; not yet run against a real Microsoft account |
| Review stack (read-later cards) | Working: page, server and actions checked in a browser on a local sync; covered by tests |
| On-device recognition (Apple Vision) | Working on printed and handwriting-style text; real tablet exports still to be checked |
| Obsidian destination | Working, covered by tests |
| Apple Notes destination | Built and unit-tested with a fake AppleScript runner; not yet run against Notes |
| Background agent (`scripts/install-agent.sh`) | Written, not yet run |

## Requirements

- macOS 14 or later
- Xcode 15 or later (Swift 5.9 toolchain) to build
- The desktop app for whichever cloud your tablet exports to: Google Drive, Dropbox or OneDrive. Their folders appear under `~/Library/CloudStorage`.

## Set up

```bash
swift build -c release
.build/release/inkrelay init      # writes ~/Library/Application Support/InkRelay/config.json
```

Edit the config (full example in [config.example.json](config.example.json)):

- **sources**: one entry per tablet. `path` is the folder the tablet exports to. `fileTypes` defaults to `["pdf"]`; add `"png"` for tablets that export images.
- **destinations**: `obsidian` needs `vaultPath`. `appleNotes` takes an optional `folder` (default `Ink`) and `account` (default: your default Notes account). Remove what you don't use.
- **recognition.languages**: BCP 47 codes such as `en-US` or `de-DE`.

Tips:

- In the cloud app, mark the export folder **Available offline**. Otherwise every new export downloads on first read.
- Set the tablet to export **PDF**, not its own notebook format.

## Viwoods Cloud

Viwoods publishes no API. InkRelay talks to the same endpoints the web portal at cloud.viwoods.com uses and signs requests the same way, so a portal update can break it. Turn on Viwoods Cloud on the tablet first (Settings → Viwoods Cloud; the Paper, Meeting, Memo and Daily apps each have their own sync switch).

Signing in on the web needs a slider captcha, so InkRelay never asks for your password. Instead it uses the token the portal already holds:

```bash
.build/release/inkrelay viwoods login   # prints where to copy the token from, then asks for it
```

The token is kept in `viwoods-token.json` next to the config, readable only by you, and refreshed automatically afterwards. Then add a `viwoodsCloud` section to the config (see the example) and sync as usual. `inkrelay viwoods pull` fetches the cloud into the cache without syncing, for a first look.

What arrives:

- **Paper and Meeting notebooks** become one PDF each, in the folders you use on the tablet, under `<cache>/Paper/…` and `<cache>/Meeting/…`. The PDF holds the rendered page images the cloud stores, so it looks exactly like the tablet. Password-protected notebooks are skipped and reported.
- **Memos** become `<cache>/Memo/<name>.pdf`.
- **Daily planner**: each day with handwritten Tasks or Notes pages becomes `<cache>/Daily/<yyyy-MM-dd>.pdf`, which Obsidian and Notes receive like any notebook. Typed to-dos go straight to Apple Calendar.
- The cache is `~/Library/Application Support/InkRelay/viwoods` unless `cachePath` says otherwise, and it is a source of its own: notes land under `Ink/viwoods-cloud/…` in Obsidian.

The cloud is checked on every sync and, under `watch`, every `rescanIntervalSeconds`. Only changed notebooks are downloaded.

## Apple Calendar

The `appleCalendar` destination takes only the Daily planner. A handwritten day page becomes an all-day event titled `Daily plan: <first recognized line>` with the full recognized text in the notes. Each typed to-do becomes an all-day event of its own, `☐ …` or `☑ …` by its state, with its priority in the notes. Events are updated in place when the page or to-do changes; one deleted in Calendar is recreated on the next change. The calendar named in the config is created if missing. macOS asks once to let `inkrelay` control Calendar.

## Review stack

Add a `reviewStack` destination and every page InkRelay relays becomes a card. While `inkrelay watch` runs, the stack is at <http://127.0.0.1:7788>; without it, `inkrelay review open` serves and opens it.

- One card per page, showing the page image and the recognized text, and one card per planner to-do.
- **Done** (`D`, or swipe right) takes a card out. **Later** (`L`, or swipe left) brings it back tomorrow morning. Arrow keys browse.
- New arrivals come first, a notebook's pages in order, at most `dailyLimit` (default 25) a day.
- A page comes back only when its ink or text changes. To-dos ticked off on the tablet leave the stack by themselves.
- `resurfaceDays`, such as `[3, 14, 60]`, brings done cards back on that schedule, like a light spaced-repetition review. Empty (the default) means done is done.
- From the terminal: `inkrelay review` lists today's cards; `inkrelay review done <id>` and `inkrelay review later <id>` act on one by the short id it prints.

The page listens on 127.0.0.1 only, refuses requests whose Host isn't local, and actions need a custom header, so other websites can't read or change your stack. Cards and their images live in `review/` next to the config.

## Google: Calendar and Docs

`googleCalendar` puts planner pages and to-dos into a calendar InkRelay creates (default name `Viwoods`). `googleDocs` turns each note into a Google Doc with the recognized text in a Drive folder InkRelay creates (default `Ink`). InkRelay asks only for the `calendar.app.created` and `drive.file` permissions, so it can see the calendar and files it made and nothing else in your account.

Google needs an OAuth client of your own while InkRelay is in development:

1. In [Google Cloud Console](https://console.cloud.google.com/), create a project, enable the **Google Calendar API** and **Google Drive API**, and set up the OAuth consent screen with yourself as a test user.
2. Under Credentials, create an **OAuth client ID** of type **Desktop app**.
3. Add it to the config, then sign in:

```json
"google": { "clientId": "…apps.googleusercontent.com", "clientSecret": "…" }
```

```bash
.build/release/inkrelay google login   # opens the consent page; the browser comes back to 127.0.0.1
```

## Microsoft: Outlook Calendar and OneNote

`outlookCalendar` puts planner pages and to-dos into an Outlook calendar, found by name or created (default `Viwoods`). All-day events use the Mac's time zone unless `timeZone` names another, such as `America/Chicago`. `oneNote` files each note as a OneNote page with the page images and the recognized text, in a notebook found by name or created (default `Ink`), one section per tablet folder (Paper, Memo, Daily…). OneNote can't replace a page's body, so an update writes a new page and deletes the old one; the page link changes.

1. In the [Microsoft Entra admin center](https://entra.microsoft.com/) → App registrations, register an app for "Accounts in any organizational directory and personal Microsoft accounts".
2. Under Authentication, turn on **Allow public client flows**. Under API permissions, add the delegated Microsoft Graph permissions **Calendars.ReadWrite** and **Notes.ReadWrite**.
3. Add the application (client) id to the config, then sign in with the code it shows:

```json
"microsoft": { "clientId": "…", "tenant": "common" }
```

```bash
.build/release/inkrelay microsoft login   # prints a code to enter at microsoft.com/devicelogin
```

## Notion

`notion` files each note as a Notion page, under a parent page (`parentPageId`) or as a row of a database (`databaseId`), with the page images and the recognized text. It updates the same page on every change, and `onDelete` archive or delete moves it to Notion's trash. Anything you add inside the page in Notion is replaced on the next change; properties and comments stay.

1. Create an internal integration at <https://www.notion.so/profile/integrations> with the Insert content and Update content capabilities.
2. Open the parent page or database in Notion, then ••• → Connections → add the integration.
3. Copy the page or database id from its link (the 32 characters at the end), and save the integration secret in the Keychain:

```json
{ "kind": "notion", "id": "notion", "parentPageId": "1a2b3c…" }
```

```bash
.build/release/inkrelay notion login
```

## AI transcription (optional)

Vision is free and never sends anything anywhere, but it struggles with cursive and dense pages. For a source that needs better reading, set `"recognizer": "claude"` on it (or on `viwoodsCloud`). **Its page images are then sent to Anthropic's API**, one request per page, and Claude returns the text with paragraphs, lists and checkboxes rebuilt, plus a suggested title and tags that land in Obsidian's frontmatter as `suggested_title` and `suggested_tags`. Every other source stays on Vision.

```json
"ai": { "model": "claude-opus-5-5", "effort": "medium", "monthlyBudgetUSD": 5, "serverFallback": true }
```

- **Budget:** each answer's token usage is priced and added up in `ai-usage.json`. A page is only sent if a worst-case page still fits under `monthlyBudgetUSD`; after that, Vision reads the rest of the month for free. At the default model a page costs roughly two to four cents.
- **Fallbacks:** a page Claude can't do (no key, budget reached, an API error, a declined or cut-off answer) is read by Vision instead, and the sync log says which pages and why. `serverFallback` lets the API retry a declined page on Anthropic's recommended fallback model first.
- **Key:** `inkrelay ai login` saves an Anthropic API key in the login Keychain (`ANTHROPIC_API_KEY` in the environment works too). `inkrelay ai status` shows the month's spend.

## Run

```bash
.build/release/inkrelay sync      # once
.build/release/inkrelay watch     # keep running; syncs on folder changes and every 5 minutes
.build/release/inkrelay status    # what's tracked and delivered
scripts/install-agent.sh          # run `watch` in the background at login
scripts/install-agent.sh --uninstall
```

Agent logs go to `~/Library/Logs/InkRelay/inkrelay.log`.

## How syncing behaves

- Each export becomes one note. Its title is the file name.
- Changes are found by size and date first, then by content hash, so unchanged cloud files aren't downloaded again.
- If one destination fails, only that destination is retried on the next pass.
- In Obsidian, InkRelay rewrites only the part between `%% inkrelay:start %%` and `%% inkrelay:end %%` and its own frontmatter keys (`source`, `device`, `original`, `pages`, `modified`, `synced`). Write anything you like above or below the markers, and add your own frontmatter keys or tags: they survive every re-sync. Notes from before 0.4.0 get the markers on their next change.
- A renamed or moved export moves its notes instead of duplicating them. Files are read only once they've stopped changing for `settleSeconds` (default 5), so half-downloaded exports aren't relayed.
- What happens when an export is deleted is up to you, per destination, with `onDelete` (for example `"onDelete": { "obsidian": "archive", "apple-notes": "delete" }`). `keep` is the default; `archive` moves Obsidian notes to `Ink/Archive/` and Apple Notes to an "Ink Archive" folder; `delete` uses the Trash, Recently Deleted or the Drive trash, so nothing is erased for good. A source folder that turns up empty never deletes anything, since that's usually an unmounted cloud drive.
- State lives in `~/Library/Application Support/InkRelay/state.json`. Delete it to re-send everything.
- The Viwoods cache keeps its own ledger in `.manifest.json`. Delete it to pull everything from the cloud again.

## Permissions

- **Apple Notes and Calendar**: macOS asks once to let `inkrelay` (or Terminal, when run there) control Notes and Calendar. Manage it later in System Settings → Privacy & Security → Automation.
- **Viwoods, Google and Microsoft**: tokens live next to the config in `viwoods-token.json`, `google-token.json` and `microsoft-token.json`, readable only by you. Delete one to sign out of that service. Google and Microsoft tokens refresh themselves.
- **Files**: cloud folders under `~/Library/CloudStorage` may prompt for access the first time.

## Development

```bash
swift test
```

`Sources/InkRelayCore` holds the library: config, scanning, sync state, recognition, destinations and the engine. `Sources/inkrelay` is the command-line tool. The Vision test renders a PDF and runs real recognition, so the first run takes about 30 seconds while the model loads.

Versions follow `MAJOR.MINOR.PATCH`, with a fourth number for bug-fix releases (`0.1.0.1`). The current version is `InkRelayCore.version`.
