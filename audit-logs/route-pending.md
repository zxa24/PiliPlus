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

## pass3 D1 - stored accounts deleted on a single not-logged-in response; refresh_token never used
- tag: `pass3-D1`
- codex_bullet: |
    - [P3] [A] Stored accounts are deleted permanently on a single "not logged in" response, and refresh_token is never used — lib/pages/mine/controller.dart:101-132; lib/utils/login_utils.dart:90-98; lib/pages/login/controller.dart:628-632
      `isLogin == false` or '账号未登录' from `userInfo` leads to `Accounts.deleteAll`, which deletes the cookies and the stored `refresh_token`. No cookie/token refresh flow exists anywhere (the only reference to refresh_token is the login controller storing it). An expired SESSDATA, or a transient -101 during risk control, destroys a renewable login without confirmation. Fix: try a refresh first, or mark the account expired instead of deleting it.
- routes:
    - try a cookie/token refresh first
    - mark the account expired instead of deleting
- deferred_at: 2026-09-19T20:15:39+00:00
- resolved_at: 2026-09-19T21:06:21+00:00 — user picked B (mark expired, do not delete)

## pass3 D2 - update check contacts GitHub on every launch by default
- tag: `pass3-D2`
- codex_bullet: |
    - [P3] [D] The update check runs on every launch by default, and "查看完整更新" links to the upstream-mirror branch — lib/utils/update.dart:24-30,68-70; lib/utils/storage_pref.dart:475-476
      `autoUpdate` defaults to true, so a privacy-first build contacts api.github.com at every start. The commits link goes to `.../commits/main`, but the fork's code is on `librepili` (`main` tracks upstream). Fix: link to `librepili`, and consider making the check opt-in.
- routes:
    - make the update check opt-in
    - keep it on by default
- deferred_at: 2026-09-19T20:15:39+00:00
- resolved_at: 2026-09-19T21:06:21+00:00 — user picked ask on first launch; updates auto-download and are applied on the next launch

## pass3 D3 - card menu incognito toggle flips persistent login mode in one tap
- tag: `pass3-D3`
- codex_bullet: |
    - [P2] [A] Card ⋮ menu offers "进入/退出无痕模式", which now flips the persistent login mode in one tap with no confirmation — lib/common/widgets/video_popup_menu.dart:308-314
      In upstream this was a session-only toggle. The fork's `MineController.onChangeAnonymity` (lib/pages/mine/controller.dart:157-172) writes `SettingBoxKey.loginMode`, calls `Accounts.refresh()` and `onLoginMain()`. Any user with a saved account can therefore leave incognito from any video card's menu, where it sits next to 拉黑/不感兴趣. Fix: remove the item from the card menu, or confirm before leaving incognito.
- routes:
    - remove the item from the card menu
    - confirm before leaving incognito
- deferred_at: 2026-09-19T20:15:39+00:00
- resolved_at: 2026-09-19T21:06:21+00:00 — user picked hide login-only items when not logged in (the incognito toggle only when an account exists)

## pass3 D4 - biliSendCommAntifraud sends full cookies to an unverified package
- tag: `pass3-D4`
- codex_bullet: |
    - [P3] [A] biliSendCommAntifraud sends the full cookie string to an unverified package — android/app/src/main/java/com/example/piliplus/AndroidHelper.java:77-104; lib/utils/reply_utils.dart:69-93
      The explicit intent targets a package name only, with no signature or installer check. Any sideloaded app using that package name receives SESSDATA and bili_jct for every comment sent while the (opt-in) switch is on. Fix: verify the target's signing certificate first, or send only what the check needs.
- routes:
    - verify the target app's signing certificate
    - send only what the check needs
- deferred_at: 2026-09-19T20:15:39+00:00
- resolved_at: 2026-09-19T21:06:21+00:00 — user picked A (verify signing certificate)

## pass3 D5 - RetryInterceptor re-sends non-idempotent POSTs
- tag: `pass3-D5`
- codex_bullet: |
    - [P3] [A] RetryInterceptor re-sends non-idempotent POSTs — lib/http/retry_interceptor.dart:52-73
      `connectionError`/`unknown` errors are retried up to `retryCount` (default 2) whatever the method. On HTTP/1.1 (the default), "Connection closed before full header was received" maps to connectionError (dio io_adapter.dart:178-185), even though the server may already have processed the request. Coin, like, reply and danmaku POSTs can therefore be applied twice (e.g. 2 coins for one tap).
      **hypothesis:** how often the server has already processed the request in these cases. Fix: only retry GET/HEAD, or only errors where nothing was sent.
    - [P2] [A] Automatic retry resends POST writes that the server may already have processed — lib/http/retry_interceptor.dart:52-73
      With the defaults (retryCount 2, HTTP/2 off, so the dart:io adapter), dio maps "Connection closed before full header was received" to `connectionError` after the body was fully sent (dio io_adapter.dart:178-186, read). `sendTimeout` and `unknown` are retried too. Only HTTP/2 `TransportConnectionException` is excluded. So a comment, danmaku, coin or dynamic post can be sent twice. **Hypothesis** (not probed): that the server really does process the first attempt in these cases. Fix: retry only idempotent methods, or only connection errors raised before the request was sent.
- routes:
    - retry only GET/HEAD
    - retry only errors raised before the request was sent
- deferred_at: 2026-09-19T20:15:39+00:00
- resolved_at: 2026-09-19T21:06:21+00:00 — user picked A (retry only GET/HEAD)

## pass3 D6 - WebDAV restore replaces local library without merge
- tag: `pass3-D6`
- codex_bullet: |
    - [P1] [A] WebDAV "恢复设置" replaces all settings and the local follows/favorites in one tap, with no confirmation and no merge — lib/pages/webdav/view.dart:108-117 (lib/pages/webdav/webdav.dart:102-119, lib/utils/storage.dart:95-110)
      `onPressed: WebDav().restore` runs `setting.clear()`+`putAll`, `video.clear()` and `LocalLibrary.importAll`, which clears and replaces the local-library boxes. Without an account those boxes are the only copy of follows/favorites. Mis-tapping it next to "备份设置", or restoring an older backup, silently loses everything added since that backup. Fix: add a confirm dialog that names what gets replaced, and either merge the library boxes by key or snapshot the current state first.
- routes:
    - merge local-library boxes by key
    - snapshot current state before replacing
- deferred_at: 2026-09-19T20:15:39+00:00
- resolved_at: 2026-09-19T21:06:21+00:00 — user picked B (snapshot before replacing)

## pass3 D7 - macOS custom download path lost after restart (hypothesis, needs a Mac)
- tag: `pass3-D7`
- codex_bullet: |
    - [P3] [A] macOS: a custom download path does not survive a restart under the sandbox — **hypothesis** — macos/Runner/Release.entitlements:5-10; lib/main.dart:62-80
      Only `files.user-selected.read-write` is granted, and no security-scoped bookmark is stored for the picked folder. At the next launch, access to the folder is presumably gone. `_initDownPath` then either fails to create it and silently deletes the setting, or keeps a path it cannot write to. Fix: store and resolve an app-scope bookmark.
- routes:
    - store a security-scoped bookmark
    - leave as is until verified on a Mac
- deferred_at: 2026-09-19T20:15:39+00:00
- resolved_at: 2026-09-19T21:06:21+00:00 — user picked verify on the Mac (ssh mac_user@100.104.75.108) first
- probe (2026-09-19, Mac mini macOS 13.7.8 x86_64 via ssh): CI dmg (run 35465726801) is universal (x86_64 arm64), entitlements = app-sandbox + files.user-selected.read-write + network.client (no bookmarks entitlement in use). A sandboxed probe app with the same entitlements: unsandboxed control writes ~/Downloads/lp_audit_dir OK; sandboxed without a grant → "You don't have permission to save the file". A restart has no grant unless a security-scoped bookmark was stored → hypothesis CONFIRMED (mechanism). Probe files removed from the Mac.

## pass3 D8 - comment anti-fraud check compares anonymous with anonymous in login mode
- tag: `pass3-D8`
- codex_bullet: |
    - [P3] [C] Login mode: the comment anti-fraud check's "with account" lookups are sent anonymously, so it gives wrong verdicts — lib/utils/reply_utils.dart:174-305; lib/http/reply.dart:59-78
      `replyReplyList(isLogin:true)` is a GET to `Api.replyReplyList`, which is not in `_accountApis`, so LoginPolicy sends it anonymously (while still sending the csrf, see the first finding). The self-visible vs. anonymous comparison therefore compares anonymous with anonymous. A shadow-banned root reply is reported as "无法找到你的评论" instead of "shadow ban", and sub-replies always end in "评论不可见".
      Fix: bind these check calls to the account explicitly (listed `_explicitAccountApis`-style), or disable the check in LibrePili.
    - [P2] [A] The comment-visibility check no longer checks as the logged-in user, so its verdicts are wrong — lib/utils/reply_utils.dart:198-285 with lib/http/reply.dart:59-78
      The check compares "as the account" (`isLogin: true`) against "without an account". `Api.replyReplyList` is not in `_accountApis`, so the "as the account" request is now also sent anonymously (confirmed by the probe above). Both sides are then anonymous, so the shadow-ban case (only visible to yourself) reports "无法找到你的评论" instead of "shadow ban". A reply missing from page 1 of the main list reports the false "评论区被戒严" warning. Fix: have these check calls pass the account explicitly and add `replyReplyList` to `_explicitAccountApis`. Otherwise drop the account half of the check and change the messages.
- routes:
    - bind the check's requests to the account explicitly
    - disable/reword the check in LibrePili
- deferred_at: 2026-09-19T20:15:39+00:00
- resolved_at: 2026-09-19T21:06:21+00:00 — user picked A (bind the check to the account explicitly)

## pass3 D9 - settings export contains WebDAV password and SponsorBlock user id
- tag: `pass3-D9`
- codex_bullet: |
    - [P3] [A] The settings export contains secrets in plain text — lib/utils/storage.dart:83-90; lib/utils/storage_pref.dart:323-332,631-641
      `setting.toMap()` includes the WebDAV password and the SponsorBlock private `blockUserID`, which acts as a password for that service. These go to the clipboard or a shareable file (export_import.dart:21-39) and up to the WebDAV server. Import also overwrites this device's WebDAV credentials. Fix: leave credential keys out of export/import.
    - [P3] [A] Exported settings include the WebDAV password in plain text — lib/utils/storage.dart:83-90; lib/utils/storage_key.dart:190-193
      `exportAllSettings` writes the whole `setting` box: `webdavPassword`, `webdavUsername`, proxy host, `blockUserID`. The export goes to the clipboard or a shared file. Fix: leave the credential keys out of the export, or ask before including them.
- routes:
    - leave credential keys out of export/import
    - ask before including them
- deferred_at: 2026-09-19T20:15:39+00:00
- resolved_at: 2026-09-19T21:06:21+00:00 — user picked B (ask before including secrets)

