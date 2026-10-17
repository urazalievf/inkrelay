# Viwoods Cloud API

Viwoods Cloud arrived in AiPaper firmware 3.15: opt-in on the tablet, 10 GB free, syncing Paper, Meeting, Knowledge Base, Memo, Learning and the Daily planner. The web portal is cloud.viwoods.com. There is no public API and no documentation. Everything here was mapped from the portal's JavaScript bundle and checked against the owner's account in October 2026. Expect it to change with any portal update; the folder export route keeps working if it does.

Code: `Sources/InkRelayCore/Viwoods/` (`ViwoodsClient`, `ViwoodsModels`, `ViwoodsCloudPuller`, `PDFComposer`, `Gzip`).

## Requests

- Base `https://api.viwoods.com`. Every call is a `POST` with a JSON body.
- **Headers:**
  - `Content-Type`, `Accept`, a browser `User-Agent`;
  - `System-Version: 1.0.0`, `Source: 2`, `Machine-Model: web`, `Machine-Number:` (empty), `Language: us`;
  - `Sign`;
  - with a token, both `Authorization: Bearer <token>` and `Access-Token: <token>`.
- **The body** always carries `uri`: the path with a leading slash.
- **`Sign`:** take the body's parameters sorted by key, join them as `k=v&k=v`, append the portal's signing key (in `ViwoodsClient.signingKey`), and take the MD5 in lowercase hex. When completing an upload, `eTags` is left out of the signature, as the portal does.
- **Replies** are an envelope `{ "code", "msg", "data" }`. `code` 200 is success. 401 and 10104 mean the token expired: call `api/v1/user/refreshLogin` once and retry.
- **Timestamps** are milliseconds since 1970 (`lastModifiedTime`; notebooks also have `userModifiedTime`).

## Signing in

The web login has a slider captcha, so InkRelay never handles passwords. The portal keeps its token in the page's `localStorage` under `Access-Token`.
- The menu bar app's "Sign In to Viwoods" window (`ViwoodsSignInView`, a `WKWebView` on `https://cloud.viwoods.com/login`) polls that key once a second after sign-in and saves the token.
- `inkrelay viwoods login` accepts a pasted token.
- Either way the token goes to `viwoods-token.json` beside the config and is refreshed automatically.

## Listing

- `api/v1/resourceSync/getRootFolder`: an app's root.
- `api/v1/resourceSync/getPage` with `appType`, `resourceId` (the parent; empty for the top level), `pageIndex` and `pageSize` (100): the items in a folder.
- **Apps:** Paper 1, Meeting 2, Learning 3, Knowledge Base 4, Memo 6.
- **Items** have `resourceId`, `name` and `resourceType`: 0 is a folder, 1 a file, 5 a template folder. They also have `childSize`, `lastModifiedTime`, `isDelete` and `encrypt`.
  - Skip template folders, empty ids and `isDelete == 1`.
  - `encrypt == 1` is a note with a cloud password (AES and SHA-256 on the client side); InkRelay reports it and moves on.
- The counts the home screen shows include folders and templates. The owner's "Paper 8" is 3 notebooks.

## Notebooks and memos

- **`api/v1/paperSync/get`** (and `meetingSync/get`) with `uuid`. `data.data` is gzip, base64-encoded JSON, containing:
  - `note`: `id`, `fileName`, times, `isDeleted`;
  - `pages`: `[{ "page": { "id", "order", "isDeleted" } }]`;
  - `resourceRefs`: `[{ "fileName", "remoteUrl", "ownerPageId" }]`.
- **`fileName` says what a reference is:**
  - `screenshotBmp_<page>.png`: the rendered page, which is what InkRelay uses;
  - `mainBmp_`: the ink layer alone, without the template;
  - `path_`: the strokes;
  - `Thumbnail_`: the preview.
- **`api/v1/memoSync/get`** with `uuid`: `memoFileInfo` plus `memoPageInfos` (`id`, `order`, and `pageShotFileName`, a CDN URL).
- **Page images** are PNGs on a CDN, fetched without signing. The server never serves PDFs; the portal composes them in the browser.
  - InkRelay does the same in `PDFComposer`, at 0.5 points per pixel: a 1440 × 1920 page becomes 10 × 13.3 inches.
  - The PDF's modification date is set to the cloud's time.

## Daily planner

- `api/v1/resourceDailySync/getDateList` with `month` (`yyyy-MM`): `[{ "date", "hasTaskNote", "hasTodo" }]`.
- `api/v1/resourceDailySync/getList` with `startDate`, `endDate` and `type`:
  - 0 is notes pages and 1 is the Tasks tab's handwritten pages, both with `url`, `pageOrder` and `lastModifiedTime`;
  - 2 is typed to-dos, with `content`, `level` (priority) and `isFinish`.
- Dates come as `2026-1-13`; `ViwoodsDate.normalize` makes them `2026-01-13`.
- A day's pages become `Daily/<yyyy-MM-dd>.pdf`. A day is fingerprinted by its newest `lastModifiedTime` and its page and to-do counts.

## Uploading (send to tablet)

1. `api/v2/cloud/upload/init` with `fileName`, `partNum` 1 and `type` `/learning/` (or `/paper/`) returns a ticket with a presigned URL.
2. `PUT` the file to it and keep the `ETag`.
3. `api/v2/cloud/upload/complete` with `uploadId`, `folder`, `source` and `eTags` (`eTags` unsigned, as above).
4. `api/v1/resourceSync/import` with `appType` (3 for Learning, 1 for Paper), `name` and `parentId` files it.

## The local cache

`viwoods/` beside the config holds `Paper/…`, `Meeting/…`, `Memo/…` and `Daily/…` as PDFs, plus `.manifest.json`:
- `notes`: resource id → modified time and path;
- `days`: date → fingerprint;
- `plans`: to-do id → calendar event ids.

A rename on the tablet with no new ink moves the cached PDF byte for byte, so the engine sees a rename instead of a new note. Delete `.manifest.json` to pull everything again.

## Not used yet

- Knowledge Base (app 4) and Learning (app 3) content. Their formats haven't been looked at.
- The `mainBmp_` ink-only layer, which could recognize better on templated pages.
- `api/v2/file/list`.
