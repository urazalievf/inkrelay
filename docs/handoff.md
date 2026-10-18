# Handoff: where things stand

As of October 17, 2026, late evening CT. 0.8.0 is on `main` (PR #55). Version 0.9.0 is on branch `reads-better` in a draft pull request, waiting for the owner. The plan both rounds follow is [plan-1.0.md](plan-1.0.md).

## What's shipped

| Version | PR | What it added |
|---|---|---|
| 0.1.0 | initial commit | CLI (`init`, `sync`, `watch`, `status`), folder sources, Vision recognition, Obsidian and Apple Notes, launch agent script |
| 0.2.0 | #20 | Viwoods Cloud as a direct source (#21), Apple Calendar for the Daily planner |
| 0.3.0 | #27 | Review stack (#25), Google Calendar and Docs (#24, #11), Outlook Calendar and OneNote (#24, #10) |
| 0.4.0 | #28 | Renames and deletions, Notion (#9), AI transcription, tasks to Reminders, send to tablet (#26), `setup` and `doctor`, menu bar app (#5), release workflow, iPhone and iPad app |
| 0.5.0 | #29 | Supernote `.note` files, Kindle Scribe by email, Mac and phone sharing one ledger (#17), MCP server |
| 0.6.0 | #31 | Viwoods sign-in window in the app, one-command release setup, Apple Notes fixes found on real Notes (#2), cloud notes dated by when they were written |
| 0.7.0 | #36 | Review stack on iPhone and iPad (#32), blank pages skipped (#33), planner events titled "Daily plan" (#34), app asks once to open at login (#35) |
| 0.8.0 | #55 | Pro license and 14-day trial (#38), notifications (#39), update check (#40), diagnostics export (#41), parallel recognition and vocabulary (#42), ink-only recognition for Viwoods (#43), Obsidian daily notes and weekly digest (#44), Settings that reopen (#45), landing page 2.0 (#46), user guide (#47) |
| 0.9.0 | draft PR | Planner-only AI with batching and per-source caps (#48), Supernote ink-only and template subtraction for exports (#49), vocabulary learned from Obsidian corrections (#50), `inkrelay viwoods list` with Learning and Knowledge Base listed (#51, still not pulled), Lemon Squeezy key issuing script (#52, untested), TestFlight archive path and workflow job (#54, untested), plan in the MCP status, daily notes offered in setup when the vault has them |

257 tests, about 15 seconds (`swift test`); the longest ones draw pages and run real Vision. CI runs on pull requests only.

## Open issues

- **#48, #49, #50, #52, #54** close when the 0.9.0 draft PR merges. **#51** stays open: `inkrelay viwoods list` shows the owner's Learning and Knowledge Base apps are empty at the top level (the home screen's "Knowledge Base 3" is its tabs), so their item format is still unknown and nothing is pulled. **#53** (bundled OAuth client ids) needs the owner's registrations.
- **#3** Real exports from each tablet. Viwoods is checked with real notebooks through the cloud. Supernote is checked against public sample notebooks and the device's own PDFs. reMarkable, Boox and Kindle Scribe exports have never been seen.
- **#19** Demand and pricing. Drafts exist (`docs/launch/`, `site/`). Posting, a waitlist form service and hosting are the owner's.
- **#23** Connector matrix. Done except reading reMarkable Cloud directly: no account or device, and its API is unofficial and changes often.

Board: GitHub user project #8, "InkRelay roadmap". Status options: Todo, In Progress, Done.

Merging is the owner's call. `main` has no branch protection (that needs GitHub Pro on a private repo), so a merge goes through without review. Open pull requests and leave them for the owner. Before pushing more commits to a PR's branch, check that the PR is still open: a commit pushed after the merge never reaches `main`.

## The owner's Mac today

- **App:** `/Applications/InkRelay.app` 0.9.0 (build 90000), ad-hoc signed, built from branch `reads-better`; the 0.8.0 build is kept at `build/InkRelay-0.8.0.app` in the repo folder (ignored by git) in case of a rollback. The CLI inside it is at `Contents/Resources/inkrelay`. The launch agent is not installed; the app does the syncing.
- **License:** a lifetime Pro key for the owner is installed (`license.json` beside the config), issued with `scripts/make-license.swift`. The signing key is at `~/Library/Application Support/InkRelay/licensing/signing-key` (owner-only; back it up privately). The matching public key is in `Sources/InkRelayCore/Licensing/License.swift`.
- **Config:** `~/Library/Application Support/InkRelay/config.json`.
  - Viwoods Cloud (paper, meeting, memo, Daily planner for 12 months, Vision, ink layer on) goes to:
    - Obsidian, vault `fu-brain` in iCloud, folder `Resources/Inbox/Ink` (the owner moved it there on October 16 and changed the config themselves);
    - Apple Calendar, calendar "Viwoods";
    - the review stack (`shareWithPhone` off).
  - No Apple Notes or Reminders, by choice.
  - `config.json.bak` is the old 0.1.0 example it replaced.
- **Viwoods sign-in:** done through the app's window on October 16, 9:32 PM CT. The token is in `viwoods-token.json` beside the config and refreshes itself.
- **What has synced:** 24 items (20 planner days, 3 Paper notebooks, 1 memo) into Obsidian, plus 20 "Daily plan" events in Calendar.
  - The cloud lists "Paper 8, Meeting 1". Those counts include folders and templates, so 3 notebooks matches. If a notebook the owner expects is missing, that's the place to look.
- **Learned vocabulary** lives in `vocabulary.json` beside the config once a correction is learned; nothing learned yet.
- **Not turned on for the owner, their call:** AI transcription (would need their Anthropic key; `aiFolders: ["Daily"]` is the cheap way), `dailyNotes` and `weeklyDigest` (the vault has no Daily Notes settings file, so daily notes would land in the vault root as `YYYY-MM-DD.md`), `notifications.newNotes`, `reviewReminder`.
- **Synced before later fixes, so these still look the old way:**
  - The 24 notes show the pull time (October 16) as `modified`, not when they were written.
  - Memo 1 and the planner days 2025-11-11 and 2025-11-12 are empty pages filed as "No text recognized" notes.
  - The calendar events keep titles like "Daily plan: ter те" until their page changes.
- **MCP:** registered for Claude Code (user scope) and Claude Desktop (the original config is backed up as `claude_desktop_config.json.bak-inkrelay`). Both run the bundled `inkrelay mcp`.
- **Permissions:** Calendar automation works from the app. Notes automation works from the terminal. Test notes from the Notes round trip are in Recently Deleted.
- **Open at login:** the 0.7.0 app asked on its first launch; the answer is the owner's.

## Waiting on the owner

0. Open the 0.9.0 draft PR, mark it ready and merge it. Drafts on purpose: something has been merging green PRs under the owner's account within minutes of CI passing (#31, #36, #37), and GitHub can't merge a draft.
1. Releases: create an App Store Connect API key (Admin role), then run `swift scripts/setup-releases.swift ~/Downloads/AuthKey_XXXX.p8 <issuer-id> --tag` on `main`. Details in [RELEASING.md](../RELEASING.md). Only an "Apple Development" identity exists locally; no Developer ID yet.
2. Phone review:
   - install the iOS app from Xcode (Run on device; automatic signing with team DT9JP293AM);
   - pick iCloud Drive/InkRelay in the app;
   - set `"shareWithPhone": true` on the Mac's `reviewStack`.

   The app needs iOS 17; the owner's iPhone 7 is stuck on iOS 15.
3. Cloud accounts, before those destinations can be checked for real: a Google desktop OAuth client, a Microsoft Entra app registration and a Notion integration token. The README explains each.
4. #19: a waitlist form service for `WAITLIST_ENDPOINT`, hosting for `site/` (Netlify or Cloudflare Pages; GitHub Pages needs a public repo or Pro), and the posts.

## Never checked for real

- Google, Microsoft and Notion against real accounts.
- Apple Reminders against the real app.
- Kindle Scribe email pickup.
- The shared ledger across two real devices.
- Phone review over iCloud on a real device. The simulator read a local folder, and the round trip is covered by tests.
- The release workflow end to end, the TestFlight job (needs the app record in App Store Connect and the repository variable `TESTFLIGHT=on`), and `scripts/issue-licenses.swift` (needs a Lemon Squeezy store and `LEMONSQUEEZY_API_KEY`).
- Template subtraction on a real tablet export; it's checked on a drawn page with ruled lines and "Name / Date" labels.
- reMarkable Cloud.

## Suggested next steps

In rough order of value (the plan in [plan-1.0.md](plan-1.0.md) has the full list):

1. **Recognition quality on real pages.** Vision gets clear writing mostly right ("Setup the diag rome for erin" for "Setup the diagram for Erin") and misreads messy lines. Ideas:
   - Recognize from the cloud's ink-only layer (`mainBmp_`) instead of the rendered page, so template text such as "Name" and "Date 10/02/2025 01:43 PM" stops showing up as content. The rendered page stays in the PDF.
   - Offer AI transcription for planner days, which also brings back meaningful event titles.
2. **Viwoods apps not pulled yet:** Knowledge Base (3 items on the owner's account) and Learning. Their formats haven't been looked at.
3. **Tidy the owner's existing data,** if they want: re-pull to fix the `modified` dates, and remove the three empty notes.
4. **Ship a release** once the key exists, then put the zip on the landing page.
5. **Bundled OAuth client IDs,** so people using InkRelay don't each create a Google client and an Entra app. The publisher creates them once.
6. #3 and #23 as devices or accounts become available.
