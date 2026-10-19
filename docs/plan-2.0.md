# Path to 2.0

Written October 19, 2026, the day v0.10.0 became the first signed release. [plan-1.0.md](plan-1.0.md) took InkRelay from a CLI to something that can be sold. This plan covers what comes next: getting it in front of buyers, the features still missing, and how it pays for itself. Market facts come from [research/market-scan-2026-10.md](research/market-scan-2026-10.md), and the current state from [handoff.md](handoff.md). Prices were checked on October 19, 2026. Check them again before quoting them anywhere.

## The goal

InkRelay costs its owner money every month: the Apple Developer Program, the tools it is built with, design work and soon a domain and payment fees. The first goal is for Pro sales to cover those costs. The second is a side income that grows with each tablet and feature added. Every item below is ranked by how much it moves one of three numbers: people who can download InkRelay, people who pay for it, and people who keep paying.

## Where InkRelay stands

- **What's built.**
  - Sources: folder exports from any tablet, Viwoods Cloud, Supernote `.note` files and Kindle Scribe by email.
  - Destinations: Obsidian, Apple Notes, Calendar and Reminders, Google Calendar and Docs, Outlook Calendar, OneNote, Notion and the review stack.
  - Also: sending articles to the tablet, Obsidian daily notes and a weekly digest, review on iPhone and iPad, an MCP server, and a Pro license with a trial.
- **What's proven on real data:** one tablet (Viwoods) going into Obsidian, Apple Calendar and Apple Notes. Everything else passes tests against fixtures but has never run against a real account or a real export (see "Never checked for real" in [handoff.md](handoff.md)).
- **Who has bought it:** nobody yet. v0.10.0's download, the site's button and the update feed point at the private repository, so anyone but the owner gets a 404. #74 moves them to the public `urazalievf/inkrelay-releases`; 0.10.1 is the first public build.

InkRelay is wide but thin. The breadth is real, but only one tablet has been proven.

## Positioning: priced like Readwise, not like Scrybble

Scrybble does one route, reMarkable to Obsidian, for €22–40 a year. InkRelay takes notes from any tablet to any notes app, adds a review mode and also sends reading the other way. The right comparison is with products that combine several jobs:

| Product | What it combines | Price |
|---|---|---|
| Readwise (Full) | Highlights from many sources into many notes apps, a daily review, a read-later app | $9.99 a month billed yearly ($119.88), $12.99 billed monthly. Lite is about $5.59–6 a month ([Readwise help](https://help.readwise.io/article/27-how-much-does-readwise-cost), [Readless](https://www.readless.app/blog/readwise-reader-pricing-2026)) |
| Imprint | Bite-sized visual cards, two minutes a chapter, about $450K a month in revenue (market scan) | App Store lists $15.99 a month and $74.99–99.99 a year ([App Pricing Lab](https://apppricinglab.com/iap/apple/1482780647), March 2026 snapshot) |
| Matter | Read-later with Kindle | $79.99 a year |
| reMarkable Connect | Cloud retention for one vendor | $39.90 a year |
| Scrybble | reMarkable into Obsidian | €22–40 a year |

InkRelay is shaped like Readwise: many sources, many destinations and a daily review on top. That supports a price above Scrybble's, with two cautions:

1. **Buyers judge the one route they came for.** Someone with a reMarkable who wants Notion doesn't care that Viwoods to Apple Calendar works. Breadth earns a higher price only if each buyer's own route works on day one. That is why Phase 0 verifies routes before Phase 2 adds features.
2. **Readwise and Imprint charge for value people get every day,** a daily review and new content. InkRelay earns a yearly price the same way. The features people use daily are the ones in Phases 2 and 3: key-idea cards, recall, search, the morning page and widgets. Setup is a one-time job.

## Pricing

| Tier | Price | What's in it |
|---|---|---|
| Free | $0 | Same as today: folder sources, Obsidian, Apple Notes, Calendar and Reminders, on-device recognition. It shows that any tablet works. |
| Pro | **$39 a year** (about $3.25 a month) | Same as today plus every new Pro feature in this plan: cloud sources, Google, Microsoft and Notion, the review stack on Mac and phone, daily notes and the digest, send to tablet, AI with your own key, and Phase 2's on-device features. |
| Founder (launch only) | **$79 once**, first 200 buyers | Lifetime Pro. It brings in money and supporters early, and the cap keeps it from replacing renewals. |
| Pro + AI (Phase 4, only if people ask) | about $7.99 a month | Hosted transcription and summaries with a monthly page allowance, so nobody needs their own Anthropic key. It's the only tier that needs a server, which is why it's billed monthly. |

**Why a yearly price instead of a one-time $29.** Unofficial clouds (Viwoods now, reMarkable next) break when vendors update them, and fixing them is work that continues after the sale. Renewals pay for it.

**Why not monthly Pro.** Keys are checked offline, so a monthly plan would mean either a new key every month or a server check. Yearly keys keep InkRelay serverless and never phoning home. The license already carries an expiry date (`expiresOn`, 0.10.0), so the app needs no change. Only the key issuer needs to handle renewals.

## What it costs to run, and break-even

| Cost | Amount |
|---|---|
| Apple Developer Program | $99 a year |
| Payment fees (Lemon Squeezy) | about 5% + 50¢ an order (check the current rate) |
| Site and downloads | $0 (Cloudflare Pages and a public releases repository) |
| Domain | about $15 a year for a `.app` domain, once registered |
| Tools it's built with (Claude, Canva Pro) | the owner's own plans |

A $39 Pro year brings in about $36.50 after fees. The Apple fee alone needs 3 Pro subscribers. Every further $100 a month of costs needs about 33 more.

## The phases

The versions follow the project's version rules, where a new feature means a MINOR bump. Phase 0 finishes plan 1.0's "1.0.0 Sellable" milestone, so the launch is 1.0.0. Each phase ends with a gate: a number that shows whether the next phase is worth building. The week counts assume October's pace and are a guide, not a promise.

### Phase 0: 1.0.0 "Open doors" (weeks 1–2), sell what exists

Nothing new gets built until a stranger can download InkRelay, try it and buy it.

| # | Item | Why | Scope |
|---|---|---|---|
| 1 | Public downloads and update feed | Everything else depends on it | A public releases repository: `urazalievf/inkrelay-releases`, created October 19, wired up in #74. The release workflow publishes there, and `UpdateChecker.feed` and the site point at it |
| 2 | Site live with a checkout and a waitlist | The page exists, but nobody can reach it | `site/` on Cloudflare Pages. A Lemon Squeezy store selling Pro yearly and Founder. A form service for `WAITLIST_ENDPOINT` that records tablet, destination and computer (Mac, Windows, or phone only) |
| 3 | Yearly keys and renewals | The issuer only handles one-time orders | `scripts/issue-licenses.swift` gives subscription orders a key with `expiresOn` one year out, and a new key at each renewal. The trial-ended panel also covers "Pro expired, renew" |
| 4 | Verified routes, labeled in the matrix | Buyers judge their own route | Run Google Calendar and Docs, Outlook, OneNote, Notion, Reminders and Kindle email against real accounts. The site's matrix labels each route verified or beta |
| 5 | Built-in Google and Microsoft sign-in (#53) | Asking buyers to create their own OAuth client loses most of them | Register the apps once as the publisher. Start Google's review early in case the scopes need verification, which can take weeks |
| 6 | Beta testers on other tablets (#3) | No reMarkable, Boox or Kindle export has ever been tested | 10–20 testers from the community posts, at least one per tablet. Each gets a free Pro year in exchange for exports and diagnostics |
| 7 | Name check, then the posts (#19) | Spending money on a name that can't be kept is waste | Check trademarks and the App Store for "InkRelay", then post the drafts in [launch/community-posts.md](launch/community-posts.md) |

**Gate:** strangers can download it, at least three tablets are verified with testers' real exports, and within a month of posting there are 150 waitlist sign-ups or 10 paid orders. If it falls well short, read the waitlist answers before building more.

### Phase 1: 1.1.0 "Every tablet" (weeks 3–6), reach

The waitlist tally sets the order inside this phase. reMarkable probably comes first: it has the most users, and the most people already paying for a sync tool.

| # | Item | Why | Scope |
|---|---|---|---|
| 1 | Read reMarkable Cloud directly (#23) | It's the biggest tablet, and its export is manual | Sign-in with a device pairing code. The community-documented sync API (as rmapi uses it) and `.rm` v6 stroke files (as rmscene reads them), drawn to PDF. Ink-only recognition comes free, because strokes carry no template. Labeled beta, with the folder route as the fallback |
| 2 | Read Supernote Cloud directly | Today Supernote needs an export folder | Same pattern as Viwoods Cloud. `.note` decoding already exists |
| 3 | Boox | Its cloud is unknown | Verify the Dropbox, Google Drive and OneDrive folder routes with a tester. Build a cloud connector only if a tester has one and the waitlist asks for it |
| 4 | Viwoods Knowledge Base and Learning (#51) | It finishes the first tablet | Pull them once their item format shows up on a real account |
| 5 | Task apps for to-dos | People keep to-dos in task managers, not calendars | Todoist (API), Things (URL scheme), Microsoft To Do and Google Tasks (the Microsoft and Google accounts people already sign into) |
| 6 | More notes apps | Each one is a line on the waitlist | Logseq (a Markdown folder, mostly Obsidian's code). Bear (x-callback-url). Day One, so handwritten journals become journal entries. Readwise, with pages sent as highlights so Readwise users see their ink in their daily review |

**Gate:** reMarkable is verified by at least three testers, and at least 5% of trials turn into paid licenses.

### Phase 2: 1.2.0 "Ink that thinks" (weeks 6–10), the Imprint layer

This phase makes InkRelay more than a pipe, and it's what the yearly price pays for. Plan 1.0's rule stays: everything runs on the device by default, and a cloud model only when the user turns it on.

| # | Item | Why | Scope |
|---|---|---|---|
| 1 | Key-idea cards | Imprint's format, applied to your own notes | Each notebook or meeting becomes 3–5 cards, each with a title, one idea in a sentence or two, and a crop of the page it came from. These use Apple's on-device Foundation Models framework on Macs and iPhones with Apple Intelligence (macOS 26, iOS 26), or Claude with the user's key. Elsewhere the stack keeps today's plain page cards |
| 2 | Recall cards and spaced repetition | It turns review into learning, for students and professionals who study on tablets | Question and answer cards made from notes, scheduled on the existing spaced resurfacing, with Anki export |
| 3 | Search by meaning | Finding "the page where I sketched the pricing idea" | On-device sentence embeddings from Apple's NaturalLanguage framework. A search box on the Mac and the phone, and the MCP server's search uses it too |
| 4 | Links and tags | Notes arrive connected instead of loose | People, projects and dates become Obsidian links and tags, and each new page links to the vault notes closest to it |
| 5 | Drawings, math and tables | Recognition turns sketches into garbage text today | Sketched regions stay in the note as images. With AI on, math becomes LaTeX and tables become Markdown tables |
| 6 | Language per page | It was on plan 1.0's 0.9.0 list and never built | Vision detects the language when a page isn't in the configured one |

**Gate:** at least 40% of Pro users review at least one card a week.

### Phase 3: 1.3.0 "Daily ritual" (weeks 10–14), the habit

Renewals come from habits. These features give people a reason to open InkRelay every day, and they connect the tablet and the calendar in both directions, which no vendor does.

| # | Item | Why | Scope |
|---|---|---|---|
| 1 | Morning page on the tablet | The tablet becomes where the day starts | Each morning a one-page PDF lands on the tablet with today's events, cards due, open to-dos and one saved article. Built on `inkrelay send` and the calendar destinations |
| 2 | Calendar into the planner | Planner pages already go to the calendar, and this goes the other way | Today's events printed onto the planner template the tablet uses, starting with Viwoods Daily, so the handwritten plan starts from the real calendar. It's sent as a document if the tablet's own planner can't be written to |
| 3 | Widgets and a gentle streak | The phone needs a daily reason to open the review stack | Home Screen and Lock Screen widgets showing today's card and the number due, and a review streak with a weekly goal and no nagging |
| 4 | Send to tablet from anywhere | Sending today needs the CLI or the Mac | A share extension on iPhone, iPad and Mac |
| 5 | Reading packs | It fills the gap Pocket and Omnivore left | Feeds and newsletters bundled into a weekly EPUB for the tablet |
| 6 | Listen to your week | A review that fits a commute | The weekly digest and due cards read aloud with on-device speech |

**Gate:** half of Pro users use the morning page or a widget every week.

### Phase 4: 1.x to 2.0 (month 4 on), beyond the Mac, only if the numbers call for it

Each item is a big bet. Build one only when the waitlist and sales call for it.

| # | Item | Build it when | Scope |
|---|---|---|---|
| 1 | iPhone without a Mac | More than 25% of the waitlist says "phone only" | The phone pulls cloud sources and recognizes with Vision. It writes Calendar and Reminders through EventKit, Obsidian through the vault folder and Apple Notes through Shortcuts. It syncs when opened and in background refresh. iOS 17 and later |
| 2 | Setapp | After launch, as a second channel | Setapp pays developers 70% of each member's fee, split among the apps that member used ([Setapp docs](https://docs.setapp.com/docs/distributing-revenue)). That suits a utility used every day. The Mac App Store is a poor fit, because Apple Notes automation needs sandbox exceptions |
| 3 | InkRelay Cloud and Pro + AI | More than 40% of sign-ups aren't on a Mac, or many trials stall at "add your Anthropic key" | A small hosted service. It moves notes from tablet clouds into Google, Microsoft and Notion for Windows, Android and web users, and runs AI with a page allowance. It's the first thing that needs a server, so it's opt-in, a separate tier, with its own privacy page |
| 4 | Teams and classrooms | Teams or schools ask for it | Shared meeting and class notebooks into a shared Notion or OneNote, priced per seat |
| 5 | Templates InkRelay reads reliably | Recognition errors stay the top complaint | Planner templates with fixed areas for the date, to-dos and events. Give them away, or sell them with template makers who already sell e-ink planners |

## Getting the word out

This isn't code, but growth depends on it.

- **Communities:** the drafted posts first. After that, one useful post a month (a field note, a template, a comparison) instead of ads.
- **Vendors:** Viwoods has no third-party ecosystem. Offer InkRelay as its bridge to Apple and Google apps and ask to be listed. Supernote's community is friendly to third-party tools.
- **Reviewers:** e-ink YouTube and blog reviewers get a free Pro year. Their audience is exactly the buyer.
- **Affiliates:** Lemon Squeezy's affiliate program, paying 20–30% to people who send buyers.
- **Product Hunt and r/macapps** when Phase 1 ships, so the launch includes reMarkable.

## Targets to steer by

These are goals, not forecasts. The dollar amounts assume yearly Pro at $36.50 after fees.

| By | Paying users | What it means |
|---|---|---|
| End of Phase 0 (early November 2026) | 10 | The Apple fee is covered and the checkout works |
| January 2027 | 100 | About $3,650 a year, enough to pay for the tools |
| April 2027 | 300 | About $11,000 a year, a real side income |
| October 2027 | 1,000 | About $36,500 a year |

## Measures

- Waitlist sign-ups by tablet, destination and computer.
- Trials that turn into paid licenses (target 5%, from plan 1.0), and the split between Founder and yearly buyers.
- How many routes in the matrix real users have verified.
- Recognition: word accuracy on the owner's page set (`inkrelay measure`), before and after each recognition change.
- The share of Pro users who review at least one card a week.
- Renewals after 12 months (target 70%).
- Support: diagnostics bundles per 100 users, and hours a week spent on support.

## Not doing, and why

Plan 1.0's list still holds (two-way sync, a server, DRM, Google Keep). Added to it:

- **Windows or Android apps before the waitlist asks.** A second platform doubles the work, and InkRelay Cloud (Phase 4) reaches those users for less.
- **Routes nobody can test.** A connector without a tester's real data ships as beta or not at all.
- **Ads.** Until the trial-to-paid rate is known, there's no way to tell whether paid traffic pays off.

## Risks

- **Unofficial clouds break.** reMarkable's API changes often. Keep the folder routes working, label cloud routes beta, and use diagnostics and quick releases to fix breakage within days.
- **One maintainer.** Every route adds support work. Doctor, diagnostics, the user guide and the verified and beta labels keep it down, and the yearly price pays for the rest.
- **On-device AI isn't on every Mac or phone.** Apple's Foundation Models need Apple Intelligence hardware and macOS 26 or iOS 26. Where they're missing, Phase 2 features fall back to the user's Claude key or to today's plain cards.
- **A vendor adds Apple or calendar sync.** No single vendor will cover other tablets, the review layer or the morning page, and that's the moat.
- **The name.** Checked in Phase 0, before any money is spent on it.

## Issues to open

Once the owner accepts this plan, each table row becomes an issue under milestones 1.0.0 to 1.3.0 on the "InkRelay roadmap" board (user project #8), the same way plan 1.0 became issues #38–#54. #53 already sits in 1.0.0.
