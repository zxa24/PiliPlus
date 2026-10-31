# Watch-page offline materials

The offline profiles the watch-page checks start from (design
`feature-logs/watch-page-shell/design.md` §5 S0b 「素材与前置条件」, and
the offline snapshot of §5 S0a 「核对」). Online ids: `test/mutants/wp_materials.json`.

| snapshot | what | open with |
|---|---|---|
| `landscape/` | one completed bilibili download, 640×360 (16:9), 6 s, a comment attachment (5 comments, 2 with 2 replies) and a saved intro | `--open-offline --entry cid:281001` |
| `portrait/` | the same at 360×640 (9:16) | `--open-offline --entry cid:281002` |
| `list10/` | ten completed downloads (`夹具列表 01`…`10`, one video each, the same media file copied into each one's folder), comment attachments, **no** saved intro; listed newest first, so row k is `夹具列表 k+1`; R4 plays index 3 = cid 281104 (`夹具列表 04`), opened from the download page | the download page |

A field table uses one as `"run": { "profile": "snapshot:test/fixtures/watch_page/<name>" }`.

## Format (a real download's)

```
appdata/download/<avid>/c_<cid>/entry.json        the download record (BiliDownloadEntryInfo.toJson)
appdata/download/<avid>/c_<cid>/cover.jpg         (media)
appdata/download/<export>/<export>.mp4            (media) — merged_path points here
appdata/download/<export>/<export>.comments.json  librepili-comments-2 (DownloadExtras.replyToJson: each comment's ReplyInfo as `pb`)
appdata/download/<export>/<export>.intro.json     librepili-intro-1 (landscape, portrait only)
appdata/download/<export>/librepili.json          the record without this device's paths
appdata/download/<export>/cover.jpg               (media)
place.json                                        which media file goes where
```

`<export>` is the download service's export name, `<title> [360P 流畅]`.
`merged_path` is `${PROFILE_APPDATA}\download\<export>\<export>.mp4`; the
restore writes the profile's folder in its place (design v7 wp6#13). The
page finds the comments and the intro beside that file
(`VideoDetailController.initFileSource`: `localCommentsPath`,
`localIntroPath`). The ids (avid 171001…, cid 281001…) sit next to the
download fixtures'; they are not checked against bilibili, and the offline
page plays from the file.

## Made, not edited

- The JSON files are made by `test/watch_page/fixtures_test.dart` with the
  app's own writers. That test fails when a file differs from what they
  make now; `WP_FIXTURES_WRITE=1 flutter test test/watch_page/fixtures_test.dart`
  rewrites them. It also reads them back with the app's readers, and runs
  the download page's controller on the real download service over
  `list10` (all ten listed, one row each, in order; the playing one at
  index 3 of the offline playlist).
- The media (the two clips and two covers) are not in the repository:
  `pwsh -NoProfile -File test/fixtures/watch_page/make_media.ps1` makes
  them with ffmpeg into `%LOCALAPPDATA%\LibrePili-test-media\watch_page`
  (`media.json` "root") and checks each against `media.json`'s SHA-256. A
  different ffmpeg build can make other bytes: then the script stops (exit
  1); `-Update` records the new hashes (commit `media.json` with a note).
  The runner hashes these source files into each report folder's manifest;
  the JSON here is pinned by the manifest's `fixtures` tree.

## Into a profile

The runner restores a table's snapshot before each run
(`test/mutants/run.ps1` `Restore-WpProfile`): the profile's folders are
emptied, `appdata/` copied in, each media file checked against its hash and
placed as `place.json` says, `${PROFILE_APPDATA}` / `${PROFILE_TEMP}`
replaced in every `.json`. By hand (e.g. the AC-S0a 核对 runs):

```
pwsh -NoProfile -File test/mutants/wp_restore_profile.ps1 -Snapshot test/fixtures/watch_page/landscape -Profile <name>
<slot exe> --selftest --profile <name> --out <report> --open-offline --entry cid:281001 ...
```

then delete `%APPDATA%\com.zxa24\LibrePili\selftest-<name>` and
`%TEMP%\LibrePili\selftest-<name>`.

Everything under `test/` is git-ignored (`.gitignore` `test*`): commit these
with `git add -f`.
