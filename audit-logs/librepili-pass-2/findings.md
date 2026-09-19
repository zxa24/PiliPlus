## U1 (codex)
- [P2] Allowlist access-key-only account actions — lib/utils/accounts/login_policy.dart:20-54  
  `_accountApis` includes some app access-key endpoints, but misses others that still require a logged-in app token, such as feed dislike/cancel and live favorite tag updates. In login mode, `_bindRequestAccount` anonymizes these requests, and the interceptor then does not add or actively scrubs `access_key`, so the UI passes its precheck but the server call fails. Add these access-key-only actions to the policy, or make the policy treat app endpoints/actions that require `access_key` as account-required.

## U2 (claude-xhigh)
- [P1] [A] Restoring or resetting settings turns login mode off without re-reading the accounts, and a later Mine refresh permanently deletes the stored account — lib/utils/storage.dart:91-102
  `importAllJsonSettings` (and About › 重置可导出的设置, lib/pages/about/view.dart:281-290) overwrite `loginMode` while the app keeps running. Nothing calls `Accounts.refresh` afterwards, so `Accounts.main` is still a LoginAccount and `AccountService.isLogin` stays true. Meanwhile `AccountManager._bindRequestAccount` (account_mgr.dart:256-259) now sends every request anonymously. A pull-to-refresh on Mine then calls `UserHttp.userInfo()`, which comes back "账号未登录"; `MineController.queryUserInfo` (mine/controller.dart:114-125) then calls `Accounts.deleteAll({Accounts.main})`, which deletes the saved cookies and tokens.
  Likely migration path: a user imports their account, turns login mode on, then imports an old PiliPlus settings export (which has no `loginMode` key). The reverse also happens: importing a backup with `loginMode=true` quietly turns login mode on at the next launch, with no opt-in on this device.
  Fix: after import/reset, run the same transition as `onChangeAnonymity` (refresh, then onLoginMain or onLogoutMain), or keep the current `loginMode` out of import/reset. Also never delete an account because an anonymized request said "未登录" (check `requestOptions.extra['account'] is LoginAccount`).

## U3 (claude-xhigh)
- [P2] [A] The incognito indicator shows "incognito" while login mode is on (mixes up "login mode off" with "heartbeat role anonymous") — lib/pages/mine/controller.dart:41-43,150-164
  `anonymity = !loginMode || !Accounts.heartbeat.isLogin`, and it is also reset to `!heartbeat.isLogin` in accounts.dart:114-116, login/controller.dart:640 and about/view.dart:252. With login mode on, a signed-in main account and heartbeat set to mid 0 (a natural privacy choice), the incognito badge appears on Mine, Home and the video page (ugc/view.dart:969). Meanwhile stream URLs, relation and like calls still carry the account. The first toggle tap then does nothing except announce "已开启登录模式".
  This also contradicts the doc comment on line 41 ("incognito … means login mode is off").
  Fix: derive the indicator only from `!LoginPolicy.loginMode`.

## U4 (claude-xhigh)
- [P2] [C] Login mode: several account-only endpoints are missing from `_accountApis`, so they are sent anonymously and fail — lib/utils/accounts/login_policy.dart:20-54
  - Contents of a favorites folder: `Api.favResourceList` (fav.dart:61-73). `favFolderInfo` is on the list but the folder contents are not, so private folders load their header and then an error.
  - Watch-later / favorites "play all" list: `Api.mediaList` (user.dart:362-377).
  - The 账号资料 page load: `${appBaseUrl}/x/v2/account/myinfo` (member_profile/view.dart:81-85).
  - The same page's name/sign/sex/birthday edits: `/x/member/app/*/update` (:371-374). `access_key` is stripped by `_scrubAccessKey`.
  - Saving live favorite tags: `Api.setLiveFavTag` (live.dart:393-416), POST with access_key only, while the read `getLiveFavTag` is on the list.
  - Home-feed "不感兴趣": `feedDislike`/`feedDislikeCancel` (video.dart:477-526), still offered in video_popup_menu.
  **hypothesis:** the exact server error codes; nothing was sent to the network.
  Fix: add these endpoints, or have call sites mark "needs account" in `Options.extra`, and extend login_policy_test.

## U5 (claude-xhigh)
- [P2] [C] Login mode: an UP's space page always shows "not followed" — lib/pages/member/controller.dart:95-112
  The space data comes from `Api.space` with a `vmid` that is not the user, so it is fetched anonymously and `relation` is always 0. Special-follow and blacklist state are lost too. Tapping 关注 on an UP the user already follows sends `relationMod act=1`, and unfollowing is impossible from this page. The video intro page avoids this by querying `UserHttp.userRelation` (ugc/controller.dart:140-142, 440).
  Fix: in login mode, fetch `Api.relation` (already on the list) for the space's mid.

## U6 (claude-xhigh)
- [P2] [A] The live-room danmaku socket bypasses LoginPolicy and ties the anonymous session to the user's uid — lib/pages/live_room/controller.dart:543-557
  The auth packet sends `uid: Accounts.heartbeat.mid` together with a `key` from `getDanmuInfo`, which was fetched anonymously (live.dart:159-168, not on the list). That links this launch's anonymous identity to the account, contrary to login_policy.dart:8-12.
  **hypothesis:** the server may also reject a uid/token mismatch, so live chat would silently fail in login mode.
  Fix: send uid 0 unless the token is fetched with the account.

## U7 (claude-xhigh)
- [P2] [A] Login mode gives the in-app WebView the full session cookies, so every web page opened inside the app is signed in — lib/http/init.dart:39-44
  `setCookie` → `LoginUtils.setWebCookie()` (login_utils.dart:22-43) at every startup, and again in `onLoginMain` (:45-50), copies SESSDATA/bili_jct into the WebView. Articles, activity pages and links opened there are therefore fully signed in, against the "account only where required" model.
  Fix: give the WebView only the anonymous cookie jar, and inject account cookies only for explicit account flows (login/captcha, the "reset cookie" menu item).

## U8 (claude-xhigh)
- [P2] [A] Download extras send a burst of comment requests per video, overlap across a batch, and recreate deleted folders — lib/services/download/download_extras.dart:143-225
  With the defaults (200 root comments, 10 replies each; download_settings.dart:40-55), each finished download makes about 10 MainList + up to 200 DetailList gRPC calls plus picture/emote downloads. These run `unawaited` (download_service.dart:586-596), so several exports overlap during batch downloads.
  If the user deletes a download while its export is still running, `CommentImages.save` (:489-495) recreates `<folder>/comments_images/`, leaving an orphan folder.
  **hypothesis:** the request volume triggers risk control (-352/-412), which would then also fail the next playurl requests.
  Fix: run exports one at a time from a queue, lower the defaults, and stop (without creating directories) once the entry has been deleted.

## U9 (claude-xhigh)
- [P3] [A] Linux: file arguments are handled as app links, giving a bogus "未知路径" toast; a file opened while the app is running is never played — lib/utils/app_scheme.dart:43-58
  app_links_linux forwards the first command-line argument as a link. Only Windows wraps file paths as `librepili-open:` (windows/runner/main.cpp:63), so on Linux a path reaches `routePush` → "未知路径:… 请截图反馈给开发者". On first launch main.dart:228-237 still plays the file, so the toast appears alongside it. A second launch is forwarded to the running unique GApplication (my_application.cc:103-121) and the file is dropped. The .desktop file uses `%u` and registers no video MIME types.
  **hypothesis:** the exact argument contents that package:gtk delivers.

## U10 (claude-xhigh)
- [P3] [C/D] The Windows update dialog still offers an "exe" download, but the installer was dropped — lib/utils/update.dart:99-101
  win_x64.yml:40-57 now publishes only `LibrePili_windows_*_portable.zip`. The exe button therefore throws `UnsupportedError` and falls back to opening the releases page. Remove the exe button.

## U11 (claude-xhigh)
- [P3] [A] XML danmaku from other tools is mostly not recognised — lib/services/download/download_extras.dart:288-322
  Only `<base>.danmaku.xml` is looked for (danmaku/controller.dart:124-139), so the common `<base>.xml` naming is ignored. The regex needs a double-quoted `p="…"` directly after `<d `. `_xmlUnescape` ignores numeric entities (`&#39;`, `&#x…;`), which then show up raw in the danmaku text.

## U12 (claude-xhigh)
- [P3] [A] The local feed refetches every followed UP on every load and on every (un)follow — lib/pages/local/feed.dart:44-98
  It runs 2 requests at a time with 400 ms gaps. With a few hundred follows that is minutes of requests on one anonymous session, and the set of mids fetched together fingerprints the user.
  **hypothesis:** rate limiting. Fix: cache per UP and fetch only what changed.

## U13 (claude-xhigh)
- [P3] [A] Self-test isolation is incomplete — lib/main.dart:90-121
  The temp dir and the image-cache Hive box (`appTempDirectory`, path_utils.dart:26-34) are shared with a running normal instance, which is the same collision fixed earlier for PiliPlus. On Linux, `--selftest` while the app is running is forwarded to the unique GApplication and never runs, so the harness sees no `--out` marker.

## U14 (claude-xhigh)
- [P3] [A] Offline and local-file playback still sends history heartbeats in login mode — lib/plugin/pl_player/controller.dart:545-548,1459-1488
  `enableHeart` ignores `FileSource`. Plain local files opened with `LocalPlayer` (aid=0, cid=0; local_player.dart:57-68) report `aid=0` every 5 s with the account attached.
  Fix: turn heartbeats off for `FileSource` (at least when cid==0).

## U15 (claude-xhigh)
- [P3] [A] Old single-URL (durl) merges pick segments by probing `0.mp4`, `1.mp4`, … on disk — lib/services/download/download_service.dart:614-625
  A leftover higher-numbered segment from an earlier attempt with the same typeTag would be joined into the output. Use the segment list in index.json instead.
  **hypothesis:** how often segment counts change between attempts.

## U16 (claude-xhigh)
- [P3] [A] A single `_mergingCid`/`_mergeDeleted` pair is shared across merges — lib/services/download/download_service.dart:546-603
  If the user starts another queued download during a merge and it finishes first, `_completeDownload` overwrites both flags. Deleting the first entry mid-merge is then not honoured (it gets re-listed/recompleted), and the second can be paused or restarted mid-merge.

## U17 (claude-xhigh)
- [P3] [A] Favorites panel: the local folders disappear whenever the account folder query fails — lib/pages/fav_panel/view.dart:123-179
  `_localSection` is only built in the `Success` branch. A network or account error hides the device-only folders too.

## U18 (claude-xhigh)
- [P3] [A] Export paths can exceed Windows MAX_PATH — lib/services/download/download_service.dart:764-797
  The name (up to 80 characters plus the quality tag) is used for both the folder and the file, and then `.comments.json` / `.<lan>.srt` suffixes are added. With a download path longer than roughly 60–70 characters, the extras (and possibly the mp4) fail.
  **hypothesis:** Dart's long-path handling on Windows.

## U19 (claude-xhigh)
- [P3] [A] `LocalLibrary.importAll` clears each box before `putAll`, with no validation — lib/services/local_library.dart:37-47
  A malformed backup leaves follows/favorites empty, or makes every `fromJson` cast throw — and these boxes are the only copy without an account. Validate before clearing.

**

## U20 (claude-agent-blind)
- [P2] [A] Login mode: saving favourite live areas always fails — lib/utils/accounts/login_policy.dart:20-54 (call sites lib/http/live.dart:396-416, lib/pages/live_area/controller.dart:58-72)
  `LiveHttp.setLiveFavTag` is an app-API POST signed with `access_key` and carries no csrf. `Api.setLiveFavTag` is not in `_accountApis`, so `requiresAccount` returns false (probed). `_bindRequestAccount` then makes the request anonymous and `_scrubAccessKey` removes the key. `getLiveFavTag` is in the list, so the account's areas load and the edit UI appears, but "保存" is sent without an account and fails. Fix: add `Api.setLiveFavTag` to `_accountApis`. Better, treat any request that carries `access_key` in its params as needing the account in login mode, instead of relying on a hand-kept allowlist.

## U21 (claude-agent-blind)
- [P2] [C] Login mode: the "账号资料" (member profile) page cannot load, and nickname/sign/birthday/sex edits fail — lib/pages/member_profile/view.dart:71-86, 350-378
  The page GETs `${appBaseUrl}/x/v2/account/myinfo` with no csrf and no self-mid key, and posts to `/x/member/app/<type>/update` with an explicit `access_key` and no csrf. Probe: `requiresAccount` is false for both (only `/x/member/web/face/update` is true, because it has csrf). Both requests go out anonymous and the access_key is removed. Upstream sent both with the account. Fix: add these paths to the policy (see the access_key rule above).

## U22 (claude-agent-blind)
- [P2] [C] Login mode: private favourite folders and media-list playlists (watch-later / fav "play all") are sent anonymously — lib/http/fav.dart:53-79, lib/http/user.dart:351-383
  `Api.favResourceList` (query `media_id`) and `Api.mediaList` (query `biz_id`) are not in `_accountApis` and carry neither csrf nor a mid/vmid/up_mid key. The folder list (`favFolder`) loads with the account, but opening a private folder, or playing watch-later as a list, goes out without it. Classification read from code, not probed. **Hypothesis** (server side): bilibili rejects both for anonymous callers (private folder → access denied, watch-later list → not logged in). Fix: add both to `_accountApis`, or add `media_id`/`biz_id` matching the user's own folders.

## U23 (claude-agent-blind)
- [P2] [A] Design gap: in login mode the in-app WebView gets the full login cookie jar — lib/utils/login_utils.dart:22-44, 49; lib/http/init.dart:43
  `onLoginMain` calls `setWebCookie(account)`, and startup calls `setWebCookie()` with `Accounts.main`, which is the LoginAccount in login mode. SESSDATA and bili_jct are therefore installed for every page opened in the in-app browser (articles, links, bilibili pages). This contradicts `LoginPolicy`'s promise that "everything else is sent anonymously". Fix: install only the anonymous jar in the WebView, and attach account cookies only for WebView flows that need them (geetest / login confirmation).

## U24 (claude-agent-blind)
- [P3] [A] `MineController.anonymity` mixes up "login mode off" with "heartbeat role is anonymous" — lib/pages/mine/controller.dart:41-43, 150-164; lib/utils/accounts.dart:114-116
  Scenario: login mode is on and the user sets the heartbeat role to "no account". `Accounts.set` then sets `anonymity = true`, and the menus show "退出无痕模式" while login mode is actually on. Tapping it computes `enterIncognito = !true = false`: it writes loginMode=true (no change) and toasts "已开启登录模式". Reaching incognito takes a second tap. Fix: derive the toggle state only from `Pref.loginMode`, and keep heartbeat anonymity as a separate flag.

## U25 (claude-agent-blind)
- [P3] [A] Multi-segment durl downloads: when the join fails, in-app playback silently plays only segment 1 — lib/services/download/download_service.dart:663-705, 643-655; lib/plugin/pl_player/models/data_source.dart:34-44
  `_exportType1` catches only `UnsupportedError`. Other errors propagate to the catch in `_mergeDownload`, e.g. the `FormatException('bad box …')` that `_Mp4Joiner._readProgressive` throws for a corrupt or truncated segment. The entry is then completed with `mergedPath == null`, and `FileSource` plays only `0.mp4`. The deliberate fallback (segments kept as `<base>.flv`, `<base>.2.flv`…) also sets `mergedPath` to the first file only, so in-app playback again stops after segment 1 with no notice. Fix: when segments stay separate, have the file source play all of them (e.g. an mpv playlist or concat), or at least tell the user playback is partial. `DownloadStatus.failMerge` (bili_download_entry_info.dart:426) is defined but never set; merge failure shows only as a toast.

## U26 (claude-agent-blind)
- [P3] [A] Segment inputs are found by "file exists", not by segment count — lib/services/download/download_service.dart:612-624
  `_mergeDownload` collects `0.mp4`, `1.mp4`, … until one is missing. It never checks against `index.json`'s `segmentList.length`. If an earlier attempt returned more durl segments than the current one, the leftover higher-index files get appended to the video. **Hypothesis** (needs the play-URL response to change segment count within one `typeTag`). Fix: take the count from the Type1 media info, and delete any higher-index segments.

## U27 (claude-agent-blind)
- [P3] [A] DownloadManager: a 416 without a usable Content-Range empties a finished file — lib/services/download/download_manager.dart:121-133
  On 416 the code only treats the file as complete if `Content-Range` gives a total equal to what is on disk. If the header is missing or `total` does not parse, it runs `file.writeAsBytes([])` and starts over. Resuming always restarts at segment 0 (`_startSegment(…, 0, …)`), so every finished segment and every finished DASH stream is re-probed this way. **Hypothesis** (CDN behaviour): mirrors that send 416 without Content-Range force full re-downloads. Separately (lines 44-61), the 6-attempt retry budget never resets when a transfer makes progress, so a long download with occasional drops fails even though it keeps advancing.

## U28 (claude-agent-blind)
- [P3] [A] Desktop: exported video folders share the download root with the internal `<avid>` / `s_<seasonId>` folders — lib/services/download/download_service.dart:736-800, 846-856, 263-280
  On desktop, `_exportDir()` returns `downloadPath` itself. Export folders are named after the sanitised title, and internal page folders are named `<avid>` or `s_<id>`. Scenario: a video whose title is just a number, say "114514", exports to `<root>/114514/`. A later download of av114514 then creates `<root>/114514/c_<cid>` inside it. Deleting that later download calls `deletePage`, which recursively deletes `<root>/114514`, including the first video's exported mp4 that the user chose to keep. Fix: export into a dedicated subfolder, or refuse names that collide with the internal layout.

## U29 (claude-agent-blind)
- [P3] [A] Download extras keep writing after the entry is deleted, and a crash mid-merge leaves an orphan partial folder — lib/services/download/download_extras.dart:480-501; lib/services/download/download_service.dart:585-594, 764-800
  `DownloadExtras.export` runs unawaited. If the user deletes the entry with "同时删除导出的视频文件" while comments are still downloading, `CommentImages.save` calls `file.parent.create(recursive: true)` and recreates `<folder>/comments_images/`, leaving a zombie folder. Also, if the app is killed during a merge, the `.part` file and its folder remain. The next merge sees that folder exists and exports to "name (2)", so the orphan is never cleaned up. Fix: let deletion cancel the export (e.g. a cancelled flag checked between steps), and remove or reuse the half-written folder on retry.

## U30 (claude-agent-blind)
- [P3] [A] Live room: when not logged in, the whole input bar is hidden, including the live-danmaku on/off toggle — lib/pages/live_room/view.dart:771-774
  `if (!isLogin) return SizedBox.shrink()` runs before the comment's "keep the danmaku toggle and like, drop sending". Incognito is the default, so most users lose that toggle in the portrait input bar. **Hypothesis** that the player controls' own toggle remains the only way to reach it. Fix: when not logged in, show the bar with only the toggle.

## U31 (claude-agent-blind)
- [P3] [A] Login mode: "不感兴趣" feedback on the recommend feed is sent anonymously — lib/http/video.dart:474-530; lib/common/widgets/video_popup_menu.dart:100-130
  The UI checks that the recommend account has an `access_key`, but `feedDislike` / `feedDislikeCancel` are not account APIs (probed: `requiresAccount` is false), so the request carries no account and the feedback does nothing. Fix: either list them as account APIs or hide the menu item, since the feed is anonymous by design.

## U32 (claude-agent-blind)
- [P3] [A] Importing a settings backup can change `loginMode` without re-applying accounts — lib/utils/storage.dart:94-102
  `importAllJsonSettings` replaces the whole setting box, including `loginMode` and `hideInteraction`, but never calls `Accounts.refresh()`, updates `MineController.anonymity`, or rebuilds the nav bar. Account state stays inconsistent until restart. Fix: after import, re-run the same steps as `onChangeAnonymity`.

## U33 (claude-agent-blind)
- [P3] [D] The Windows update dialog still offers an "exe" installer — lib/utils/update.dart:99-101
  CI no longer builds the Inno Setup installer (win_x64.yml). Tapping "exe" finds no asset and throws "platform not found". Remove the button.

## U34 (claude-agent-blind)
- [P3] [D] `audit-logs/` is gitignored but tracked on the branch — .gitignore:153
  The pass-1 commit tracks about 40k lines under `audit-logs/` (full diffs and prompts) while the same commit adds `audit-logs/` to .gitignore. Either untrack it or drop the ignore rule.

## U35 (claude-agent-anchored)
- [P2] [C] Login mode: profile edit and live-tag write now fail — `lib/utils/accounts/account_manager/account_mgr.dart:48-53, 263-283`; `lib/utils/accounts/login_policy.dart:19-54`; `lib/pages/member_profile/view.dart:343-372`; `lib/http/live.dart:393-416`
  `/x/member/app/*/update` (nickname, signature, birthday, gender) and `Api.setLiveFavTag` are POST writes with no csrf that authenticate only through `access_key` in the body. Neither is on `_accountApis`, so they are bound anonymously. Before this commit the leaked `access_key` still authenticated them. Now the scrub removes it (probe: `Map.cast` removal mutates the underlying `Map<String,String>` body). With login mode on, editing your own profile or saving live tags returns a not-logged-in error. Fix: add `Api.setLiveFavTag` and the member-app update paths to `_accountApis`, or treat any non-GET that carries `access_key` as account-required.

## U36 (claude-agent-anchored)
- [P3] [A] A 416 without Content-Range truncates the saved file, and a later failure deletes it — `lib/services/download/download_manager.dart:121-133, 67-77`
  On resume of a file that is already complete, a CDN that answers 416 without a parseable `bytes */N` makes the code empty the file, even though all its bytes were saved. Multi-segment Type1 resume depends on exactly this 416 path for every finished segment. If the next attempts then fail (network down), `_fail` deletes the now-empty file. That contradicts the claim that saved bytes are never thrown away. Fix: on 416 with an unknown total, keep the file and use the size from `index.json`, or re-probe; never truncate a non-empty file there.

## U37 (claude-agent-anchored)
- [P3] [A] Unawaited extras export races with deletion and recreates the exported folder — `lib/services/download/download_service.dart:586-596`; `lib/services/download/download_extras.dart:480-500`
  Deleting a just-completed entry with "同时删除导出的视频文件" removes the export folder while `DownloadExtras.export` is still running. `CommentImages.save` then calls `file.parent.create(recursive: true)`, which recreates `<export>/comments_images`, and `_comments` writes `<base>.comments.json` into it. The result is an orphan folder in public `Download/LibrePili` that is not linked to any entry. The same race hits the self-test cleanup (`self_test.dart:449-455`), and its `folderFiles` report (`:429-434`) no longer includes the extras. Fix: keep the extras future per entry and cancel or await it in `deleteDownload`.

## U38 (claude-agent-anchored)
- [P3] [A] Merge guard is one shared field, so overlapping merges clobber each other — `lib/services/download/download_service.dart:546-566, 599-603`
  Scenario: entry A is deleted during its merge, so entry B starts. B is small, finishes and begins merging (`_mergingCid = B`, `_mergeDeleted = false`) before A's remux returns. A's return then sets `_mergingCid = null`, so B loses its pause/start guard (the U28 double-download returns). A's deletion flag has also been reset, so in the Windows locked-file case this fix targeted, A is re-added to `downloadList`. Fix: per-entry state (a set of merging cids and a set of cids deleted while merging), or capture the flag in a local closure.

## U39 (claude-agent-anchored)
- [P3] [A] Type1 merge takes segments from what is on disk, not from the segment list — `lib/services/download/download_service.dart:612-625` — **hypothesis**
  The inputs are `0.mp4, 1.mp4, …` for as long as each file exists, ignoring the segment count in `index.json`. If an earlier attempt left more segments than the current play URL has (a different segment layout after re-fetching), the stale files are joined or remuxed onto the end. Fix: build the inputs from the segment count in `index.json`.

## U40 (claude-agent-anchored)
- [P3] [A] Fallback multi-part export: only the first part is media-scanned, unknown formats get `.mp4` — `lib/services/download/download_service.dart:578-579, 682-688`
  When remux or join is not possible, parts `<base>.2.ext…` are moved into the export folder, but `_scanMedia(output)` indexes only the first. Android galleries and players then miss the other parts. Content that is neither FLV nor MP4 is still named `.mp4`. Fix: scan every moved part, and choose the extension from a content sniff.

