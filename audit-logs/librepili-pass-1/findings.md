## U1 (codex)
- [P1] Strip `access_key` when anonymizing requests — lib/http/live.dart:202-228  
  `liveFeedIndex` builds query params with `recommend.accessKey` before the request interceptor applies `LoginPolicy.requiresAccount`. Since `Api.liveFeedIndex` is not in the account allowlist, cookies/headers are anonymized but the account token remains in the URL, linking the request to the user. Fix by deriving app API params from the post-policy bound account, or by scrubbing `access_key` whenever `_bindRequestAccount` replaces a `LoginAccount` with `AnonymousAccount`.

## U2 (codex)
- [P2] Rebuild nav tabs after login-mode changes — lib/pages/main/controller.dart:364-370  
  `setNavBarConfig()` filters out the `dynamics` tab when `Accounts.main` is anonymous, but it only runs during `onInit`. Toggling login mode later updates account state but leaves the tab list and `TabController`/`PageController` length stale, so account-only tabs stay hidden until restart. Recompute navigation config and recreate/sync the page controller when `onChangeAccount` fires.

## U3 (claude-xhigh)
- [P1] [A] Login mode: live requests, including live search, still carry the account's `access_key` — lib/http/live.dart:198-466
  `liveFeedIndex`, `liveSecondList`, `liveAreaList`, `liveRoomAreaList`, `liveSearch` (and line 773) put `'access_key': ?recommend.accessKey` straight into the request parameters. `spaceShop` (member.dart:810-811) does the same with `Accounts.main.accessKey`. `_bindRequestAccount` then swaps in the anonymous account, but account_mgr.dart:76-80 only adds `access_key` when the bound account has one. It never removes one that is already there, and the request is re-signed with it. Failure: with login mode on and the recommend role set to the account (what the quick-select dialog does), live search keywords and browsing are tied to the account. That breaks the "search and recommendations stay anonymous" promise. Fix: in `onRequest`, remove `access_key`/`mobile_access_key` from the parameters whenever the bound account is not a logged-in account, or stop adding them at these call sites.

## U4 (claude-xhigh)
- [P1] [A] Login mode: "has a csrf parameter" is treated as "is a write", so some public reads carry the account — lib/utils/accounts/account_manager/../login_policy.dart:79-84
  Several existing GET reads add `csrf` whenever the user is logged in: `replyReplyList` (reply.dart:75), `dynamicDetail` (dynamics.dart:284), `upowerRank` (member.dart:759), and `archiveNoteList` always (video.dart:954). `requiresAccount` therefore returns true for them. Failure: in login mode, opening replies to a comment or a post's detail page sends the account cookies. `LoginPolicy`'s own doc says comments and spaces are anonymous. Fix: only apply the csrf check to non-GET methods, or remove `csrf` from those reads.

## U5 (claude-xhigh)
- [P2] [A] Changing account roles while login mode is off does nothing visible, and the old stored roles come back later — lib/utils/accounts.dart:78-86
  With login mode off, `accountMode` is all anonymous, so the role dialog (login/controller.dart:651-762) shows every role as anonymous. Picking "anonymous" for a role compares equal and is skipped (line 759). Picking account B for a role adds it to B but leaves it in A's saved `type` set, because only the anonymous placeholder gets `.remove(key)`. Failure: when login mode is turned on, `refresh()` reactivates the old saved roles (for a role claimed by two accounts, whichever is stored last wins). The heartbeat/history role can end up on the account after the user chose anonymous. Fix: load the dialog from the saved `LoginAccount.type` sets, and when reassigning a role, remove it from every saved account. Related: `setAccount` (623-642) turns login mode on without calling `Accounts.refresh()` or updating `MineController.anonymity`, so the incognito icon stays wrong.

## U6 (claude-xhigh)
- [P2] [C] The new retry loop deletes a partly downloaded file when only the last attempt failed before any data — lib/services/download/download_manager.dart:44-58
  `delete: failure.beforeData` only describes the last attempt. Failure: attempt 1 gets 95% of a large m4s, the network drops for longer than about 15s (attempts 2–6 are connection errors with 1–5s backoff), and `_fail` deletes the whole file. Before this change, a mid-transfer error kept the partial file. Fix: only delete if the file on disk was empty when the loop started, or never delete once any bytes have been saved.

## U7 (claude-xhigh)
- [P2] [A] Resume and CDN rotation append the response body without checking it is a partial response — lib/services/download/download_manager.dart:84-116
  A retry opens the file in append mode and accepts any 2xx or 416. If a backup host ignores `Range` and returns 200, the whole stream is appended after the partial data. A 416 body is also appended, and the file is then marked completed. Either way the m4s is corrupt, and the remux fails with "bad box" (the m4s files are kept). Rotating across CDNs makes this more likely. The 416 acceptance may predate the fork. Fix: require 206 with a matching `Content-Range` start when `received > 0`; truncate and restart on 200; treat 416 as complete only when the on-disk size equals the total.

## U8 (claude-xhigh)
- [P2] [A] A crash after merging causes a full re-download and leaves an untracked duplicate folder — lib/services/download/download_service.dart:553-582
  The m4s files are deleted right after the remux (571-574). `mergedPath` and `isCompleted` are only saved later in `_completeDownload` (538-539), after `DownloadExtras.export`. That export does many network calls (up to 500 comments × reply pages, 200ms apart), so the window is long, and the download queue is blocked in "merging" meanwhile. Failure: if the app is killed in that window, the entry reloads as incomplete, downloads from zero, and `_exportFilePath` creates "name (2)". The first folder is never tracked and deleting the entry never removes it. Fix: save `mergedPath` and completion before deleting inputs and before fetching extras, and run extras afterwards.

## U9 (claude-xhigh)
- [P2] [A] Old-format (single-URL) downloads are renamed to .mp4 whatever their real format — lib/services/download/download_service.dart:556-570
  For this format (`mediaType == 1`) the file is only moved to `<name>.mp4`. Its real format is `response.format` (download.dart:203), which can be FLV, and only the first segment is ever downloaded (the first-segment limit is a known TODO). The media scan also tags it `video/mp4`. Failure: the "complete mp4" is FLV content, or only part of the video, under an .mp4 name. Galleries or players that trust the extension or MIME type fail. Fix: use the extension from `format` and scan with the right MIME type, or remux FLV; mark multi-segment results as incomplete.

## U10 (claude-xhigh)
- [P2] [A] With quick-favourite on, one tap removes an item from all local folders — lib/pages/common/common_intro_controller.dart:233-242
  `fav = !isFav(key)` followed by `setFolders(key, data, {})` clears every folder, not just the default one. Failure: a video filed in "Default" and "Music" (or only "Music") is removed from all of them by a single tap. The account version of quick-favourite only touches the quick folder. Fix: when un-favouriting, toggle only `defaultFolderId` and keep the other folders.

## U11 (claude-xhigh)
- [P2] [A] Local follows and favourites are not in any backup or export — lib/utils/storage.dart:82-87
  `exportAllSettings` (also used by WebDAV sync, webdav.dart:82) exports only the `setting` and `video` boxes. The `localFollows`, `localFavFolders` and `localFavItems` boxes are also missing from `compact()` and `close()` (113-137), which run on exit (main/view.dart:134, 187-188). Failure: without an account these boxes are the only copy of the user's follows and favourites, so reinstalling or moving devices loses them. Fix: add the boxes to export/import and to compact/close.

## U12 (claude-xhigh)
- [P2] [A] "Open with LibrePili" does nothing if LibrePili is already running on Windows — lib/main.dart:218-227
  The file path in the launch arguments is only handled in a fresh process. `SendAppLinkToInstance()` (windows/runner/main.cpp:11-13) passes the arguments to the running instance and exits. There, `uriLinkStream` goes to `routePush` (app_scheme.dart:47-49), which has no local-file handling (a search for `LocalPlayer`/`File` in app_scheme.dart finds nothing). Closing the window minimizes to the tray by default, so an instance is usually running. Failure: the file silently doesn't open. Fix: in the listener, detect an existing file or folder path and call `LocalPlayer.open`.

## U13 (claude-xhigh)
- [P2] [A] The self-test runs against the real LibrePili profile and deletes the user's downloads — lib/utils/self_test.dart:365-374
  The data folder is set by the app's company/product name, not by where the exe is unpacked, so a self-test uses the real profile. `--download` first deletes any existing download of the same video, merged mp4 folder included, and deletes the test download again unless `--keep` (444-447). With the default `hot`, that is whatever video is first in the popular list. `--local` also deletes every user folder whose title starts with "selftest" (328-332). The switch is compiled into release builds. Fix: point the test at a separate data/download folder, or skip and report videos that are already downloaded instead of deleting them.

## U14 (claude-xhigh)
- [P3] [A] Pausing or deleting a download can take up to 5s, and a request is still sent after cancelling — lib/services/download/download_manager.dart:51-57
  The retry decision is made before the backoff delay. `cancel()` awaits `task`, and `startDownload` holds `_lock` while doing so. After the delay, `_attempt` still opens the file and sends a request with the cancelled token. Fix: re-check `_cancelToken.isCancelled` and `_status` after the delay, and make the delay cancellable.

## U15 (claude-xhigh)
- [P3] [A] A dropped local file gets a wrong playlist, and possibly a crash, when the download page is open — lib/pages/video/introduction/local/controller.dart:57-80
  If `DownloadPageController` is registered (e.g. a file dropped while the download page is open; `DropTarget` sits on the main page, main/view.dart:550), `list` holds the downloads and `indexWhere(cid==0)` returns -1. On mobile `list[index]` throws a RangeError; on desktop nothing is highlighted and `nextPlay` jumps to download 0. Fix: fall back to `[entry]` when the current entry isn't in the list.

## U16 (claude-xhigh)
- [P3] [A] The folder-name dialog's text controller is disposed while the closing animation still uses it — lib/pages/local/fav_sheet.dart:26-55
  `whenComplete(controller.dispose)` runs when the dialog is popped, but the `TextField` rebuilds during the reverse transition. Expected result: a "used after being disposed" error in debug builds (a known Flutter pattern; not run here). Fix: keep the controller in a StatefulWidget inside the dialog.

## U17 (claude-xhigh)
- [P3] [A] A saved tab order hides the new "本地" (Local) tab, and "dynamics only" becomes zero tabs — lib/pages/main/controller.dart:231-248
  `local` only appears in `defaultOrder`. Any existing or imported `navBarSort` leaves the Local tab (local follows/favourites/feed) out. A saved order of only `[dynamics]` is filtered to an empty list when logged out. Fix: add `local` to saved orders once, and fall back to `defaultOrder` if the filtered list is empty.

## U18 (claude-xhigh)
- [P3] [D] The update dialog still offers an "exe" download and links to `main`'s commits — lib/utils/update.dart:67-101
  The Windows installer was removed, so "exe" never matches an asset and falls back to the releases page. "View full changes" opens `/commits/main`, which is the upstream mirror, not the `librepili` branch. Fix: drop the exe button and link to the `librepili` branch.

## U19 (claude-xhigh)
- [P3] [D] The hide-interaction setting's description claims more than the code does — lib/pages/setting/models/extra_settings.dart:133
  The text says it hides writing comments, replies and sending danmaku; the gate exists only on the video page (reply/view.dart:125, reply_item_grpc.dart:514, video/view.dart:1399, header_control.dart:1861). Dynamic, article and live comment entry points are not covered (partly already in TODO). Fix: narrow the wording or gate the other panels.

## U20 (claude-xhigh)
- [P3] [A] Offline comments fetch avatars over the network — lib/pages/video/reply/local_reply_panel.dart:132-137
  `NetworkImgLayer(src: c['avatar'])` makes a CDN request for every comment while viewing offline. That leaks what is being watched, and the avatars fail with no network. Fix: use a placeholder, or save the avatars with the download.

## U21 (claude-xhigh)
- [P3] [A] Local player on Android: the file picker probably copies the video into the app cache, and folder listing needs a media permission (hypothesis) — lib/services/local_player.dart:33-46
  This relies on file_picker's documented Android behaviour of caching the picked file (not checked here). If so, a multi-GB file is copied before playback, the copy is never cleaned up, and the danmaku/subtitle files next to the original are not found. `pickFolder` then `listSync` on Android 13+ without READ_MEDIA_VIDEO would only list files the app owns. Fix: turn off caching or use the original path/URI, and request the media permission.

## U22 (claude-xhigh)
- [P3] [A] On Windows, a download deleted during merging may come back (hypothesis) — lib/services/download/download_service.dart:533-541
  `deleteDownload` during a merge tries to delete the m4s files the merge isolate still has open. If Windows refuses the delete, `tryDel` hides the error. The completion check then only tests `Directory(entryDirPath).existsSync()` and re-adds the entry to `downloadList`. Fix: add a "deleted" flag or token that `_completeDownload` checks.

## U23 (claude-xhigh)
- [P3] [A] One odd XML field makes the whole external danmaku file load as empty — lib/services/download/download_extras.dart:278-280
  `Int64.parseInt(p[4])` throws on a non-integer ctime in XML from other tools. `_initFileDm` catches the error once, so no danmaku load at all. Fix: use `Int64.tryParseInt` / `int.tryParse` for each field.

## U24 (claude-xhigh)
- [P3] [D] iOS, macOS and Linux still use the upstream identifiers (known TODO) — .github/workflows/linux_x64.yml:229-254
  Those builds still produce `PiliPlus_*` artifacts with the upstream app id, so they share the data folder with the original app. That breaks the "runs side by side" goal off Windows and Android. Fix: rename them, or stop building those platforms from this branch.

## U25 (claude-agent)
- [P1] [A] Account-only gRPC calls never get the account in login mode — lib/utils/accounts/login_policy.dart:55-74
  `requiresAccount` compares `options.path` with bare `GrpcUrl` constants (`/bilibili.im.interface.v1.ImInterface/...`, `$audio/PlayURL`, `dynRed`). But `GrpcReq.request` sends `HttpString.appBaseUrl + url` (lib/grpc/grpc_req.dart:62), so `options.path` begins with `https://app.bilibili.com`. Neither `contains` nor `startsWith` ever matches. In login mode, private messages, the dynamic red dot, audio play URL and audio like/coin all go out anonymously and fail. test/utils/login_policy_test.dart passes bare paths, so the test hides the bug. Fix: strip the app base URL before comparing (or match on `endsWith`), and test with the real `appBaseUrl + GrpcUrl.x` path.

## U26 (claude-agent)
- [P1] [C] A retried download can delete a nearly complete file — lib/services/download/download_manager.dart:38-60, 104-109
  The file is deleted when the last attempt failed before any data arrived (`delete: failure.beforeData`). Earlier attempts may already have written most of it. Scenario: the stream breaks at 90%, the network is down for about 15 s, all 5 retries fail at connect time, and `_fail(delete: true)` deletes the 90% file. Before this change, a failure during the stream kept the file. Fix: delete only when this manager wrote nothing at all (track bytes written across attempts), or never delete a resumable partial file.

## U27 (claude-agent)
- [P1] [A] Resuming on a backup CDN does not check for 206, a complete length, or 416 — lib/services/download/download_manager.dart:96-136
  Resume now depends on `Range` across different mirrors. The code has three gaps:
  - A mirror that ignores `Range` and returns 200 gets the full body appended to the partial file (`writeOnlyAppend`), which corrupts it.
  - A clean early EOF is marked `completed` without comparing `received` to `contentLength`, so a short transfer is never retried. Dropped connections are exactly why this feature was added.
  - A 416 body is accepted and appended.
  The first two already existed. Retry-on-mirror makes them much more likely. Fix: require 206 when `received > 0` (on 200, truncate and restart), treat `received != contentLength` as a retryable failure, and on 416 check the size instead of writing the body.

## U28 (claude-agent)
- [P2] [A] Tapping an entry while it merges pauses it, and tapping again starts a second download — lib/services/download/download_service.dart:523-547; lib/pages/download/detail/widgets/item.dart:138-149
  `merging` counts as `isDownloading`, so a tap calls `cancelDownload` (it shows 暂停中 while the isolate keeps remuxing). A second tap calls `startDownload(entry)` → `_startDownload`, which fetches the stream again and creates new DownloadManagers. The m4s files get deleted after the remux, so this becomes a full re-download. Meanwhile `_completeDownload` marks the entry completed and clears `curDownload`, leaving orphan m4s writers. `cancelDownload(... downloadNext: true)` from pause/delete can also call `nextDownload()`, which picks this same entry, because it is still at the head of `waitDownloadQueue` during the merge. Fix: ignore pause/start for an entry in `merging` (or run the merge under `_lock`), and remove it from the queue before merging.

## U29 (claude-agent)
- [P2] [A] Saving comments/subtitles inside the merge step blocks the download queue — lib/services/download/download_service.dart:578-582; lib/services/download/download_extras.dart:146-186
  `DownloadExtras.export` is awaited before the next download starts. Defaults are 200 root comments and 10 replies each. Each root with more than its preview replies triggers a `detailList` walk with 200 ms sleeps, so a popular video can mean hundreds of anonymous gRPC calls. The queue sits in "merging" for tens of seconds per video, which also widens the race above. Fix: run extras after `nextDownload()` (fire-and-forget or as a separate job).

## U30 (claude-agent)
- [P2] [A] Deleting a download inside the app always deletes the exported MP4 in public storage — lib/services/download/download_service.dart:704-724, 604-613
  The merged video now lives in the user-visible `Download/LibrePili/<title>/` folder, which galleries index (`_scanMedia`). `deleteDownload`/`deletePage` call `_deleteMerged`, which deletes that whole folder recursively. There is no way to clear the in-app list and keep the file. Fix: make it a choice in the delete dialog ("also delete the exported file").

## U31 (claude-agent)
- [P2] [A] Server-side logout silently fails while in incognito mode — lib/utils/accounts/account_manager/account_mgr.dart:236-243; lib/pages/setting/view.dart:231-238
  `LoginHttp.logout(account)` passes the account explicitly. `_bindRequestAccount` still swaps it for `AnonymousAccount` when `!LoginPolicy.loginMode`. The logout request goes out without the account's cookies, so the session is never revoked on the server even though the user chose to log out. Fix: treat an explicit `extra['account']` for login-flow APIs (`Api.logout`, `activateBuvidApi`, `qrcodeConfirm`) as authoritative whatever the mode.

## U32 (claude-agent)
- [P2] [A] Local follows and favorites are left out of backup, clear and close — lib/utils/storage.dart:82-140; lib/services/local_library.dart:17-29
  Boxes `localFollows`, `localFavFolders` and `localFavItems` are not in `exportAllSettings`/`importAllJsonSettings` (the settings/WebDAV backup) or in `GStorage.close()`/`clear()`/`compact()`. This is the only copy of an account-free user's library, so a reinstall or device change loses it, and "clear all data" leaves it behind. Fix: add the three boxes to export/import/clear/close.

## U33 (claude-agent)
- [P2] [A] A local file opened while the download page is in the navigation stack crashes on mobile (index −1) — lib/pages/video/introduction/local/controller.dart:54-78
  When `DownloadPageController` is registered, `list` is filled with all completed downloads and the "just this video" fallback is skipped. A plain local file (`cid: 0`) is not in that list, so `index == -1` and `list[index]` throws a RangeError on mobile. Fix: add the entry whenever `indexWhere` returns −1, not only when the list is empty.

## U34 (claude-agent)
- [P2] [A] All plain local files share one progress key, and resume is always discarded — lib/services/local_player.dart:108-135; lib/pages/video/controller.dart:332-360
  `_plainEntry` sets `cid: 0` and `totalTimeMilli: 0`. `watchProgress` is keyed by `cid`, so every plain file reads and writes key `"0"`. The check `progress >= totalTimeMilli - 400` is then always true, so resume never works. Fix: key by a hash of the path and skip the "completed" check when the duration is unknown.

## U35 (claude-agent)
- [P2] [A] The offline comments tab goes stale or can crash when switching videos in the offline playlist — lib/pages/video/reply/local_reply_panel.dart:22; lib/pages/video/view.dart:1839-1846
  `LocalReplyPanel` caches `_data` as `late final`, keeps itself alive, and has no key tied to `path`. After `playIndex`, it keeps showing the previous video's comments. If the next entry has no comments file, `showReply` becomes false while the `localCommentsPath!` call site may still rebuild, which throws. The crash path is a **hypothesis**, not reproduced. Fix: `key: ValueKey(path)` plus a null guard.

## U36 (claude-agent)
- [P2] [A] Picking a local file on Android probably copies it into the cache and loses its side files — lib/services/local_player.dart:33-40, 88-103
  **Hypothesis**, based on file_picker's default Android behaviour. `FilePicker.pickFiles` returns a cache copy, so a multi-GB video gets copied. `_entryFor` then looks for `librepili.json`, danmaku, `.srt` and comments next to the copy, not the original. Fix: pick the folder (SAF) or use `withReadStream`/original URI, or at least document that "open folder" is the Android path.

## U37 (claude-agent)
- [P2] [D] The "side-by-side install" rebrand misses Linux, macOS and iOS — linux/CMakeLists.txt:7-10; linux/runner/my_application.cc:48-71; macos/Runner/Configs/AppInfo.xcconfig:8-11; ios/Runner.xcodeproj/project.pbxproj:390
  The Linux `APPLICATION_ID` is still `com.example.piliplus`. GApplication uniqueness then hands the launch to a running PiliPlus, and the two share a data dir. The same applies to the macOS/iOS bundle id. The commit message and README promise side-by-side install. Fix: rename the ids, or limit that claim to Windows/Android.

## U38 (claude-agent)
- [P2] [A] `--selftest --download` deletes the user's existing download of that video — lib/utils/self_test.dart:364-373
  "Start from a clean state" calls `deleteDownload` for any entry with the same cid. With `bvid == 'hot'` that is whatever video is currently popular. This now includes the exported public MP4 folder. It runs against the real user profile. Fix: skip or abort when the cid already exists, or use a separate download root for self tests.

## U39 (claude-agent)
- [P3] [A] Switching an account's role in incognito leaves the old holder's role set — lib/utils/accounts.dart:78-86
  In incognito `accountMode[key]` is always `AnonymousAccount`, so `oldAccount..type.remove(key)` removes nothing from the LoginAccount that held the role. Two stored accounts can then both claim `main`, and `refresh()` in login mode picks whichever comes last. Fix: remove `key` from every `Accounts.account.values` entry before adding it.

## U40 (claude-agent)
- [P3] [A] The navigation bar does not follow login-mode changes — lib/pages/main/controller.dart:233-248
  The dynamics tab is filtered once at startup using `Accounts.main.isLogin`, so toggling incognito does nothing until restart. If the saved order is `[dynamics]` only, the bar list is empty and a length-0 TabController follows.

## U41 (claude-agent)
- [P3] [B] `DownloadStatus.failMerge` is defined but never set — lib/models_new/download/bili_download_entry_info.dart:426
  A merge failure only shows a toast, then marks the entry completed with `mergedPath == null`. The status is dead, or the UI misses the failure state.

## U42 (claude-agent)
- [P3] [A] Export file name truncation can split a surrogate pair and produce very long paths — lib/services/download/download_service.dart:666-695
  `substring(0, 120)` counts UTF-16 units, so an emoji at the boundary leaves a lone surrogate. Folder name plus file name repeat the ≤120-char title twice. On Windows without long-path support this may pass 260 characters and make the merge fail back to m4s. The Windows part is a **hypothesis**.

## U43 (claude-agent)
- [P3] [D] The updater still offers an `exe` asset on Windows, but CI no longer publishes an installer — lib/utils/update.dart:101; .github/workflows/win_x64.yml
  The button always ends in "platform not found: exe".

## U44 (claude-agent)
- [P3] [A] Local favorites change the displayed server favorite count — lib/pages/common/common_intro_controller.dart:219-224
  `_onLocalFavChanged` calls `updateFavCount(±1)`, so a device-local action changes the public count shown.

