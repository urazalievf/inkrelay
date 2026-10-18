# InkRelay user guide

InkRelay takes the handwriting on your e-ink tablet and files it into the apps you already use, on your Mac, without sending anything anywhere. This guide follows the order a new user meets things. The [README](../README.md) is the full reference.

## 1. Install

- **Mac:** download `InkRelay-<version>.zip` from the releases page, unzip, move `InkRelay.app` to Applications and open it. It lives in the menu bar; there's no Dock icon. macOS 14 or later.
- **Command line (optional):** the `inkrelay` command is inside the app at `InkRelay.app/Contents/Resources/inkrelay`. Add that folder to your PATH, or run it by its full path.
- **iPhone and iPad (optional):** the app in `iOS/` runs from Xcode on your own device until it's on TestFlight.

The first launch from Applications asks whether to open InkRelay at login. Say yes: InkRelay syncs only while it's running.

## 2. First setup

Click the menu bar icon and choose **Set Up InkRelay…**. It asks:

1. **Which tablet.** Viwoods, reMarkable, Supernote, Boox, Kindle Scribe or another one.
2. **Where the notes come from.** For a Viwoods AiPaper with Viwoods Cloud on, nothing else: InkRelay reads the cloud. For every tablet, you can also point it at the folder the tablet exports PDFs to (Google Drive, Dropbox, OneDrive or iCloud Drive on this Mac). Supernote `.note` files in that folder are read directly.
3. **Where the notes go.** An Obsidian vault, Apple Notes, Apple Calendar (planner pages and to-dos), Apple Reminders (tasks you write with a checkbox), and the review stack.
4. **Phone sharing.** If you'll use InkRelay on an iPhone or iPad, share through iCloud Drive.
5. **Notifications.** Problems, new notes, and a daily review reminder.

Save, and the first sync starts. With Viwoods Cloud, a sign-in window opens: sign in once, and InkRelay keeps the session fresh itself.

macOS asks once for permission to control Notes, Calendar or Reminders, the first time InkRelay files into each. Click Allow.

From the terminal, `inkrelay setup` asks the same questions and `inkrelay doctor` checks that everything is in place.

## 3. What a sync does

Every five minutes, and whenever a source folder changes, InkRelay:

- pulls new or changed notebooks, memos and planner days from Viwoods Cloud into a local cache;
- reads each new or changed export's handwriting on the Mac with Apple's Vision;
- files the text and the original PDF into each destination it hasn't reached yet;
- updates in place when a page changes, moves notes when you rename a notebook, and never duplicates.

The menu shows the last sync, any problems, how many review cards are waiting, and the most recent notes; click one to open it.

Things worth knowing:

- An empty page is skipped. An empty notebook isn't filed until you write in it.
- A note's title is the notebook's name. Planner days are named by date.
- In Obsidian, InkRelay rewrites only its own block (between `%% inkrelay:start %%` and `%% inkrelay:end %%`) and a few frontmatter keys. Write anything you like around it.
- Deleting an export on the tablet does nothing to your notes unless you set `onDelete` in the config (`archive` or `delete`; deletions go to the Trash or Recently Deleted).

## 4. Free and Pro

Free: export folders from any tablet, Obsidian, Apple Notes, Apple Calendar and Apple Reminders. Pro ($29, once): Viwoods Cloud, Kindle Scribe by email, Google Calendar and Docs, Outlook Calendar and OneNote, Notion, AI transcription, and the review stack on the Mac and the phone.

Every install starts with a 14-day Pro trial. The menu shows how many days are left. When it ends without a key, the Pro parts pause: the sync report says so in one line, nothing is deleted, and entering a key resumes them from where they stopped at the next sync, with no restart. **Enter License…** is in the menu; `inkrelay license enter INK1.…` from the terminal. Keys are checked on your Mac; InkRelay has no server.

## 5. The review stack

Every page InkRelay relays becomes a card: the page as written, the recognized text, and for planner to-dos the to-do itself. While the app runs, the stack is at <http://127.0.0.1:7788> (click **Review stack** in the menu).

- **Done** takes a card out; **Later** brings it back tomorrow morning. Swipe or use the keys D and L.
- A page comes back only when its ink changes. A to-do ticked off on the tablet leaves by itself.
- Lines that name a date and a time ("Dentist March 3 at 3pm") become suggested events; **Add to calendar** creates them.
- `resurfaceDays` (`[3, 14, 60]`) brings done cards back on that schedule.
- With phone sharing on, the same stack is in the iPhone and iPad app's Review tab. Choices made on the phone reach the Mac on its next sync.
- `notifications.reviewReminder` posts "N cards to review" once a day.

## 6. Obsidian extras

- **Daily notes.** With "Add to the vault's daily notes" on, your daily note (whatever folder and date format you've set in Obsidian's Daily Notes plugin) gets a block with the planner page for that day, the notes you wrote that day, and the open tasks found in them. Everything outside the block is yours.
- **Weekly digest.** `Ink/Weekly/2026-W42.md`: the week's notes, planner days and open tasks. Rebuilt whenever a note from that week syncs.

## 7. Calendars, reminders and tasks

- The Viwoods **Daily planner** goes to Apple Calendar (or Google or Outlook) as all-day events named "Daily plan", with the recognized text in the notes, and each typed to-do as its own event. **Any tablet's planner** works the same way: put day pages named by date (`2026-10-17`, `17 Oct 2026`…) in a folder and name it as the source's planner folder (setup asks).
- **Tasks you write** on any page, as `☐ …`, `[ ] …` or `TODO …`, become Obsidian checkboxes (tick them there and they stay ticked) and Apple Reminders. Ticking the box on the tablet completes the reminder. A date in the task ("by Friday", "March 3 at 3pm") becomes the due date.
- Google, Microsoft and Notion need an account of your own and a few config lines; the README explains each.

## 8. Sending things to the tablet

`inkrelay send LINK` turns an article into a clean EPUB and puts it where your tablet picks it up: a folder it syncs, a Kindle email address, or straight into Viwoods Cloud. `inkrelay send FILE.pdf` sends a document. Set `sendTargets` in the config once.

## 9. Better recognition

- **Names and words it keeps getting wrong:** fix them once inside InkRelay's block of the Obsidian note; the next time that page changes, the fix is learned and Vision expects the word from then on (`inkrelay vocabulary` shows what it learned). Or add words to `recognition.vocabulary` in the config.
- **Template text in your notes** ("Name", "Date …"): Viwoods Cloud and Supernote notebooks are read from the ink alone. For PDF exports, point `template` on the source at a picture of the blank template and its lines and labels are taken out before recognition.
- **Messy pages:** AI transcription (`"recognizer": "claude"` on a source, with your own Anthropic key and a monthly budget) reads harder handwriting and suggests titles and tags. `"aiFolders": ["Daily"]` limits it to the planner, where titles matter most, and `aiMonthlyBudgetUSD` caps one source. Page images go to Anthropic only for what you set this way.
- **Other languages:** `recognition.languages`, or an empty list to let Vision guess.

## 10. AI assistants

`inkrelay mcp` serves your notes to Claude and other MCP clients: search what you wrote, read a note, list tasks, work through the review stack, sync now, send an article to the tablet. Register it once (`claude mcp add inkrelay -- /Applications/InkRelay.app/Contents/Resources/inkrelay mcp`). It runs on your Mac and talks to the assistant over stdio.

## 11. When something's wrong

- **The menu shows a problem.** Click it to read the whole line. Expired sign-in: **Sign In to Viwoods…** in the menu. Denied permission: System Settings → Privacy & Security → Automation → InkRelay.
- **`inkrelay doctor`** checks folders, permissions, sign-ins, the plan and the background agent, and says what to fix.
- **Nothing syncs.** Is InkRelay running? Is the tablet's cloud sync on? With a folder source, has the Drive app downloaded the files (not just placeholders)?
- **A note is wrong or missing.** Delete `state.json` next to the config to send everything again; destinations update in place.
- **Reporting a bug:** **Export Diagnostics…** writes one zip to your Desktop with versions, doctor's checks, your config without its secrets, counts and recent logs. Attach it. It holds no note text.

## Where things are

| What | Where |
|---|---|
| Config | `~/Library/Application Support/InkRelay/config.json` |
| Sync state, archive of recognized text, review cards, caches | the same folder |
| Logs | `~/Library/Logs/InkRelay` |
| Shared with the phone | iCloud Drive/InkRelay |
