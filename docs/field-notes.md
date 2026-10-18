# Field notes

What was learned by running InkRelay against real data and real apps. Numbers are from the owner's Viwoods AiPaper account and Mac in October 2026, unless noted. `scripts/measure-pages.swift` reproduces the page measurements.

## Recognition on real handwriting

- **Vision on clear handwriting is usable, on messy lines it isn't.**
  - Read correctly: "Ensemble / Service Bus sending / Setup the diag rome for erin", where the page says "Setup the diagram for Erin".
  - Read as noise: lines like "ter", "6304552958#4" and "Consumption mye".
- **Confidence doesn't separate good lines from bad.** `VNRecognizedText.confidence` is 1.00 for almost every line, misreads included ("ter" 1.00). It only occasionally drops to 0.50 or 0.30. Don't use it to filter.
- **Spell checks don't either.**
  - `/usr/share/dict/words` (Webster's Second, 1934) lacks "intro", "midterm" and "Microsoft", so it would drop good titles.
  - `NSSpellChecker` in automatic-language mode accepts "ter", "те", "mye", "Zere" and "Reut".
  - That's why planner events are titled "Daily plan" ([decisions.md](decisions.md)).
- **Template text is recognized as content.** Paper templates print "Name" and "Date 10/02/2025 01:43 PM", and they show up in the note text. The cloud's `mainBmp_` layer has the ink without the template and is the obvious next thing to try.
- **Scripts:** Vision sometimes returns Cyrillic letters ("те") for Latin handwriting even with `en-US` set.

## Ink layer (0.8.0)

- Viwoods Cloud's `mainBmp_<page>.png` is the ink alone on a transparent background; composed on white it recognizes cleanly. On the owner's three Paper notebooks, the template lines ("Name", "Date 11/05/2025 03:22 PM") vanished from the recognized text; the handwriting itself read about the same. Memos and planner pages have no separate layer.
- Pulling the layer added one download per page the first time (≈18 s for 24 items against ≈40 s for the first pull in 0.6.0, on the same account; the cloud was warm).
- Five printed words on five pages, read with `concurrency: 3`, came back in page order every run.

## Blank pages

Share of pixels darker than 150 of 255:

| Page | Ink coverage |
|---|---|
| Empty memo, two empty planner days | 0.00000 |
| Second page of a planner day, empty | 0.00002 |
| One small word (synthetic, four 3-pixel strokes) | about 0.0002 |
| Two short lines ("Microsoft / 1. Compled set up") | 0.0067 |
| Ordinary pages | 0.013–0.063 |
| A sketch with no recognizable text | 0.12 |

- **The rule:** blank means no recognized text and coverage under 0.0001.
- **How it's measured:** at half size with nearest-neighbour sampling, so thin strokes stay dark. A smoothed downscale washes them out.

## The owner's vault

- On October 16 the owner moved InkRelay's `Ink` folder inside their vault to `Resources/Inbox/Ink` (a PARA layout). They changed the config's `folder` to match, so updates reach the moved notes instead of recreating `Ink/` at the root. Obsidian's note paths in the state (`externalID`) still say `Ink/…`; the destination computes the new path from the config and merges with what's there, so nothing had to be rewritten.

## Viwoods Cloud data

- Cloud times are milliseconds. Before 0.6.0, pulled PDFs carried the pull time, so every note looked written on the day of the first sync.
- The home screen counts include folders and templates.
- The owner's account at the first pull:
  - Paper 8 listed, 3 notebooks;
  - Meeting 1 listed, 0 notebooks;
  - Knowledge Base 3, Learning 0, Memo 1;
  - 20 planner days in the last 12 months.
- A day page and a notebook page are both about 1440 × 1920 PNGs. Composed at 0.5 pt/px, that's 10 × 13.3 inches.

## Apple Notes through AppleScript

- **Reading a note's folder needs an explicit `get`:** `get name of (get container of note id X)`. The plain form `name of container of note id X` fails with -1700 even for a live note.
  - Before 0.6.0, the Recently Deleted check silently never matched, so a note deleted in Notes was updated where it sat and never came back.
  - `account of container of theNote` fails with -1728, so archiving failed too.
  - To find a note's account, walk up with `get container` while the class is `folder`, because folders nest.
- **A deleted note is still there to AppleScript:** it lives in Recently Deleted, `exists note id X` stays true, and its container is named "Recently Deleted".
- **Updating it there fails** with "Can't modify a note in Recently Deleted" (-10000).
- **Arguments:** 208,028 characters of mixed Latin, Unicode, CJK, Arabic and emoji went through `osascript` arguments without trouble.
- **Accounts:** the owner's Mac has iCloud (the default) and Google, and no On My Mac. The round trip passes on both.

## Platform gotchas

- **AppleScript embedded in Swift:** in a multi-line string, `\\(` written to escape an interpolation breaks the script. The tests compile every shipped AppleScript with `osacompile` exactly as it ships.
- **`XMLDocument`:** a relative XPath (`.//p`) on an element matches the whole document. Walk the subtree yourself and match elements with `local-name()`.
- **libtidy** (behind `XMLDocument`'s HTML option) strips HTML5 elements. `Article.markSections` renames them to `<div data-ink-tag="…">` first.
- **File dates:** cloud files can have modification dates in the future (the cloud's clock is ahead). The settle wait only applies when a file's age is 0 or more, or such files would wait forever.
- **macOS has no `timeout` command.** To probe an app that might show a permission dialog, run `osascript` in the background, wait a few seconds and kill it.
- **Bash 3.2** (macOS's) under `set -u` fails on an empty array. Write `${ARR[@]+"${ARR[@]}"}`.
- **Swift regex literals** with spaces need the extended form `#/…/#`.
- **iOS 17:** `IntentFile`'s `supportedContentTypes` parameter needs iOS 18, so the app leaves it out.
- **CSS:** a `display` rule overrides the `hidden` attribute. The review page has `[hidden]{display:none!important}`.
- **CLI arguments:** `--config` before the subcommand used to be read as the subcommand. It's removed from the arguments after parsing.
- **Main-actor state:** a main-actor static read from a nonisolated context doesn't compile. `BarModel.launchConfigURL` is `nonisolated`.
- **FSEvents late notices:** FSEvents can report a file written just before the stream started. `RelayRunner` then runs a second pass, so tests read the snapshots published through `onChange` instead of reading `snapshot` mid-pass.
- **WKWebView storage:** a `WKWebView` keeps its own website data, so the sign-in window doesn't see Safari's or Chrome's Viwoods session; the user signs in once in the window.

## Permissions and automation

- macOS asks once per controlling app for Notes, Calendar and Reminders. The menu bar app asks for itself; the terminal and the launch agent ask separately.
- Registering a login item (`SMAppService.mainApp.register()`) shows a system notice. The app asks before doing it.
