## pass1 D1 — in-app delete removes exported mp4 folder
- tag: `pass1-D1`
- codex_bullet: |
    - [P2] [A] Deleting a download inside the app always deletes the exported MP4 in public storage — lib/services/download/download_service.dart:704-724, 604-613
      The merged video now lives in the user-visible `Download/LibrePili/<title>/` folder, which galleries index (`_scanMedia`). `deleteDownload`/`deletePage` call `_deleteMerged`, which deletes that whole folder recursively. There is no way to clear the in-app list and keep the file. Fix: make it a choice in the delete dialog ("also delete the exported file").
- routes: as stated in the bullet(s) above
- deferred_at: 2026-09-19T14:35:12+00:00
- resolved_at: 2026-09-19T14:47:23+00:00 — user picked A: delete dialog offers "also delete exported file"

## pass1 D2 — self-test runs on real profile and deletes downloads
- tag: `pass1-D2`
- codex_bullet: |
    - [P2] [A] The self-test runs against the real LibrePili profile and deletes the user's downloads — lib/utils/self_test.dart:365-374
      The data folder is set by the app's company/product name, not by where the exe is unpacked, so a self-test uses the real profile. `--download` first deletes any existing download of the same video, merged mp4 folder included, and deletes the test download again unless `--keep` (444-447). With the default `hot`, that is whatever video is first in the popular list. `--local` also deletes every user folder whose title starts with "selftest" (328-332). The switch is compiled into release builds. Fix: point the test at a separate data/download folder, or skip and report videos that are already downloaded instead of deleting them.
    - [P2] [A] `--selftest --download` deletes the user's existing download of that video — lib/utils/self_test.dart:364-373
      "Start from a clean state" calls `deleteDownload` for any entry with the same cid. With `bvid == 'hot'` that is whatever video is currently popular. This now includes the exported public MP4 folder. It runs against the real user profile. Fix: skip or abort when the cid already exists, or use a separate download root for self tests.
- routes: as stated in the bullet(s) above
- deferred_at: 2026-09-19T14:35:12+00:00
- resolved_at: 2026-09-19T14:47:23+00:00 — user picked A: separate data/download dir for self-test

## pass1 D3 — Android file picker cache copy loses side files (hypothesis)
- tag: `pass1-D3`
- codex_bullet: |
    - [P3] [A] Local player on Android: the file picker probably copies the video into the app cache, and folder listing needs a media permission (hypothesis) — lib/services/local_player.dart:33-46
      This relies on file_picker's documented Android behaviour of caching the picked file (not checked here). If so, a multi-GB file is copied before playback, the copy is never cleaned up, and the danmaku/subtitle files next to the original are not found. `pickFolder` then `listSync` on Android 13+ without READ_MEDIA_VIDEO would only list files the app owns. Fix: turn off caching or use the original path/URI, and request the media permission.
    - [P2] [A] Picking a local file on Android probably copies it into the cache and loses its side files — lib/services/local_player.dart:33-40, 88-103
      **Hypothesis**, based on file_picker's default Android behaviour. `FilePicker.pickFiles` returns a cache copy, so a multi-GB video gets copied. `_entryFor` then looks for `librepili.json`, danmaku, `.srt` and comments next to the copy, not the original. Fix: pick the folder (SAF) or use `withReadStream`/original URI, or at least document that "open folder" is the Android path.
- routes: as stated in the bullet(s) above
- deferred_at: 2026-09-19T14:35:12+00:00
- resolved_at: 2026-09-19T14:47:23+00:00 — user picked probe first on the phone (user: 测试), then decide; 2026-09-19 user picked A (SAF-based reading, no copy, no new permission) after probe
- probe (2026-09-19, OnePlus CPH2447 Android 16, build a5a244943, app has no storage permissions; test folder /sdcard/Download/LPTest owned by com.android.shell: lptest.mp4 47.84MB + lptest.danmaku.xml + lptest.zh-CN.srt):
    - 打开视频文件 → system picker → plays, but NO danmaku and NO subtitle loaded (screens s9/s10). App cache: cleared to 0 byte, picked again → 48.87 MB (whole file copied into cache/file_picker).
    - 打开视频文件夹 → Download root refused by system ("Can't use this folder"); LPTest selectable, "Allow access" granted → toast "没有找到可播放的视频文件" (path + listSync cannot see files through a SAF tree grant without storage permission).
    - Not tested: folders the app itself created (Download/LibrePili/<title>/, owned by the app) — expected readable (hypothesis).

## pass1 D4 — old single-URL downloads renamed .mp4 regardless of format
- tag: `pass1-D4`
- codex_bullet: |
    - [P2] [A] Old-format (single-URL) downloads are renamed to .mp4 whatever their real format — lib/services/download/download_service.dart:556-570
      For this format (`mediaType == 1`) the file is only moved to `<name>.mp4`. Its real format is `response.format` (download.dart:203), which can be FLV, and only the first segment is ever downloaded (the first-segment limit is a known TODO). The media scan also tags it `video/mp4`. Failure: the "complete mp4" is FLV content, or only part of the video, under an .mp4 name. Galleries or players that trust the extension or MIME type fail. Fix: use the extension from `format` and scan with the right MIME type, or remux FLV; mark multi-segment results as incomplete.
- routes: as stated in the bullet(s) above
- deferred_at: 2026-09-19T14:35:12+00:00
- resolved_at: 2026-09-19T14:47:23+00:00 — user picked B: remux FLV to mp4

## pass1 D5 — offline comments fetch avatars over network
- tag: `pass1-D5`
- codex_bullet: |
    - [P3] [A] Offline comments fetch avatars over the network — lib/pages/video/reply/local_reply_panel.dart:132-137
      `NetworkImgLayer(src: c['avatar'])` makes a CDN request for every comment while viewing offline. That leaks what is being watched, and the avatars fail with no network. Fix: use a placeholder, or save the avatars with the download.
- routes: as stated in the bullet(s) above
- deferred_at: 2026-09-19T14:35:12+00:00
- resolved_at: 2026-09-19T14:47:23+00:00 — user picked A: placeholder avatars; but images inside comments must be downloaded with the download

## pass1 D6 — hide-interaction setting description vs scope
- tag: `pass1-D6`
- codex_bullet: |
    - [P3] [D] The hide-interaction setting's description claims more than the code does — lib/pages/setting/models/extra_settings.dart:133
      The text says it hides writing comments, replies and sending danmaku; the gate exists only on the video page (reply/view.dart:125, reply_item_grpc.dart:514, video/view.dart:1399, header_control.dart:1861). Dynamic, article and live comment entry points are not covered (partly already in TODO). Fix: narrow the wording or gate the other panels.
- routes: as stated in the bullet(s) above
- deferred_at: 2026-09-19T14:35:12+00:00
- resolved_at: 2026-09-19T14:47:23+00:00 — user picked B: gate the other comment/danmaku entry points (dynamic, article, live)

## pass1 D7 — iOS/macOS/Linux still use upstream identifiers
- tag: `pass1-D7`
- codex_bullet: |
    - [P3] [D] iOS, macOS and Linux still use the upstream identifiers (known TODO) — .github/workflows/linux_x64.yml:229-254
      Those builds still produce `PiliPlus_*` artifacts with the upstream app id, so they share the data folder with the original app. That breaks the "runs side by side" goal off Windows and Android. Fix: rename them, or stop building those platforms from this branch.
    - [P2] [D] The "side-by-side install" rebrand misses Linux, macOS and iOS — linux/CMakeLists.txt:7-10; linux/runner/my_application.cc:48-71; macos/Runner/Configs/AppInfo.xcconfig:8-11; ios/Runner.xcodeproj/project.pbxproj:390
      The Linux `APPLICATION_ID` is still `com.example.piliplus`. GApplication uniqueness then hands the launch to a running PiliPlus, and the two share a data dir. The same applies to the macOS/iOS bundle id. The commit message and README promise side-by-side install. Fix: rename the ids, or limit that claim to Windows/Android.
- routes: as stated in the bullet(s) above
- deferred_at: 2026-09-19T14:35:12+00:00
- resolved_at: 2026-09-19T14:47:23+00:00 — user picked A: rename iOS/macOS/Linux identifiers

## pass2 D1 — home-feed 不感兴趣 in login mode
- tag: `pass2-D1`
- codex_bullet: |
    - [P3] [A] Login mode: "不感兴趣" feedback on the recommend feed is sent anonymously — lib/http/video.dart:474-530; lib/common/widgets/video_popup_menu.dart:100-130
      The UI checks that the recommend account has an `access_key`, but `feedDislike` / `feedDislikeCancel` are not account APIs (probed: `requiresAccount` is false), so the request carries no account and the feedback does nothing. Fix: either list them as account APIs or hide the menu item, since the feed is anonymous by design.
- routes:
    - add feedDislike/feedDislikeCancel to the account allowlist
    - hide the menu item (feed is anonymous by design)
- deferred_at: 2026-09-19T16:10:46+00:00
- resolved_at: 2026-09-19T18:50:19+00:00 — user: in login mode the home recommend feed is no longer anonymous (binds to the recommend-role account), so 不感兴趣 works there; local 不感兴趣 (option C) recorded as TODO

## pass2 D2 — in-app playback of multi-part fallback download plays only part 1
- tag: `pass2-D2`
- codex_bullet: |
    - [P3] [A] Multi-segment durl downloads: when the join fails, in-app playback silently plays only segment 1 — lib/services/download/download_service.dart:663-705, 643-655; lib/plugin/pl_player/models/data_source.dart:34-44
      `_exportType1` catches only `UnsupportedError`. Other errors propagate to the catch in `_mergeDownload`, e.g. the `FormatException('bad box …')` that `_Mp4Joiner._readProgressive` throws for a corrupt or truncated segment. The entry is then completed with `mergedPath == null`, and `FileSource` plays only `0.mp4`. The deliberate fallback (segments kept as `<base>.flv`, `<base>.2.flv`…) also sets `mergedPath` to the first file only, so in-app playback again stops after segment 1 with no notice. Fix: when segments stay separate, have the file source play all of them (e.g. an mpv playlist or concat), or at least tell the user playback is partial. `DownloadStatus.failMerge` (bili_download_entry_info.dart:426) is defined but never set; merge failure shows only as a toast.
- routes:
    - play all parts (mpv playlist / concat)
    - tell the user playback is partial
- deferred_at: 2026-09-19T16:10:46+00:00
- resolved_at: 2026-09-19T17:29:56+00:00 — user: neither A nor B; make the merge itself not fail (solve the non-joinable cases)

## pass2 D3 — desktop export folders share the root with internal <avid>/s_<id> folders
- tag: `pass2-D3`
- codex_bullet: |
    - [P3] [A] Desktop: exported video folders share the download root with the internal `<avid>` / `s_<seasonId>` folders — lib/services/download/download_service.dart:736-800, 846-856, 263-280
      On desktop, `_exportDir()` returns `downloadPath` itself. Export folders are named after the sanitised title, and internal page folders are named `<avid>` or `s_<id>`. Scenario: a video whose title is just a number, say "114514", exports to `<root>/114514/`. A later download of av114514 then creates `<root>/114514/c_<cid>` inside it. Deleting that later download calls `deletePage`, which recursively deletes `<root>/114514`, including the first video's exported mp4 that the user chose to keep. Fix: export into a dedicated subfolder, or refuse names that collide with the internal layout.
- routes:
    - export into a dedicated subfolder
    - refuse/rename titles that collide with the internal layout
- deferred_at: 2026-09-19T16:10:46+00:00
- resolved_at: 2026-09-19T17:29:56+00:00 — user picked B (rename on collision)

