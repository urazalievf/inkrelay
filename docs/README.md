# InkRelay project notes

Working notes for whoever picks the project up next. The top-level [README](../README.md) is for people who use InkRelay; these are for people who build it.

Start with **[handoff.md](handoff.md)**: what's shipped, what's open, what the owner's Mac runs today, and what to do next.

| File | What's in it |
|---|---|
| [handoff.md](handoff.md) | Current state, open work, the live setup, what waits on the owner, suggested next steps |
| [architecture.md](architecture.md) | How the pieces fit: targets, the sync pass, sources, destinations, files on disk |
| [decisions.md](decisions.md) | Choices already made and why, so they aren't argued again |
| [field-notes.md](field-notes.md) | Measurements on real tablet data, and platform gotchas found along the way |
| [testing.md](testing.md) | How to check each part, including against real data without touching real notes |
| [viwoods-cloud.md](viwoods-cloud.md) | The unofficial Viwoods Cloud API as InkRelay uses it |
| [supernote-format.md](supernote-format.md) | The Supernote `.note` file format as the decoder reads it |
| [research/market-scan-2026-10.md](research/market-scan-2026-10.md) | Market scan, gaps, platform access and risks (from issue #22) |
| [launch/pricing.md](launch/pricing.md) | Pricing comparables, costs and the option to test (#19) |
| [launch/community-posts.md](launch/community-posts.md) | Draft posts for the demand check (#19) |

Release steps are in [RELEASING.md](../RELEASING.md). The landing page is [site/index.html](../site/index.html).

Keep these current: update `handoff.md` at the end of each round of work, and add to `field-notes.md` and `decisions.md` when something is learned or settled.
