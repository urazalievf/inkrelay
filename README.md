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

Version 0.5.0: a menu bar app, a command-line tool with a background agent, and an iPhone and iPad app, all for one engine. See the [issues](../../issues) and [milestones](../../milestones).

### Compatibility

Any tablet reaches every destination: sources and destinations are independent, so the two tables multiply.

| Tablet | How InkRelay reads it | State |
|---|---|---|
| Viwoods AiPaper, AiPaper Mini | Straight from Viwoods Cloud (notebooks, memos, Daily planner), or a PDF export folder | Cloud built against the live API's responses; a full pull on a real account still to run |
| reMarkable | PDF export to Google Drive, Dropbox or OneDrive | Folder route works; reading reMarkable Cloud directly is planned (#23) |
| Supernote | Its own `.note` notebooks, straight from Supernote's Dropbox, Google Drive or OneDrive sync; or PDF exports | Notebook reader checked page by page against Supernote's own PDF exports, on real notebooks from A6 X, Nomad and Manta in both the 2023 and 2026 formats |
| Boox | PDF or PNG export to a cloud drive | Folder route works |
| Kindle Scribe | Notebooks shared by email (Share → Send to email), picked up from Mail; or PDFs in a folder | Mail pickup built and tested against simulated Mail; not yet run on a real Scribe email |
| Any other tablet | PDF or PNG in any folder | Works |

| Destination | What it gets | Sign-in | State |
|---|---|---|---|
| Obsidian | Markdown with your edits kept, the original PDF | none | Working, tested |
| Apple Notes | Text with the original PDF attached | macOS Automation prompt | Built and tested with a simulated Notes; `inkrelay doctor --notes-roundtrip` runs it for real |
| Apple Calendar | Planner pages and to-dos as all-day events; accepted suggested events | macOS Automation prompt | Built, scripts compile; not yet run against Calendar |
| Apple Reminders | Written tasks and Daily to-dos, ticked off from the tablet | macOS Automation prompt | Built, scripts compile; not yet run against Reminders |
| Google Docs, Google Calendar | A Doc per note; planner events | Your Google OAuth client | Tested against the API's shapes and a real loopback sign-in; not yet run on a real account |
| OneNote, Outlook Calendar | A page per note with images; planner events | Your Microsoft app registration | Tested against Graph's shapes and the device-code flow; not yet run on a real account |
| Notion | A page per note with images | Notion integration token | Tested against the API's shapes; not yet run on a real workspace |
| Review stack | Read-later cards per page, to-do and suggested event | none | Working: used in a browser on a real sync |
| Shortcuts on iPhone and iPad | Text per note for Create Note | none | Builds and runs in the simulator; not yet run on a device |

| Also | State |
|---|---|
| On-device recognition (Vision) with paragraph, list and column rebuilding | Working on printed and handwriting-style text; real tablet pages still to check (#3) |
| AI transcription (Claude), opt-in per source | Tested against the API's request and response shapes; not yet run with a key |
| Send to tablet (EPUB from links, PDF, Markdown) | Folder target run for real on a live article; Viwoods import and Kindle mail not yet run |
| Menu bar app | Builds, launches and serves the review stack; not yet looked at in the menu bar |
| Background agent (`scripts/install-agent.sh`) | Not yet run (#4); `inkrelay doctor` checks it |
| Signed, notarized releases | Workflow written; needs the Developer ID secrets (see RELEASING.md) |

## Requirements

- macOS 14 or later
- Xcode 15 or later (Swift 5.9 toolchain) to build
- The desktop app for whichever cloud your tablet exports to: Google Drive, Dropbox or OneDrive. Their folders appear under `~/Library/CloudStorage`.

## Set up

```bash
swift build -c release
.build/release/inkrelay setup     # asks about your tablet, finds your cloud folders and Obsidian vaults, writes the config
.build/release/inkrelay doctor    # checks folders, permissions, sign-ins and the background agent
```

`setup` finds the folders under `~/Library/CloudStorage` (Google Drive, Dropbox, OneDrive, Box) and iCloud Drive, reads Obsidian's own list of vaults, and can list your Notes accounts, then runs a first sync. Nobody has to type JSON. `doctor` prints one line per check with what to fix; `doctor --notes-roundtrip` also creates, updates and deletes a test note in a folder called "InkRelay Test" to check Apple Notes end to end (the test notes end up in Recently Deleted), and `--no-apps` skips the Apple app checks that make macOS ask for permission.

To write the config by hand instead, `inkrelay init` writes an example to `~/Library/Application Support/InkRelay/config.json` (full example in [config.example.json](config.example.json)):

- **sources**: one entry per tablet. `path` is the folder the tablet exports to. `fileTypes` defaults to `["pdf"]`; add `"png"` for tablets that export images.
- **destinations**: `obsidian` needs `vaultPath`. `appleNotes` takes an optional `folder` (default `Ink`) and `account` (default: your default Notes account). Remove what you don't use.
- **recognition.languages**: BCP 47 codes such as `en-US` or `de-DE`.

Tips:

- In the cloud app, mark the export folder **Available offline**. Otherwise every new export downloads on first read.
- Set the tablet to export **PDF**, not its own notebook format.

## Supernote

Supernote can sync its Note folder to Dropbox, Google Drive or OneDrive by itself (Settings → Sync), but it syncs the notebooks in its own `.note` format, not PDFs. InkRelay reads those directly: add `"note"` to the source's `fileTypes` (setup does it when you pick Supernote) and point the source at that folder. Each notebook is turned into a PDF, page by page with all its visible layers, before recognition, so every destination gets the pages as you see them on the device. `inkrelay convert notebook.note notebook.pdf` does the same for one file.

Password-protected notebooks and the oldest A5 format (before firmware C.053) aren't supported.

## Kindle Scribe

A Kindle Scribe shares a notebook by email: Share → Send to email sends a PDF (attached, or as a download link) from Amazon. With a `kindleMail` section in the config (setup adds it when you pick the Scribe), InkRelay asks Mail every 15 minutes for recent messages from Amazon that mention Kindle, saves each notebook's PDF into its own cache, and relays it like any other export. It reads nothing else, remembers which messages it has handled, and only follows links that turn out to be PDFs. macOS asks once to let InkRelay read Mail.

```json
"kindleMail": { "sender": "amazon", "lookbackDays": 14, "checkEveryMinutes": 15 }
```

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

## Send articles and documents to the tablet

The other direction: `inkrelay send` takes a web link or a file and delivers it to the tablet.

```bash
inkrelay send https://example.com/some-article        # to the first send target
inkrelay send ~/Downloads/paper.pdf --to kindle
inkrelay send notes.md --title "Reading list"
```

A web page becomes an **EPUB**: the article's own text, headings, lists and pictures, without menus, ads, scripts or footers, which reflows to fit any e-ink screen. PDF and EPUB files go as they are; HTML, Markdown and plain text become EPUB too.

```json
"sendTargets": [
  { "kind": "viwoodsCloud", "id": "viwoods", "app": "learning" },
  { "kind": "folder", "id": "drive", "path": "~/Library/CloudStorage/GoogleDrive-you@example.com/My Drive/Viwoods/Import" },
  { "kind": "kindle", "id": "kindle", "address": "you_123@kindle.com" }
]
```

- **viwoodsCloud** uploads into Learning (the reader, default) or Paper, the same way the portal's Import button does; it needs `inkrelay viwoods login`.
- **folder** drops the file where the tablet or its cloud app picks files up. Existing files are never overwritten.
- **kindle** mails the file from Mail's default account. Add that address to the approved senders in Amazon's Send to Kindle settings first.

## Review stack

Add a `reviewStack` destination and every page InkRelay relays becomes a card. While `inkrelay watch` runs, the stack is at <http://127.0.0.1:7788>; without it, `inkrelay review open` serves and opens it.

- One card per page, showing the page image and the recognized text, and one card per planner to-do.
- **Done** (`D`, or swipe right) takes a card out. **Later** (`L`, or swipe left) brings it back tomorrow morning. Arrow keys browse.
- New arrivals come first, a notebook's pages in order, at most `dailyLimit` (default 25) a day.
- A page comes back only when its ink or text changes. To-dos ticked off on the tablet leave the stack by themselves.
- `resurfaceDays`, such as `[3, 14, 60]`, brings done cards back on that schedule, like a light spaced-repetition review. Empty (the default) means done is done.
- From the terminal: `inkrelay review` lists today's cards; `inkrelay review done <id>` and `inkrelay review later <id>` act on one by the short id it prints.

The page listens on 127.0.0.1 only, refuses requests whose Host isn't local, and actions need a custom header, so other websites can't read or change your stack. Cards and their images live in `review/` next to the config.

## Tasks, reminders and suggested events

Write tasks on the tablet the way you already do (`☐ Call the bank`, `[ ] book flights`, `TODO: renew passport`) and an `appleReminders` destination turns each into a reminder in the list named by `list` (default `Ink`; `{device}` and `{source}` are filled in, such as `"Ink · {device}"`). A date in the task, such as "by April 15" or "March 3 at 3pm", becomes the due date; on a planner page a bare time ("call Sam 4:30pm") belongs to that page's day. Tick the box on the tablet (`☑`, `[x]`) and the reminder is completed on the next sync. Re-syncs never duplicate, and edits you make in Reminders stay. Viwoods Daily to-dos go to Reminders too, due on their day.

Lines that name a date and a time but aren't tasks ("Dentist March 3 at 3pm") show up in the review stack as **suggested events**. Nothing is created until you press **Add to calendar** (or `A`), which adds it to every calendar destination you have: Apple, Google or Outlook. **Dismiss** drops it.

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

## Menu bar app

`scripts/build-app.sh` builds `build/InkRelay.app`. Move it to Applications and open it: it lives in the menu bar and runs the same engine inside the app, so macOS asks once, for InkRelay itself, for Notes, Calendar, Reminders and folder access.

- The icon shows the state at a glance: ready, syncing, paused, or a warning when the last sync had problems.
- The menu shows the last sync, Sync now and Pause, the problems if any, how many review cards are waiting, and the most recent notes; click one to open it in Obsidian (or the original export).
- Settings… sets everything up in a window when there's no config yet, with the same choices as `inkrelay setup`. Config and Logs open the files; Open at login uses macOS's login items.
- If the command-line agent from `scripts/install-agent.sh` is running, the app waits and offers to stop it, so notes aren't synced twice.
- The `inkrelay` command is inside the app at `InkRelay.app/Contents/Resources/inkrelay`.

## iPhone and iPad

For people without a Mac running all the time. The app in `iOS/` (open `iOS/InkRelayMobile.xcodeproj`, or `scripts/build-ios.sh --run` for the simulator) shares `InkRelayCore` with the Mac.

- Choose the folder your tablet exports to, through the Files app, so iCloud Drive, Google Drive, Dropbox and OneDrive all work. Handwriting is read on the device with Vision; nothing is uploaded.
- **Check for New Notes** reads what's new or changed since the last check.
- Apple Notes has no API on iOS either, so the app hands notes to Shortcuts: **Get New Ink Notes** returns one text per note with the title on the first line; follow it with **Repeat with Each** and **Create Note**, and run it from an automation. **Recognize Handwriting** reads any PDF or image shared to it.
- **Sync with your Mac**: with `"sharedLedger": {}` in the Mac's config (setup offers it), the Mac keeps a small `ledger.json` in iCloud Drive/InkRelay of what it filed into Apple Notes. Pick that same folder in the app, and each side skips what the other already filed, so a note never lands in Notes twice. Obsidian and the other Mac destinations still get everything. Whichever device sees a new version of an export first files it.

The project signs with the team set in `iOS/project.yml`; run it on a device from Xcode, which creates the provisioning profile the first time. The shared ledger is a plain file, so it needs no iCloud entitlement.

## Run

```bash
.build/release/inkrelay sync      # once
.build/release/inkrelay watch     # keep running; syncs on folder changes and every 5 minutes
.build/release/inkrelay status    # what's tracked and delivered
scripts/install-agent.sh          # run `watch` in the background at login
scripts/install-agent.sh --uninstall
```

Agent logs go to `~/Library/Logs/InkRelay/inkrelay.log`, trimmed to the newest 512 KB whenever they pass 5 MB.

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
