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

Version 0.11.0: a menu bar app, a command-line tool with a background agent, and an iPhone and iPad app, all for one engine. Free for folder exports, Obsidian and the Apple apps; Pro ($29 once, 14-day trial) for the cloud sources, Google, Microsoft, Notion, AI transcription and the review stack. See the [issues](../../issues) and [milestones](../../milestones). Signed builds are on the [releases page](../../releases) ([RELEASING.md](RELEASING.md)).

### Compatibility

Any tablet reaches every destination: sources and destinations are independent, so the two tables multiply.

| Tablet | How InkRelay reads it | State |
|---|---|---|
| Viwoods AiPaper, AiPaper Mini | Straight from Viwoods Cloud (notebooks, memos, Daily planner), or a PDF export folder | Pulled from a real account: notebooks, a memo and 20 planner days |
| reMarkable | PDF export to Google Drive, Dropbox or OneDrive | Folder route works; reading reMarkable Cloud directly is planned (#23) |
| Supernote | Its own `.note` notebooks, straight from Supernote's Dropbox, Google Drive or OneDrive sync; or PDF exports | Notebook reader checked page by page against Supernote's own PDF exports, on real notebooks from A6 X, Nomad and Manta in both the 2023 and 2026 formats |
| Boox | PDF or PNG export to a cloud drive | Folder route works |
| Kindle Scribe | Notebooks shared by email (Share → Send to email), picked up from Mail; or PDFs in a folder | Mail pickup built and tested against simulated Mail; not yet run on a real Scribe email |
| Any other tablet | PDF or PNG in any folder | Works |

| Destination | What it gets | Sign-in | State |
|---|---|---|---|
| Obsidian | Markdown with your edits kept, the original PDF | none | Working, tested |
| Apple Notes | Text with the original PDF attached | macOS Automation prompt | Checked against real Notes (iCloud and Google accounts); `inkrelay doctor --notes-roundtrip` runs the same checks on yours |
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

`setup` finds the folders under `~/Library/CloudStorage` (Google Drive, Dropbox, OneDrive, Box) and iCloud Drive, reads Obsidian's own list of vaults, and can list your Notes accounts, then runs a first sync. Nobody has to type JSON. `doctor` prints one line per check with what to fix; `doctor --notes-roundtrip` also creates, updates, archives and deletes a test note in a folder called "InkRelay Test" to check Apple Notes end to end (the test notes end up in Recently Deleted and the test folders are removed; `--notes-account NAME` picks an account other than the configured one), and `--no-apps` skips the Apple app checks that make macOS ask for permission.

To write the config by hand instead, `inkrelay init` writes an example to `~/Library/Application Support/InkRelay/config.json` (full example in [config.example.json](config.example.json)):

- **sources**: one entry per tablet. `path` is the folder the tablet exports to. `fileTypes` defaults to `["pdf"]`; add `"png"` for tablets that export images.
- **destinations**: `obsidian` needs `vaultPath`. `appleNotes` takes an optional `folder` (default `Ink`) and `account` (default: your default Notes account). Remove what you don't use.
- **recognition.languages**: BCP 47 codes such as `en-US` or `de-DE`.

Tips:

- In the cloud app, mark the export folder **Available offline**. Otherwise every new export downloads on first read.
- Set the tablet to export **PDF**, not its own notebook format.

## Free and Pro

Everything a Mac can do on its own is free: export folders from any tablet, Obsidian, Apple Notes, Apple Calendar and Apple Reminders. Pro adds Viwoods Cloud, Kindle Scribe by email, Google Calendar and Docs, Outlook Calendar and OneNote, Notion, AI transcription, and the review stack on the Mac and the phone. Every install starts with a 14-day Pro trial.

When the trial ends without a license, the Pro parts pause: each sync says so in one line, nothing is deleted, and once a key is entered they catch up from where they stopped at the next sync (every pass reads the plan again, so the app or the agent needs no restart). Enter a key with **Enter License…** in the InkRelay menu or `inkrelay license enter INK1.…`; `inkrelay license` shows the plan. Keys are checked on the Mac against the publisher's public key, so InkRelay never contacts a server about them.

A key can carry an end date (yearly Pro). Two weeks before it, the menu says the renewal key is on its way; each paid renewal emails a new key, and entering it keeps everything running. A key that runs out pauses the Pro parts the same way, and the menu, the sync report and `inkrelay doctor` ask for the renewal rather than calling the key refused. `scripts/issue-licenses.swift` issues keys from a Lemon Squeezy store: Founder orders for keeps, the yearly subscription through the paid year plus 14 days' grace, and a new key at each renewal.

## Supernote

Supernote can sync its Note folder to Dropbox, Google Drive or OneDrive by itself (Settings → Sync), but it syncs the notebooks in its own `.note` format, not PDFs. InkRelay reads those directly: add `"note"` to the source's `fileTypes` (setup does it when you pick Supernote) and point the source at that folder. Each notebook is turned into a PDF, page by page with all its visible layers, before recognition, so every destination gets the pages as you see them on the device. `inkrelay convert notebook.note notebook.pdf` does the same for one file.

Supernote's sync folder also holds `Document` (books and PDFs you annotate), `EXPORT`, `INBOX`, `SCREENSHOT` and `MyStyle`. A source made by setup for a Supernote leaves those out with `"exclude"`, and setup suggests the `Note` folder itself when it exists. Any source can take `"exclude": ["Folder", "Other/Sub"]` to leave folders out, or `"folders": ["Note"]` to read only those; excluding a folder later never deletes the notes already made from it. `inkrelay doctor` warns when a source picks up exports under `Document` or `EXPORT`.

Password-protected notebooks and the oldest A5 format (before firmware C.053) aren't supported.

## Kindle Scribe

A Kindle Scribe shares a notebook by email: Share → Send to email sends a PDF (attached, or as a download link) from Amazon. With a `kindleMail` section in the config (setup adds it when you pick the Scribe), InkRelay asks Mail every 15 minutes for recent messages from Amazon that mention Kindle, saves each notebook's PDF into its own cache, and relays it like any other export. It reads nothing else and remembers which messages it has handled. Only mail sent from an address at one of `senderDomains` counts (a display name proves nothing), only https links on `linkDomains` are followed, a redirect off those hosts doesn't count, a link must turn out to be a PDF, and anything over 100 MB is refused before it downloads. A Kindle-looking email from another domain, or a link to another host, is named in the sync report once, so a real one is easy to add. macOS asks once to let InkRelay read Mail.

```json
"kindleMail": {
  "lookbackDays": 14, "checkEveryMinutes": 15,
  "senderDomains": ["amazon.com", "kindle.com"],
  "linkDomains": ["amazon.com", "amazonaws.com", "kindle.com", "a2z.com"]
}
```

These defaults haven't been checked against a real share email from every Amazon store yet; if yours comes from `amazon.co.uk` or links to another Amazon host, the sync report says what to add.

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
- **Ink only**: each notebook page's ink layer is pulled beside the rendered page and recognition reads that, so the template's "Name" and "Date …" stay out of your notes. The PDF keeps the full page. Memos and planner pages have no separate ink layer. `"recognizeInkOnly": false` turns it off.
- **What's there**: `inkrelay viwoods list` shows every app's folders and items (Learning and Knowledge Base too, which aren't pulled yet).
- **Daily planner**: each day with handwritten Tasks or Notes pages becomes `<cache>/Daily/<yyyy-MM-dd>.pdf`, which Obsidian and Notes receive like any notebook. Typed to-dos go straight to Apple Calendar.
- The cache is `~/Library/Application Support/InkRelay/viwoods` unless `cachePath` says otherwise, and it is a source of its own: notes land under `Ink/viwoods-cloud/…` in Obsidian.

The cloud is checked on every sync and, under `watch`, every `rescanIntervalSeconds`. Only changed notebooks are downloaded.

## Obsidian

Each export becomes `<vault>/Ink/<source>/<folder>/<title>.md` with the PDF beside it. Tasks written on the tablet (`☐ …`, `[ ] …`, `TODO …`) become Obsidian checkboxes, each with a block id (`^ink-…`) that stays the same across syncs, so the Tasks plugin and Dataview see them and links can point at them. Tick one in Obsidian and it stays ticked when the page syncs again.

Two extras, off unless you turn them on (Settings… in the app, or the config):

- `"dailyNotes": true` keeps a block in your daily note, in the folder and date format Obsidian's Daily Notes plugin is set to, with the planner page for that day, the notes you wrote that day and the open tasks found in them. The block sits between `%% inkrelay:daily:start %%` and `%% inkrelay:daily:end %%`; everything else in the daily note is yours.
- `"weeklyDigest": true` keeps `Ink/Weekly/<year>-W<week>.md`: the week's notes with page counts, its planner days, and every open task, rebuilt whenever a note from that week syncs.

In both, open tasks are links to the checkbox in their own note (`[[note#^ink-…|Call the bank]]`), not second checkboxes, so each task exists once.

## Planner pages from any tablet

A page named by date in a source's planner folder is a planner page, whatever tablet wrote it: it goes to Apple, Google or Outlook Calendar as "Daily plan" for that day, its review card is titled by the day, its tasks get that day as their due date, and it lands in that day's Obsidian daily note. The folder is `Daily` by default, which is how the Viwoods Cloud cache is laid out; for a Supernote, reMarkable or Boox planner notebook, name its folder:

```json
{ "id": "supernote", "path": "~/Dropbox/Supernote/Note", "fileTypes": ["note"], "planner": { "folders": ["Planner"] } }
```

Names like `2026-10-17`, `20261017`, `2026_10_17`, `2026.10.17`, `17 Oct 2026`, `Oct 17, 2026` and `October 17th 2026` are read anywhere in the file name ("Planner 2026-10-17" works). Day-month-year in numbers is ambiguous, so `17.10.2026` is read only with `"dateFormat": "dd.MM.yyyy"`. Setup asks for the planner folder for tablets other than Viwoods, and turns Apple Calendar on by default only when there is one.

## Apple Calendar

The `appleCalendar` destination takes only the Daily planner. A handwritten day page becomes an all-day event titled `Daily plan` with the full recognized text in the notes (with AI transcription on, its title for the page follows: `Daily plan: Gym and errands`). The first line of handwriting is too often misread to make a good title, and Vision is as sure of its misreadings as of the rest. Each typed to-do becomes an all-day event of its own, `☐ …` or `☑ …` by its state, with its priority in the notes. Events are updated in place when the page or to-do changes; one deleted in Calendar is recreated on the next change. The calendar named in the config is created if missing. macOS asks once to let `inkrelay` control Calendar.

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
- Empty pages get no card.
- `"shareWithPhone": true` puts the stack in the iPhone and iPad app too (see below). `setup` turns it on when you say you'll use InkRelay on a phone.

The page listens on 127.0.0.1 only and refuses requests whose Host isn't local. Every launch makes a new key, handed to the page in its address's `#` fragment (which browsers never send) and required on every API call and page image, so neither other websites nor other apps or users on the Mac can read or change your stack; the page also refuses to be framed. Open it from the menu or with `inkrelay review open`, which carry the key. It's kept, owner-only, in `review/.key`. Cards and their images live in `review/` next to the config.

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

## Recognition

Vision reads pages on the Mac, `recognition.concurrency` pages at a time (by core count, up to 4). `recognition.vocabulary` lists words Vision should expect, such as names, products and places; they win over the dictionary when the ink is close, which is the difference between "Erin" and "erin" or "Ensemble" and "Enseunble". `scripts/measure-pages.swift` shows what Vision reads from any PDF and how sure it is.

- **How good is it on your pages?** `inkrelay measure add SOURCE/PATH` puts an export's pages in a set beside the config (`measure/`) as drafts of what InkRelay reads now. Correct each draft to what the page really says and delete its first line. `inkrelay measure` then reads every page exactly as a sync would (vocabulary, ink-only copies, templates, and AI where a source uses it), prints word accuracy per page and in total, compares it with the last run and records the run in `measure/history.tsv`. `--show` prints each reading. Drafts are never scored, and the set holds your handwriting, so it stays on the Mac.

- **It learns from your corrections.** Fix a misread word inside InkRelay's block of an Obsidian note, and the next time that page changes on the tablet the word is learned before the block is rewritten: it goes into `vocabulary.json` beside the config and Vision expects it from then on. `inkrelay vocabulary` lists, adds and removes words.
- **Templates stay out.** Viwoods Cloud and Supernote notebooks are read from their ink layer alone. For any folder source, `"template": "~/Templates/cornell.png"` names a picture (or one-page PDF) of the blank template, and its lines and labels are taken out of each page before recognition.

## AI transcription (optional)

Three ways to keep it cheap: `"aiFolders": ["Daily"]` on a source sends only those folders to Claude (the planner, where titles matter) and lets Vision read the rest; `"aiMonthlyBudgetUSD": 2` caps one source inside the overall `ai.monthlyBudgetUSD`; `ai.batchSize` (default 4) sends several pages per request.

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
- Settings… sets everything up in a window when there's no config yet, with the same choices as `inkrelay setup`. Config and Logs open the files; Open at login uses macOS's login items, and the first launch from Applications asks once whether to turn it on.
- If the command-line agent from `scripts/install-agent.sh` is running, the app waits and offers to stop it, so notes aren't synced twice.
- The `inkrelay` command is inside the app at `InkRelay.app/Contents/Resources/inkrelay`.

## Notifications, updates and bug reports

- **Notifications** (menu bar app): a problem that wasn't there before, such as an expired Viwoods sign-in or a denied permission, gets one notification, not one per sync. `notifications.newNotes` adds a short note when pages sync. `notifications.reviewReminder` (`"09:00"`) posts "N cards to review" once a day. All of it is in Settings… too.
- **Updates**: the app looks for a newer release once a day and shows it in the menu; **Check for Updates…** does it now. `inkrelay update check` from the terminal. Nothing about your Mac is sent; it's one request to the release feed. A feed that can't be read says so rather than "up to date". `"checkForUpdates": false` turns it off.
- **Sync log**: the app writes every pass to `~/Library/Logs/InkRelay/inkrelay.log` (when, why, the summary, each warning and failure); **Open Logs** opens it. Every process that syncs also leaves the last pass in `last-sync.json` beside the config, which `inkrelay status` and the MCP server report.
- **Bug reports**: **Export Diagnostics…** (or `inkrelay diagnostics [--apps]`) writes one zip with versions, `doctor`'s checks including sign-ins (and, from the app or with `--apps`, whether Notes, Calendar and Reminders allow InkRelay), why a config or state file didn't load, your config with every secret and address replaced, counts from the sync state, the last pass and the last few hundred log lines. The home folder, email addresses, cloud account names and the licensee's name are taken out. No note text, tokens or keys.

## iPhone and iPad

For people without a Mac running all the time. The app in `iOS/` (open `iOS/InkRelayMobile.xcodeproj`, or `scripts/build-ios.sh --run` for the simulator) shares `InkRelayCore` with the Mac.

- Choose the folder your tablet exports to, through the Files app, so iCloud Drive, Google Drive, Dropbox and OneDrive all work. Handwriting is read on the device with Vision; nothing is uploaded.
- **Check for New Notes** reads what's new or changed since the last check.
- Apple Notes has no API on iOS either, so the app hands notes to Shortcuts: **Get New Ink Notes** returns one text per note with the title on the first line; follow it with **Repeat with Each** and **Create Note**, and run it from an automation. **Recognize Handwriting** reads any PDF or image shared to it.
- **Sync with your Mac**: with `"sharedLedger": {}` in the Mac's config (setup offers it), the Mac keeps a small `ledger.json` in iCloud Drive/InkRelay of what it filed into Apple Notes. Pick that same folder in the app, and each side skips what the other already filed, so a note never lands in Notes twice. Obsidian and the other Mac destinations still get everything. Whichever device sees a new version of an export first files it.

- **Review**: with `"shareWithPhone": true` on the Mac's `reviewStack`, the Mac copies the stack (`stack.json` and the page images) to `Review/` in iCloud Drive/InkRelay after every sync, or to `shareFolder` if you set one. Pick that folder in the app, and the Review tab shows today's cards one at a time: swipe right or tap **Done**, swipe left or tap **Later**, and **Add to Calendar** for a suggested event when the Mac has a calendar. Each phone writes its choices to a file of its own (`decisions-<device>.json`) and the Mac applies them on its next pass, so iCloud never has two versions of one file to reconcile. Cards you decide leave the phone at once; a card whose page changed in the meantime comes back as new.

The project signs with the team set in `iOS/project.yml`; run it on a device from Xcode, which creates the provisioning profile the first time. The shared ledger is a plain file, so it needs no iCloud entitlement.

## Use with AI assistants (MCP)

`inkrelay mcp` is a [Model Context Protocol](https://modelcontextprotocol.io) server, so Claude and other AI assistants can work with your handwritten notes: "what did I write about the bank last week?", "list my open tasks", "go through today's review stack with me", "send this article to my tablet".

InkRelay keeps the recognized text of every note it relays in `archive/` next to the config (notes synced before 0.5.0 are read once more with Vision on the next sync to fill it). The server reads that archive and InkRelay's state; it runs on your Mac and talks to the assistant over stdio, so nothing goes anywhere the assistant doesn't take it.

| Tool | What it does |
|---|---|
| `inkrelay_status` | Sources, destinations, last sync, searchable notes, review cards due |
| `inkrelay_list_notes` | Notes newest first, with a preview; paged |
| `inkrelay_search_notes` | Notes containing every word of a query (case and accents ignored), with the matching page and a snippet |
| `inkrelay_get_note` | One note's full text page by page, its tasks, where it was delivered and the original file |
| `inkrelay_list_tasks` | Tasks written on pages, open, done or all, with due dates |
| `inkrelay_review_stack` / `inkrelay_review_card` | Today's read-later cards; mark done, later, or accept a suggested event into your calendars |
| `inkrelay_sync_now` | Runs one sync pass (waits for one the app or agent is running) |
| `inkrelay_send_to_tablet` | Sends a link or a file to the tablet through a send target |

**Claude Desktop**: Settings → Developer → Edit Config, then add (use the path where your `inkrelay` is; inside the app it's `InkRelay.app/Contents/Resources/inkrelay`):

```json
{
  "mcpServers": {
    "inkrelay": { "command": "/Applications/InkRelay.app/Contents/Resources/inkrelay", "args": ["mcp"] }
  }
}
```

**Claude Code**:

```bash
claude mcp add inkrelay -- /Applications/InkRelay.app/Contents/Resources/inkrelay mcp
```

Add `--config PATH` after `mcp` to use another config. Sync passes from the server, the menu bar app, `watch` and `sync` take turns through a lock, each starting from the state the last one saved.

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
- An export with nothing written in it yet (no text and next to no ink on every page) isn't filed anywhere. It's filed once someone writes in it. A note that was already filed keeps following its export, even if the ink is erased.
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

Notes for whoever works on InkRelay next (current state, architecture, decisions, measurements on real data, how to test each part, the Viwoods Cloud API and the market research) are in [docs/](docs/README.md). Start with [docs/handoff.md](docs/handoff.md).
