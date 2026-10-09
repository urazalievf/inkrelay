# InkRelay

Handwritten notes from any e-ink tablet, delivered into the notes apps you already use.

E-ink tablets (Viwoods, Supernote, Boox, Kindle Scribe, reMarkable) each sync to their own cloud, or to Google Drive, Dropbox and OneDrive. None of them reach Apple Notes, and each one reaches Obsidian through a different plugin, if at all. InkRelay watches the folder your tablet exports to, reads the handwriting on your Mac, and files each notebook into Apple Notes and Obsidian. When you add a page on the tablet, the same note updates.

```
tablet ──export──▶ Google Drive / Dropbox / OneDrive / iCloud Drive folder on your Mac
                                │
                     inkrelay watch (FSEvents + periodic rescan)
                                │
                  Vision handwriting recognition, on device
                                │
               ┌────────────────┴────────────────┐
          Apple Notes                       Obsidian vault
     (folder "Ink", via AppleScript)   (Markdown + original PDF)
```

## Status

Version 0.1.0 is a command-line tool and background agent for macOS. A menu bar app, more destinations and an iPhone app are planned. See the [issues](../../issues) and [milestones](../../milestones).

| Piece | State |
|---|---|
| Folder sources (any tablet that exports PDF or PNG) | Working, covered by tests |
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
- Obsidian notes are regenerated when the export changes, so **edits you make to them in Obsidian are overwritten**. Edit in Apple Notes, or copy the text out.
- Deleting an export doesn't delete its notes.
- State lives in `~/Library/Application Support/InkRelay/state.json`. Delete it to re-send everything.

## Permissions

- **Apple Notes**: macOS asks once to let `inkrelay` (or Terminal, when run there) control Notes. Manage it later in System Settings → Privacy & Security → Automation.
- **Files**: cloud folders under `~/Library/CloudStorage` may prompt for access the first time.

## Development

```bash
swift test
```

`Sources/InkRelayCore` holds the library: config, scanning, sync state, recognition, destinations and the engine. `Sources/inkrelay` is the command-line tool. The Vision test renders a PDF and runs real recognition, so the first run takes about 30 seconds while the model loads.

Versions follow `MAJOR.MINOR.PATCH`, with a fourth number for bug-fix releases (`0.1.0.1`). The current version is `InkRelayCore.version`.
