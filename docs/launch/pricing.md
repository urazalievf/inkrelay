# Pricing notes (#19)

## What people already pay

| Product | What it does | Price |
|---|---|---|
| Scrybble | reMarkable → Obsidian only | €22–40 a year |
| reMarkable Connect | Unlimited cloud retention for one tablet; Drive and OneDrive integrations are now free | $3.99 a month or $39.90 a year |
| Matter | Read-later app with Kindle integration | $79.99 a year |
| Readwise | Highlights and read-later, no tablet integration beyond Send to Kindle | about $8–10 a month |

Sources and dates are in issue #22.

## What it costs to run

- Vision recognition and everything on the Mac: nothing per user.
- AI transcription with Claude: two to four cents a page at the default model; capped by the user's own key and monthly budget, so it isn't InkRelay's cost unless it's bundled.
- No server is needed, apart from a waitlist and, later, license checks.

## Options

1. **One-time purchase**, about $29–39 for the Mac app, paid upgrades for major versions. Fits a Mac utility that runs locally and costs nothing to serve. Easiest to explain next to Scrybble's subscription.
2. **Subscription**, about $3–5 a month or $29–39 a year. Fits if InkRelay hosts AI transcription (so users don't need their own key) or a sync service between phone and Mac.
3. **Free core, paid extras**: folder sources, Obsidian and Apple Notes free; cloud sources (Viwoods, later reMarkable and Supernote), Google, Microsoft and Notion destinations, AI transcription and the review stack paid.

## Recommendation to test

Option 3 with a one-time "Pro" unlock at $29, and ask on the waitlist which features people would pay for. The free tier shows the cross-tablet promise; the paid tier covers what took the most work and what single-vendor plugins can't match. Revisit a subscription only if hosted transcription or phone-to-Mac sync becomes part of the product.

## Before launch

- Name: a few small, unrelated GitHub repos are called "inkrelay". Check trademarks and the App Store before committing to the name.
- Hosting the landing page: GitHub Pages needs a public repo or GitHub Pro; Netlify, Cloudflare Pages or Vercel host `site/` for free.
