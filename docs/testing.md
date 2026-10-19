# Testing

## The suite

```bash
swift test
```

- 223 tests, about 9 seconds.
- One test renders a PDF and runs real Vision recognition; on a cold machine the first run takes up to 30 seconds while the model loads.
- AppleScripts are compiled with `osacompile` as shipped.
- Cloud APIs are tested with `FakeTransport`, scripted per path, in `Tests/InkRelayCoreTests/ViwoodsSupport.swift`. Apple apps use fake script runners.
- CI runs the same on GitHub's macOS runner for every pull request.

When a commit touches files shared with other work in the same round, test that commit alone. Stage it, then run `git stash push --keep-index --include-untracked`, `swift test` and `git stash pop`.

## Against real data, without touching real notes

Copy the Viwoods cache into a scratch folder and give it a config whose only destination is a review stack shared into another scratch folder. Nothing reaches Obsidian, Calendar or Notes.

```bash
S=$(mktemp -d)
mkdir -p "$S/exports" "$S/shared"
cp -R ~/Library/Application\ Support/InkRelay/viwoods/{Paper,Memo,Daily} "$S/exports/"
cat > "$S/config.json" <<EOF
{
  "sources": [{ "id": "viwoods", "device": "Viwoods AiPaper", "path": "$S/exports", "fileTypes": ["pdf"] }],
  "destinations": [{ "kind": "reviewStack", "id": "review", "shareWithPhone": true, "shareFolder": "$S/shared" }],
  "settleSeconds": 0
}
EOF
swift build --product inkrelay && .build/debug/inkrelay sync --config "$S/config.json"
```

- State, the archive and the review store land beside that config.
- `state.json` shows which exports were judged `blank`, and `$S/shared/Review/stack.json` shows what a phone would get.
- On the owner's data at 0.7.0: 21 synced, 3 blank, 50 cards (43 pages, 7 suggested events).
- `swift scripts/measure-pages.swift FILE.pdf …` prints ink coverage and Vision's lines with confidence for any PDF.
- `inkrelay measure` scores recognition on the owner's set of corrected pages (`measure/` beside the config) and compares it with the last run. Run it before and after a recognition change; `inkrelay measure add viwoods-cloud/Daily/2025-11-03.pdf` adds pages as drafts to correct.

## The iPhone and iPad app

```bash
scripts/build-ios.sh          # regenerate the project with XcodeGen and build for a simulator
scripts/build-ios.sh --run    # also install and launch it
```

Debug builds read the environment variable `INKRELAY_SHARED_FOLDER` in place of the picked iCloud folder, so the simulator can show a stack from the scratch run above:

```bash
DEVICE=$(xcrun simctl list devices available | sed -n 's/^ *\(iPhone[^(]*\) (\([0-9A-F-]*\)).*/\2/p' | head -1)
xcrun simctl install "$DEVICE" .build/ios/Build/Products/Debug-iphonesimulator/InkRelay.app
SIMCTL_CHILD_INKRELAY_SHARED_FOLDER="$S/shared" xcrun simctl launch --terminate-running-process "$DEVICE" io.github.urazalievf.InkRelay.mobile
xcrun simctl io "$DEVICE" screenshot shot.png
```

Real iCloud on a real device hasn't been tried. The decision round trip is covered by `ReviewMirrorTests`.

## Apple apps

- `inkrelay doctor` checks folders, permissions, sign-ins and the agent. `--no-apps` skips the checks that make macOS ask for automation permission.
- `inkrelay doctor --notes-roundtrip [--notes-account NAME]` runs the real-Notes checks in a throwaway "InkRelay Test" folder: create, update in place, long and non-Latin text, archive, a note in Recently Deleted. It cleans up (test notes end in Recently Deleted; the test folders are removed). In zsh, pass `--notes-account` and the name as separate words.
- **Probing whether automation is allowed without hanging on a dialog:**

  ```bash
  ( osascript -e 'tell application "Calendar" to count calendars' > out.txt 2>&1 ) & P=$!
  for i in $(seq 1 10); do kill -0 $P 2>/dev/null || break; sleep 1; done
  kill -0 $P 2>/dev/null && { kill $P; echo "a permission dialog is probably waiting"; }
  ```

## The menu bar app

```bash
scripts/build-app.sh                          # build/InkRelay.app, ad-hoc signed
osascript -e 'quit app "InkRelay"'
rm -rf /Applications/InkRelay.app && ditto build/InkRelay.app /Applications/InkRelay.app
open /Applications/InkRelay.app
```

- `INKRELAY_CONFIG=/path/to/config.json` points the app at a scratch config.
- The app waits while the command-line launch agent is running, so two engines never share state.

## MCP

```bash
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"check","version":"1"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"inkrelay_status","arguments":{}}}' \
  | /Applications/InkRelay.app/Contents/Resources/inkrelay mcp
```

This expects server version 0.7.0, nine tools, and the status of the real config.

## Releases

- `swift scripts/setup-releases.swift --self-test` checks the App Store Connect JWT signing.
- `--dry-run KEY.p8 ISSUER` checks a key without creating or storing anything.
- `scripts/check-version.sh vX.Y.Z` fails unless the tag matches `InkRelayCore.version`.

## Supernote

`INKRELAY_SUPERNOTE_SAMPLES=/path/to/samples swift test` compares the decoder with the sample notebooks and their PDFs. Without the variable, that test is skipped; it's the one skipped test.
