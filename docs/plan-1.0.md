# Path to 1.0

Written October 16, 2026. What "professional grade" means for InkRelay, where it stands, and the order of work to get there. The market facts come from [research/market-scan-2026-10.md](research/market-scan-2026-10.md); the current state from [handoff.md](handoff.md).

## What the market says, and what it asks of the product

1. **Every vendor ships a cloud and a Drive export; none reach Apple Notes, a calendar, Notion or OneNote.** Third parties cover one vendor each, Obsidian only (Scrybble, €22–40 a year). The opening is the matrix: any tablet, any destination. InkRelay has the matrix. What it lacks is proof it holds up: most routes have never run against a real account.
2. **People pay yearly for single-purpose tools:** reMarkable Connect $39.90, Scrybble up to €40, Matter $79.99. A one-time $29 Pro unlock undercuts all of them and fits a tool that costs nothing to serve. That needs a license, a trial, a buy page and a signed download. None exist yet.
3. **The read-later category just lost Pocket and Omnivore.** The review stack is the feature no vendor plugin will copy. It exists on the Mac and the phone; it has no daily pull (nothing nudges you), and no way to see what you wrote this week.
4. **A vendor could add calendar or Apple Notes sync tomorrow.** reMarkable competes on software. Cross-vendor reach and the review mode are the moat; recognition quality is the thing people notice first.
5. **Privacy is the honest differentiator.** On-device recognition, no server. Every feature should keep that true by default.

So a buyer judges InkRelay on six things:

| Dimension | What "pro" means | Where 0.7.0 stands |
|---|---|---|
| Runs itself | Syncs for months without attention; tells you when it needs you, and only then | Syncs; problems sit silently in a menu |
| Reads well | Clear handwriting comes out right; templates and empty pages don't pollute notes | Vision is good on clear writing; template text leaks in; names are misread |
| Fits your system | Notes land where you'd put them yourself; daily notes, calendars, tasks | Notebooks and planner go to the right apps; no daily-note integration, no weekly view |
| Private | Nothing leaves the Mac unless you turn it on | True |
| Buyable | Trial, license, price, signed download, a page that explains it | Drafts only; ad-hoc signed builds |
| Supportable | Diagnostics, docs, updates | `doctor`; no update check; no way to send a bug report |

## Milestones

### 0.8.0 "Runs itself" (this round)

| # | Feature | Why | Scope |
|---|---|---|---|
| 1 | **Pro license and 14-day trial** | Without it there is nothing to sell. Keys are signed offline (Ed25519), so no server and no phoning home. | `License`, `Entitlement`, `license.json`; `inkrelay license`; Enter License in the app; `scripts/make-license.swift` for the owner. Free: folder sources, Obsidian, Apple Notes, Calendar, Reminders. Pro: cloud sources, Google, Microsoft, Notion, AI transcription, review stack. When the trial ends, Pro parts pause with one clear line; nothing is deleted, and they resume when a key is entered. |
| 2 | **Notifications** | A sync tool that fails silently is worse than none. | Problems that need you (expired sign-in, denied permission), coalesced; optional "new notes synced"; a daily "N cards to review" at a time you pick. Off by `notifications` in the config. |
| 3 | **Check for updates** | Nobody re-downloads zips by hand. | Daily check of the release feed, "Check for Updates…" in the menu, `inkrelay update check`. Opens the download page; no self-replacing binary until releases are signed. |
| 4 | **Export diagnostics** | Support without a diagnostics bundle is guesswork. | One zip: versions, `doctor` output, config with secrets removed, state counts, recent log. `inkrelay diagnostics`, Export Diagnostics… in the app. |
| 5 | **Faster, better recognition** | Multi-page notebooks take minutes; names come out wrong. | Pages recognized in parallel; `recognition.vocabulary` feeds Vision's custom words (names, products, places). |
| 6 | **Ink only, not the template** | Paper templates print "Name" and "Date …", and they end up in every note and card. | Viwoods Cloud pulls the ink layer beside the rendered page; recognition reads the ink, the PDF keeps the full page. |
| 7 | **Obsidian daily notes and a weekly digest** | Obsidian users live in their daily note. A week-in-review is the review stack's natural companion. | A managed block in the vault's daily note (its own folder and date format) with the planner page, the notes written that day and open tasks. `Ink/Weekly/2026-W42.md` with the week's notes, tasks and planner days. |
| 8 | **Settings you can come back to** | Setup runs once and then it's JSON. | Settings… opens prefilled from the config and keeps the sections it doesn't show. New toggles for daily notes, digest and notifications. |
| 9 | **Landing page 2.0** | The current page is a waitlist card. | Hero, how it works, the compatibility matrix, review stack, privacy, pricing with the trial, FAQ, download. Visuals made in Canva. |
| 10 | **User guide** | The README has grown into a reference; buyers need a path. | `docs/user-guide.md`: install, first sync, each feature with its config, troubleshooting. |

### 0.9.0 "Reads better"

- AI transcription for the planner only (meaningful event titles without paying for every page), batching pages per request, a per-source budget.
- Ink-only recognition for Supernote (layers are already separate) and for folder exports with templates (subtract a known template image).
- Language per page: Vision's automatic detection when a page isn't the configured language.
- A "fix this word" loop: corrections in Obsidian feed `vocabulary`.
- Knowledge Base and Learning from Viwoods Cloud.
- Boox and reMarkable: verified with real exports (#3); reMarkable Cloud if an account appears (#23).

### 1.0.0 "Sellable"

- Developer ID signing and notarized releases through the existing workflow (needs the owner's App Store Connect key; one command).
- A buy page: Lemon Squeezy or Paddle issuing keys from `make-license` through a small webhook, or by hand at launch volume.
- iPhone and iPad on TestFlight.
- Bundled Google and Microsoft client ids (verified apps), so people stop creating OAuth clients.
- The landing page live with the download and the matrix; the community posts out; the waitlist answers folded into pricing.
- Localization of the app's strings if sign-ups say so.

## Measures

- Trial starts → licenses (target 5% at launch).
- Sign-ups by tablet and destination from the landing page.
- Recognition: word accuracy on a fixed set of real pages (`scripts/measure-pages.swift`), before and after each change.
- Support: diagnostics bundles received per 100 users; problems that needed a human.

## Not doing, and why

- **Two-way sync** (edits in Obsidian back to the tablet): no tablet exposes an API for it, and PDFs are not editable ink.
- **A server**: nothing in the product needs one. Licenses verify offline; phones share through iCloud Drive.
- **DRM**: the trial is a date in a file. Someone who deletes it to extend the trial was never going to pay; the honest majority gets a product that never calls home.
- **Google Keep**: no API for personal accounts.
