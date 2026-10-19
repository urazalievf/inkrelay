# Handoff: where things stand

As of October 19, 2026, 5:30 PM CT. Everything through 0.10.0 "Polish" (#69) is on `main`, and so is the release workflow fix (#71). Waiting as draft PRs: #72 (the previous handoff update) and, on top of it, #74 on branch `public-releases` (0.10.1: public downloads and `inkrelay measure`). The plan all rounds follow is [plan-1.0.md](plan-1.0.md).

**v0.10.0 is the first signed release.** It was published October 19 at 5:06 PM CT: [InkRelay-0.10.0.zip](https://github.com/urazalievf/inkrelay/releases/tag/v0.10.0), universal, Developer ID signed, notarized and stapled. Downloaded and checked on the Mac: Gatekeeper says "accepted, Notarized Developer ID". The tag's first run (39134287085) timed out on October 18 because Apple held the team's first notarization for hours. Apple accepted it with no issues, and a re-run of the failed job went through in minutes. #71 now keeps the signed app as an artifact and adds a finish path for the next slow notarization ([RELEASING.md](../RELEASING.md)).

**Public downloads have a home; the first public release is 0.10.1.** The source repository is private, so its releases answer 404 to customers. The owner chose a public releases-only repository: [urazalievf/inkrelay-releases](https://github.com/urazalievf/inkrelay-releases), created October 19 with a customer README and nothing else (issues, wiki and projects off). On the `public-releases` branch:

- the release workflow publishes there through `scripts/publish-release.sh`, with a fine-grained token (`RELEASES_TOKEN`, which only the owner can create; [RELEASING.md](../RELEASING.md) step 3), and uploads the zip twice, as `InkRelay-<version>.zip` and as `InkRelay.zip`, so `releases/latest/download/InkRelay.zip` is always the newest;
- release notes come from `docs/release-notes/<version>.md`, because generated notes list private pull requests; the workflow refuses to start without the file, and a test fails when the current version has none;
- `UpdateChecker.releasesRepository`, the site's Download button, the user guide and the README point at the public repository, and a test keeps them in step;
- the workflow's own token is down to `contents: read`.

v0.10.0 stays only in the private repository: its update check reads the private feed, so a customer on 0.10.0 would never hear of a newer version. 0.10.1 is the first build worth handing out.

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
| 0.9.0 | #56 | Planner-only AI with batching and per-source caps (#48), Supernote ink-only and template subtraction for exports (#49), vocabulary learned from Obsidian corrections (#50), `inkrelay viwoods list` with Learning and Knowledge Base listed (#51, still not pulled), Lemon Squeezy key issuing script (#52, untested), TestFlight archive path and workflow job (#54, untested), plan in the MCP status, daily notes offered in setup when the vault has them |
| 0.9.0.1 | #57 | Fixes from a review of 0.9.0: corrections learned before the changed page is read and only from a vault copy of the archived version; `vocabulary.json` re-read when another process writes it; a template in the other orientation is turned and an ill-fitting one ignored; the archive-only paths use the same ink-only and per-folder routing; AI batches shrink to what the budget allows; the key issuer filters by product and skips test orders; the TestFlight upload takes the FIX number as its build number; Daily Notes detected from `core-plugins.json` |
| 0.9.0.2 | #58 | Fixes from a review of 0.8.0: the plan is read again at every pass (a key entered while the app or agent runs takes effect at the next sync); one snapshot per pass, so "notes synced" and the review reminder carry the right pass; the update feed is the releases list, and a feed that can't be read is reported rather than called "up to date"; `--expires` covers the whole stated day in local time; `Do` ordinals in daily-note names; an orphaned start marker no longer swallows what follows it; a new daily note starts from the person's template; a rename no longer doubles the digest; Settings keep every source, every source setting, the Apple destinations' own settings and the cloud device name, and back up a config they couldn't read before replacing it |
| 0.10.0 | #69 | License expiry as a calendar date; a purchase path and what Pro means for this setup (#59); the first run continues to the sign-in or login question (#60); doctor explains empty and unreadable sources and checks templates and send targets (#61); sources can leave folders out, Supernote's books and exports by default (#62); a trial-ended panel, trial notifications and the reason a key was rejected (#63); a per-launch key on the review server (#64); Kindle mail limited to Amazon senders, Amazon https links and 100 MB (#65); a sync log for the app, last-sync.json and scrubbed diagnostics (#66); tablet to-dos as Obsidian checkboxes with block ids (#67); planner pages from any folder (#68) |
| 0.10.1 | #74 (draft) | Releases published to the public `inkrelay-releases` repository with customer-facing notes; the update check, site and guide read it there; `inkrelay measure`, word accuracy on a fixed set of real pages read exactly as a sync reads them |

287 tests, about 15 seconds (`swift test`); the longest ones draw pages and run real Vision. CI runs on pull requests only.

## Open issues

- Every issue of 0.8.0, 0.9.0 and 0.10.0 is closed except #51 and #53. GitHub only closes the first issue in "Closes #a, #b", so #38–#47, #49, #50, #52, #54 and #60–#68 were closed by hand on October 18. Write "Closes #a, closes #b" in PR descriptions. **#51** stays open: `inkrelay viwoods list` shows the owner's Learning and Knowledge Base apps are empty at the top level (the home screen's "Knowledge Base 3" is its tabs), so their item format is still unknown and nothing is pulled. **#53** (bundled OAuth client ids) needs the owner's registrations.
- **#3** Real exports from each tablet. Viwoods is checked with real notebooks through the cloud. Supernote is checked against public sample notebooks and the device's own PDFs. reMarkable, Boox and Kindle Scribe exports have never been seen.
- **#19** Demand and pricing. Drafts exist (`docs/launch/`, `site/`). Posting, a waitlist form service and hosting are the owner's.
- **#23** Connector matrix. Done except reading reMarkable Cloud directly: no account or device, and its API is unofficial and changes often.

Board: GitHub user project #8, "InkRelay roadmap". Status options: Todo, In Progress, Done.

Merging is the owner's call. `main` has no branch protection (that needs GitHub Pro on a private repo), so a merge goes through without review. Open pull requests and leave them for the owner. Before pushing more commits to a PR's branch, check that the PR is still open: a commit pushed after the merge never reaches `main`.

## The owner's Mac today

- **App:** `/Applications/InkRelay.app` 0.10.0 (build 100000), ad-hoc signed, built from branch `polish-0.10.0`; the 0.9.0.2 build is kept at `build/InkRelay-0.9.0.2.app` in the repo folder (ignored by git) in case of a rollback. The CLI inside it is at `Contents/Resources/inkrelay`. The launch agent is not installed; the app does the syncing.
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
- **Measuring set:** `measure/viwoods-cloud/` beside the config holds 26 pages as drafts, made October 19 with `inkrelay measure add`: all 11 pages of Paper `ll`, `Initial` p1, `Temp` p1–3, and the planner days 2025-11-03, 2025-12-08, 2026-01-20 and 2026-02-02 (12 pages). About 370 words in all. Each draft is what InkRelay reads today; nothing is scored until the owner corrects them, so there's no baseline number yet.
- **Not turned on for the owner, their call:** AI transcription (would need their Anthropic key; `aiFolders: ["Daily"]` is the cheap way), `dailyNotes` and `weeklyDigest` (the vault has no Daily Notes settings file, so daily notes would land in the vault root as `YYYY-MM-DD.md`), `notifications.newNotes`, `reviewReminder`.
- **Synced before later fixes, so these still look the old way:**
  - The 24 notes show the pull time (October 16) as `modified`, not when they were written.
  - Memo 1 and the planner days 2025-11-11 and 2025-11-12 are empty pages filed as "No text recognized" notes.
  - The calendar events keep titles like "Daily plan: ter те" until their page changes.
- **MCP:** registered for Claude Code (user scope) and Claude Desktop (the original config is backed up as `claude_desktop_config.json.bak-inkrelay`). Both run the bundled `inkrelay mcp`.
- **Permissions:** Calendar automation works from the app. Notes automation works from the terminal. Test notes from the Notes round trip are in Recently Deleted.
- **Open at login:** the 0.7.0 app asked on its first launch; the answer is the owner's.

## Waiting on the owner

Pull requests stay drafts until the owner marks them ready and merges them. Something has been merging green PRs under the owner's account within minutes of CI passing (#31, #36, #37), and GitHub can't merge a draft.

Done on October 18 with the owner's approval, so not waiting any more: App Store Connect API access, a Team API key "InkRelay Releases" (Admin, key ID NTZGY42J5H), a Developer ID Application certificate (G2, expires November 17, 2027), the six release secrets, and the `v0.10.0` tag (released October 19). The key, the certificate and its private key are in `~/Library/Application Support/InkRelay/release-signing/` (owner-only); keep a private backup. The API can't create Developer ID certificates, so the certificate was made on developer.apple.com ([RELEASING.md](../RELEASING.md)).

1. **The first public release (0.10.1).**
   - Create `RELEASES_TOKEN`: github.com → Settings → Developer settings → Personal access tokens → Fine-grained tokens → Generate new token; resource owner `urazalievf`; Repository access: only `urazalievf/inkrelay-releases`; Repository permissions: **Contents: Read and write** (Metadata read-only comes with it); nothing else. Then `gh secret set RELEASES_TOKEN --repo urazalievf/inkrelay`.
   - Merge #72, then #74.
   - Tag: `git tag v0.10.1 && git push origin v0.10.1` from `main` (or `swift scripts/setup-releases.swift … --tag`, which now stops while the token is missing). Pushing a tag is the owner's call.
   - Then check the release page, the site's button link and `inkrelay update check` on 0.10.1.
2. **Correct the measuring drafts** (about 15 minutes): open each file in `~/Library/Application Support/InkRelay/measure/viwoods-cloud/`, change the text to what the page really says, delete the first line. Then `inkrelay measure` gives the first number, and every later run compares with it.
3. **Installing the notarized build on this Mac (optional).** The installed app is the ad-hoc build of the same 0.10.0. Swapping in the notarized one changes the code signature, so macOS will probably ask again for Calendar automation.
4. Phone review:
   - install the iOS app from Xcode (Run on device; automatic signing with team DT9JP293AM);
   - pick iCloud Drive/InkRelay in the app;
   - set `"shareWithPhone": true` on the Mac's `reviewStack`.

   The app needs iOS 17; the owner's iPhone 7 is stuck on iOS 15.
5. Cloud accounts, before those destinations can be checked for real: a Google desktop OAuth client, a Microsoft Entra app registration and a Notion integration token (#53 would make the first two unnecessary for customers). The README explains each.
6. #19: a waitlist form service for `WAITLIST_ENDPOINT`, hosting for `site/`, and the posts. The download button now points at the public releases repository. Since that repository is public, GitHub Pages could serve `site/` from it for free; Netlify or Cloudflare Pages still work.
7. Selling (#52): a Lemon Squeezy store and product, then `LEMONSQUEEZY_API_KEY=… swift scripts/issue-licenses.swift --store ID --product ID --send`. Until then keys are issued by hand with `scripts/make-license.swift`.
8. TestFlight (#54): an app record for io.github.urazalievf.InkRelay.mobile in App Store Connect, then the repository variable `TESTFLIGHT=on`; the release workflow uploads the next tag's iPhone build.

## Never checked for real

- Google, Microsoft and Notion against real accounts.
- Apple Reminders against the real app.
- Kindle Scribe email pickup.
- The shared ledger across two real devices.
- Phone review over iCloud on a real device. The simulator read a local folder, and the round trip is covered by tests.
- Publishing to the releases repository: `scripts/publish-release.sh --check` passed against it locally (with the owner's `gh` login), but the release job has never run with `RELEASES_TOKEN`. The first tag after the merge is the test.
- The release workflow's finish path (`workflow_dispatch`, only needed when Apple is slow; the tag path was checked end to end with v0.10.0), the TestFlight job (needs the app record in App Store Connect and the repository variable `TESTFLIGHT=on`), and `scripts/issue-licenses.swift` (needs a Lemon Squeezy store and `LEMONSQUEEZY_API_KEY`).
- Template subtraction on a real tablet export; it's checked on a drawn page with ruled lines and "Name / Date" labels.
- reMarkable Cloud.

## Suggested next steps

In rough order of value (the plan in [plan-1.0.md](plan-1.0.md) has the full list):

1. **The first public release** (0.10.1; the token and the tag are the owner's, above). After it, the site needs a host before the Download button is reachable from anywhere but the README.
2. **Recognition quality on real pages.** `inkrelay measure` and a 26-page set exist; once the owner has corrected the drafts, record the baseline, then try one change at a time and keep what raises the number. Candidates: `usesLanguageCorrection` off for planner pages, a higher `renderScale`, the vocabulary, and `aiFolders: ["Daily"]` (costs money, the owner's call).
3. **Viwoods apps not pulled yet:** Knowledge Base and Learning (#51). They're empty at the top level on the owner's account, so their format is still unknown.
4. **Tidy the owner's existing data,** if they want: re-pull to fix the `modified` dates, and remove the three empty notes.
5. **Bundled OAuth client IDs** (#53), so people using InkRelay don't each create a Google client and an Entra app. The publisher creates them once.
6. #3 and #23 as devices or accounts become available.
