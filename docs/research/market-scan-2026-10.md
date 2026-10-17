# Market scan, October 2026

Copied from issue #22 (market scan of October 16, 2026) so it stays with the code, followed by issues #19 and #23 as they stand. Figures and prices are as found on that date, with their sources; re-check them before quoting them anywhere.

**The bet:** one tool that takes handwriting, highlights and plans from any e-ink tablet (Viwoods, reMarkable, Supernote, Boox, Kindle Scribe) and keeps them in sync with the Apple, Google and Microsoft notes and calendars people already use, with a read-later review mode on top.

## Market

- The e-ink tablet market is estimated at about $3.2B in 2025, growing to $6.1B by 2034 (7.8% CAGR), with note-taking tablets the largest segment at ~42% ([Market Intelo](https://marketintelo.com/report/e-ink-tablet-market), single report, methodology not shown). A vendor blog cites IDC for 6.4M e-note units in 2026, up 18.4% YoY ([VoxBooster](https://voxbooster.com/blog/e-ink-device-statistics-2026)); unverified.
- Current lineup: reMarkable Paper Pro, Paper Pro Move and the new Paper Pure, Kindle Scribe and Scribe Colorsoft, Supernote Manta and Nomad, Boox Note Air 6 C, Viwoods AiPaper and AiPaper Mini, iFlytek ([Knowledgelib](https://knowledgelib.io/consumer-electronics/e-readers/e-ink-tablets-note-taking/2026), [Layer3 Labs](https://www.layer3labs.io/gear/kindle-scribe-vs-remarkable)).

## What vendors ship

- Every vendor has its own cloud plus Google Drive / Dropbox / OneDrive export. reMarkable made those integrations free for everyone; Connect is $3.99/mo or $39.90/yr and mostly buys unlimited cloud retention ([reMarkable press release](https://news.remarkable.com/remarkable-announces-major-expansion-of-software-ecosystem-and-changes-to-subscription-service-3tol2e), [Templacity](https://templacity.com/?p=11944)). Viwoods Cloud is free with 10 GB (firmware 3.15).
- No vendor syncs to Apple Notes, Notion, OneNote or any calendar. Boox can run those apps because it is Android, but that is not sync.
- Kindle Scribe is the most closed: Send-to-Kindle in, notebook export by email out ([MPU forum](https://talk.macpowerusers.com/t/anybody-here-uses-an-eink-tablet-like-boox-supernote-or-remarkable-what-s-your-workflow/31906?page=4)).

## What third parties ship

- Obsidian plugins per vendor, nothing else: Scrybble (reMarkable, paid), reMarkable Round-Trip, reMarkable Tagged Sync (local transcription), Supernote Cloud Sync (unofficial, one-way) ([Obsidian community plugins](https://community.obsidian.md/plugins/scrybble.ink), [Supernote Cloud Sync](https://community.obsidian.md/plugins/supernote-cloud-sync), [dsebastien](https://www.dsebastien.net/i-built-an-obsidian-plugin-to-sync-my-remarkable-notes)).
- No Kindle Scribe → Obsidian path found. No tool for Apple Notes, Apple Calendar, Google Calendar or OneNote from any tablet.
- Read-later is in flux: Omnivore shut down in November 2024, Pocket in July 2025 ([Wallabag](https://wallabag.it/en/blog/2026/06/15/which-read-it-later-app-to-choose-in-2026/), [TechCrunch](https://techcrunch.com/2025/05/27/read-it-later-app-pocket-is-shutting-down-here-are-the-best-alternatives)). Matter charges $79.99/yr and integrates with Kindle; Readwise Reader has no e-ink device integration beyond Send-to-Kindle ([Mailist](https://mailist.app/blog/best-pocket-alternatives)).
- Imprint (Polywise) shows the format people pay for on the learning side: bite-sized visual cards, a chapter in two minutes, ~$450K/month revenue ([Screens Design](https://screensdesign.com/showcase/imprint-learn-visually), [Nibble review](https://nibble-app.com/blog/imprint-review)). Nobody applies that card format to a person's own handwritten notes.

## Platform access (what we can build on)

| Target | Access | Note |
|---|---|---|
| Apple Notes, Apple Calendar | No public API; AppleScript on a Mac | Already how InkRelay works. Means a Mac (or later an iPhone app with Shortcuts) is required. |
| OneNote, Outlook Calendar | Microsoft Graph, delegated `Notes.ReadWrite`, `Calendars.ReadWrite` | Works for personal Microsoft accounts ([Graph OneNote](https://learn.microsoft.com/graph/integrate-with-onenote)). |
| Google Calendar, Google Docs/Drive | Public APIs | Straightforward. |
| Google Keep | API is for Workspace admins only ([Keep API](https://developers.google.com/workspace/keep/api/guides)) | Not reachable for personal accounts. Drop from the plan. |
| Notion | Public API | Straightforward. |
| Tablet clouds | All unofficial (Viwoods mapped in #21; reMarkable and Supernote community-documented; Boox and Kindle unknown) | Breakage risk on every firmware/portal update. Folder export is the safe fallback for all of them. |

## Gaps worth filling (each is an issue)

1. Any tablet → Apple, Google, Microsoft notes and calendars from one app. Today it is Obsidian-or-nothing, one plugin per vendor. → #23
2. Planner pages and to-dos → calendar. Nobody does it; Apple Calendar shipped in #21, Google and Outlook next. → #24
3. A review mode for your own ink: notes, highlights and plans stacked as bite-sized cards you flip through later, Imprint style. → #25
4. The reverse direction: articles and documents into the tablet, filling the hole left by Pocket and Omnivore. → #26
5. Positioning and price: on-device recognition (nothing leaves the Mac) against Scrybble's €22–40/yr and Matter's $79.99/yr. Folds into #19.

## Risks

- Unofficial clouds break without notice; keep the folder route as the always-working path and treat cloud connectors as accelerators.
- Mac required for Apple targets until the iPhone app (#17) exists.
- A vendor could add Apple Notes or calendar sync themselves; reMarkable's move to free integrations shows they compete on software. Cross-vendor coverage and the review mode are the parts a single vendor won't copy.

## Since the scan

Every gap above now has code behind it:

| Gap | Where it stands |
|---|---|
| 1. Any tablet → Apple, Google, Microsoft (#23) | Folder exports from every tablet, Viwoods Cloud, Supernote `.note`, Kindle Scribe by email. Destinations: Obsidian, Apple Notes, Calendar, Reminders, Google Calendar and Docs, Outlook Calendar, OneNote, Notion. Missing: reMarkable Cloud read directly. |
| 2. Planner → calendar (#24) | Apple Calendar is checked on real data (20 planner days). Google and Outlook are built but untested against real accounts. |
| 3. Review mode for your own ink (#25) | Review stack on the Mac (0.3.0) and on iPhone and iPad (0.7.0), with spaced resurfacing and suggested events. |
| 4. Articles into the tablet (#26) | `inkrelay send` makes an EPUB or PDF from a link or file and puts it in a folder, a Kindle address or Viwoods Cloud. |
| 5. Positioning and price (#19) | Drafts in [launch/pricing.md](../launch/pricing.md), [launch/community-posts.md](../launch/community-posts.md) and `site/index.html`. Nothing posted yet. |

## Demand check still to do (#19)

- Ask in r/eink, r/Supernote, r/RemarkableTablet, r/Onyx_Boox and the Viwoods community which notes app people want their tablet notes in, and how they get them there today
- Landing page with a waitlist; count sign-ups by tablet and destination. Show the tablet × destination matrix (#23)
- Pricing: Scrybble charges €22–40 a year for reMarkable → Obsidian only; Matter $79.99/yr; reMarkable Connect $39.90/yr. Decide between a one-time purchase and a subscription, and whether the review mode (#25) is the paid tier
- Ask whether to-dos should be calendar events or reminders/tasks (#24), and whether people want articles sent to the tablet (#26)
- Name: a few small, unrelated GitHub repos are also called "inkrelay". Do a trademark and App Store name check before launch

Prepared: posts for r/eink, the brand subreddits, r/ObsidianMD and r/macapps with a tally table, pricing options, and a landing page whose waitlist records tablet and destination. Left: a form service for `WAITLIST_ENDPOINT`, hosting for `site/` (GitHub Pages needs a public repo or Pro; Netlify or Cloudflare Pages work), and posting.
