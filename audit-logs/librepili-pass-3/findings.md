## U1 (codex)
- [P0] SAF provider allows path traversal outside declared roots — `android/app/src/main/kotlin/com/example/piliplus/BiliDocumentsProvider.kt:120-259`  
  When the optional document provider is enabled, `retrieveFile()` joins attacker-controlled `documentId` suffixes directly under private roots without canonical containment checks, and create/rename accept raw names. A client with provider access can use `../` or crafted names to read, overwrite, move, or delete files outside the selected logical root. Canonicalize the resolved file and require it to remain under the chosen root; reject separators, `.` and `..` in `displayName`.

## U2 (codex)
- [P1] Enabling the system proxy disables TLS verification — `lib/http/init.dart:148-170`  
  The proxy branch sets `badCertificateCallback` / `onBadCertificate` to always accept certificates, even when the explicit “disable SSL certificate verification” setting is off. Any proxied HTTPS request carrying cookies or `access_key` can be intercepted by a MITM proxy or hostile network. Keep certificate validation on for proxied connections unless the separate dangerous SSL-bypass preference is explicitly enabled.

## U3 (codex)
- [P2] WebView permits mixed content for all pages — `lib/pages/webview/view.dart:463-474`  
  `MIXED_CONTENT_ALWAYS_ALLOW` lets HTTPS pages load insecure HTTP subresources, including pages where account cookies are temporarily injected for note flows. This weakens transport guarantees and can expose authenticated WebView sessions to network injection. Default to `MIXED_CONTENT_NEVER_ALLOW` and add narrowly scoped exceptions only for known pages that truly require it.

## U4 (claude-xhigh)
- [P2] [A] Login mode: requests that are sent anonymously still carry the account's csrf (`bili_jct`) — lib/utils/accounts/login_policy.dart:126-136, lib/utils/accounts/account_manager/account_mgr.dart:261-281
  `requiresAccount` makes a GET that carries `csrf` anonymous, but `_scrubAccessKey` only removes `access_key`/`mobile_access_key`. The csrf goes out on the anonymous request, next to the per-launch anonymous buvid3.
  Call sites: `dynamicDetail` (dynamics.dart:284, every dynamic opened), `upowerRank` (member.dart:759), `archiveNoteList` (video.dart:950-953, not the listed `archiveNote`), and `replyReplyList(isLogin:true)` (reply.dart:75).
  Each of these links the anonymous session to the account session, which breaks the "everything else anonymous" promise. Fix: strip `csrf`/`csrf_token`/`biliCSRF` in the scrub (and re-sign where the params are signed), or stop adding it at these call sites.

## U5 (claude-xhigh)
- [P2] [A] An empty (or too-short prefix) SponsorBlock server address silently breaks every bilibili request — lib/utils/accounts/account_manager/account_mgr.dart:26,55,223-227; lib/pages/sponsor_block/view.dart:346-356
  `_skipCookie` tests `path.startsWith(blockServer)`, and the server dialog saves any text without checking it. If the user clears the field and taps 确定, `startsWith('')` is true for every path.
  `onRequest` then returns early for all requests: no cookies, no headers, no `access_key`, no app signing, and Set-Cookie is not saved. App and gRPC calls fail signature checks, and login mode stops working. The empty value is persisted, so this repeats on every launch until 重置.
  Fix: only save a value that parses as an http(s) URL with a host, and match on the host rather than a raw prefix.

## U6 (claude-xhigh)
- [P2] [A] Turning on the proxy setting also turns off TLS certificate checking for all API traffic — lib/http/init.dart:148-175
  With 设置代理 on, the HTTP/1.1 client gets `badCertificateCallback = (..) => true` and the HTTP/2 client gets `onBadCertificate = (_) => true`. This is independent of the separate `badCertificateCallback` switch, and the settings entry (extra_settings.dart:621-632) gives no warning.
  Any proxy, or anything between the app and the proxy, can MITM SESSDATA, `access_key` and csrf. Fix: apply only the explicit certificate switch, not the proxy switch.

## U7 (claude-xhigh)
- [P2] [A] WebView "reset cookie" leaves the account cookies installed for the rest of the session, and "reset all data" never removes them — lib/pages/webview/view.dart:243-248,386-399; lib/utils/login_utils.dart:45-67; lib/utils/storage.dart:153-165
  `resetCookie` calls `setWebCookie()` (the main LoginAccount in login mode) but does not set `_accountCookie`, so `dispose` never restores the anonymous jar. Every later in-app page on bilibili domains is signed in.
  关于 › 重置所有数据 → `GStorage.clear` → `Accounts.clear` never cleans the WebView cookie store. At the next start, `setAnonymousWebCookie` only deletes cookies for accounts still in the (now empty) box, so the deleted account's SESSDATA stays in the WebView indefinitely.
  The doc comment at login_utils.dart:45-48 promises otherwise. Fix: set `_accountCookie = true` on reset, and call `deleteAllCookies` in `GStorage.clear` / `Accounts.clear`.

## U8 (claude-xhigh)
- [P2] [A] Linux: taking a note (or "reset cookie") injects the account cookies into WebKitGTK and nothing ever removes them — lib/pages/webview/view.dart:67-75,386-394; lib/utils/linux_cookie_manager.dart:33-65; lib/utils/login_utils.dart:49-50
  The note URL makes `openLinux` inject the main account's SESSDATA/bili_jct through `document.cookie`, with `max-age=31536000` and not HttpOnly, into the shared WebKit context. On Linux `setAnonymousWebCookie` returns immediately.
  Later "anonymous" windows only overwrite the anonymous jar's names (buvid3…), so SESSDATA survives and every bilibili page opened in the Linux webview afterwards is signed in. It is also readable by page scripts.
  **hypothesis:** whether WebKitGTK's default context persists these cookies across app restarts.

## U9 (claude-xhigh)
- [P2] [A] Cookie login fails for the normal `a=b; c=d` format — lib/pages/login/controller.dart:176-187; lib/utils/accounts/account.dart:206-215
  The check request trims each piece (`validateCookie`), but the saved jar splits the raw text on `;` without trimming. It then builds `Cookie(' bili_jct', …)`, and dart:io rejects names containing space (SDK `_http/http_headers.dart:1024-1026,1264-1288`) with a FormatException, so the user sees "登录失败: FormatException…".
  Values are also rebuilt with `list.skip(1).join()`, which drops `=` from values that contain it. Fix: trim keys and values, and use `join('=')`.

## U10 (claude-xhigh)
- [P2] [A] One failed WBI key fetch leaves WBI signing broken for the rest of the day or session — lib/utils/wbi_sign.dart:77-109
  `getWbiKeys` stores today's timestamp before fetching. On failure (offline at start, any DioException), `_getWbiKeys` returns `''` without storing a key, and `_future` keeps that completed `''`.
  Every later `makSign` that day returns `''`, so all WBI-signed endpoints (web recommend, space, search…) fail until midnight or a restart. The `.day == nowDate.day` check also accepts keys exactly one month old.
  Fix: do not cache a failed future (reset `_future` when the result is `''`), and compare the full date.

## U11 (claude-xhigh)
- [P3] [C] Login mode: the comment anti-fraud check's "with account" lookups are sent anonymously, so it gives wrong verdicts — lib/utils/reply_utils.dart:174-305; lib/http/reply.dart:59-78
  `replyReplyList(isLogin:true)` is a GET to `Api.replyReplyList`, which is not in `_accountApis`, so LoginPolicy sends it anonymously (while still sending the csrf, see the first finding). The self-visible vs. anonymous comparison therefore compares anonymous with anonymous. A shadow-banned root reply is reported as "无法找到你的评论" instead of "shadow ban", and sub-replies always end in "评论不可见".
  Fix: bind these check calls to the account explicitly (listed `_explicitAccountApis`-style), or disable the check in LibrePili.

## U12 (claude-xhigh)
- [P3] [A] Error toasts show the full request URL, including `access_key`/csrf — lib/utils/accounts/account_manager/account_mgr.dart:149,169-189; lib/http/init.dart:300-309
  `toast` shows `dioError(err) + err.requestOptions.uri`. In login mode, app GET requests have `access_key` (and a signature) added to `queryParameters` (account_mgr.dart:78-87), and several web GETs carry csrf (e.g. loginDevices, followedUp). Users screenshot these toasts into issues, the app itself asks for screenshots elsewhere, and that publishes the token. Fix: show only scheme, host and path.

## U13 (claude-xhigh)
- [P3] [A] RetryInterceptor re-sends non-idempotent POSTs — lib/http/retry_interceptor.dart:52-73
  `connectionError`/`unknown` errors are retried up to `retryCount` (default 2) whatever the method. On HTTP/1.1 (the default), "Connection closed before full header was received" maps to connectionError (dio io_adapter.dart:178-185), even though the server may already have processed the request. Coin, like, reply and danmaku POSTs can therefore be applied twice (e.g. 2 coins for one tap).
  **hypothesis:** how often the server has already processed the request in these cases. Fix: only retry GET/HEAD, or only errors where nothing was sent.

## U14 (claude-xhigh)
- [P3] [A] RetryInterceptor's manual redirect keeps the original Cookie header, even across origins — lib/http/retry_interceptor.dart:16-50; lib/utils/accounts/account_manager/account_mgr.dart:90-101
  dart:io does not follow POST 301/302/307/308 (SDK http_impl.dart:647-658). The interceptor follows them itself by rewriting `options.path` and re-running `fetch`. `onRequest` then merges the previous `cookie` header (SESSDATA, bili_jct) into the redirected request whatever the target host, adds the account headers (`x-bili-mid`), and re-sends the POST body. dio_http2_adapter strips these for its own cross-origin redirects; this path does not.
  **hypothesis:** that bilibili sends such POST redirects. Fix: drop cookie/authorization headers when the origin changes.

## U15 (claude-xhigh)
- [P3] [A] An external link can open the note-app URL and make the WebView load it signed in — lib/utils/app_scheme.dart:379-387; lib/pages/webview/view.dart:54-55,228-240,478-497
  `bilibili://browser/?url=https://www.bilibili.com/h5/note-app…` from any app or website opens `/webview`. `_isNoteUrl(_url) && Accounts.main.isLogin` then installs the full account jar before loading, and further navigation in that WebView stays signed in until close.
  The `infoBarClicked` / `finishButtonClicked` JS handlers are also registered for every page, and `int.parse(oid)` throws on non-numeric input. Fix: install account cookies only when the note page is opened from the video page's widget (`widget.url`), not from route parameters.

## U16 (claude-xhigh)
- [P3] [A] Note title is put into the note/add form body without URL-encoding — lib/pages/webview/view.dart:589-599
  `replaceFirst('&title=--&', '&title=${widget.title}&')` inserts the raw video title. A title containing `&`, `=`, `+` or `%` truncates the title or injects extra form fields into `x/note/add`. Fix: use `Uri.encodeQueryComponent(widget.title!)`.

## U17 (claude-xhigh)
- [P3] [A] Importing a settings file without `setting`/`video` keys wipes all settings and turns login mode off — lib/utils/storage.dart:95-111
  Only the LocalLibrary part is validated. `setting.clear().then((_) => setting.putAll(map['setting']))` throws on null after clearing, so the `.then(put loginMode)` that should restore login mode never runs. The same happens to `video`.
  Triggered by importing the wrong JSON (the account export, the search-history export, or a hand-trimmed backup) into 导入设置. Fix: validate both boxes are Maps before clearing anything.

## U18 (claude-xhigh)
- [P3] [A] The settings export contains secrets in plain text — lib/utils/storage.dart:83-90; lib/utils/storage_pref.dart:323-332,631-641
  `setting.toMap()` includes the WebDAV password and the SponsorBlock private `blockUserID`, which acts as a password for that service. These go to the clipboard or a shareable file (export_import.dart:21-39) and up to the WebDAV server. Import also overwrites this device's WebDAV credentials. Fix: leave credential keys out of export/import.

## U19 (claude-xhigh)
- [P3] [A] Stored accounts are deleted permanently on a single "not logged in" response, and refresh_token is never used — lib/pages/mine/controller.dart:101-132; lib/utils/login_utils.dart:90-98; lib/pages/login/controller.dart:628-632
  `isLogin == false` or '账号未登录' from `userInfo` leads to `Accounts.deleteAll`, which deletes the cookies and the stored `refresh_token`. No cookie/token refresh flow exists anywhere (the only reference to refresh_token is the login controller storing it). An expired SESSDATA, or a transient -101 during risk control, destroys a renewable login without confirmation. Fix: try a refresh first, or mark the account expired instead of deleting it.

## U20 (claude-xhigh)
- [P3] [A] Live-room danmaku stops for good after any socket drop — lib/tcp/live.dart:204-212,313-323; lib/pages/live_room/controller.dart:469-488
  `onDone`/`onError` call `close()`, but `_msgStream` stays non-null. `startLiveMsg` then returns early (`if (_msgStream != null) return;`), so a Wi-Fi/cellular switch ends live chat silently with no reconnect or new token.
  Also: `fromBytesData` only checks `length < 10` but reads 16 bytes, and `onData` is not wrapped in try, so short frames throw uncaught. Fix: set `_msgStream` to null on close and reconnect with a fresh token.

## U21 (claude-xhigh)
- [P3] [A] Desktop "save original image" moves files out of the image cache — lib/utils/image_utils.dart:152-191; lib/utils/extension/file_ext.dart:19-26
  `getSingleFile` returns the cache manager's own file. On desktop `moveOrCopy` renames it into the target folder (overwriting any same-named file there), leaving the cache entry pointing at a missing file. On partial failure, the `eagerError` cleanUp deletes other cached files.
  **hypothesis:** the cache self-heals on next display. Fix: copy instead of moving.

## U22 (claude-xhigh)
- [P3] [A] Changing the desktop download path re-reads the list without clearing the waiting queue — lib/services/download/download_service.dart:72-85,109; lib/pages/setting/models/extra_settings.dart:768-793
  `_readDownloadList` clears `downloadList` but not `waitDownloadQueue`. Switching paths (or 重置, then back) keeps stale entries from the old folder and adds duplicates of re-read incomplete entries, so the same cid can be queued twice. The current download keeps writing into the old path. Fix: clear or dedupe the queue, and pause the active download on a path change.

## U23 (claude-xhigh)
- [P3] [A] Crash logging is on by default and writes `.pili_logs.json` into the user's Documents folder on Windows and Linux — lib/services/logger.dart:22-32; lib/utils/storage_pref.dart:665-666; lib/main.dart:206-224
  `getApplicationDocumentsDirectory()` is `%USERPROFILE%\Documents` (often synced to OneDrive) on Windows and ~/Documents on Linux. The file name is the same as upstream PiliPlus, so both apps (and `--selftest`) append to one file, and 清除日志 in either app wipes both. Fix: use `appSupportDirPath` and a LibrePili-specific name.

## U24 (claude-xhigh)
- [P3] [A] Mobile 清除缓存 deletes the side-file cache of a local video that is still open — lib/utils/cache_manager.dart:70-85; lib/services/local_player.dart:151-184
  `clearLibraryCache` removes everything under the temp dir except the image cache, including `local_documents/<hash>` folders that `_mirrorsInUse` still counts. Comments JSON and comment images for an open Android SAF video then disappear mid-session. Fix: skip `local_documents` (or the folders still in use).

## U25 (claude-xhigh)
- [P3] [A] Android "允许三方APP访问私有存储" exposes credentials, and a subtree grant can be escaped — android/app/src/main/kotlin/com/example/piliplus/BiliDocumentsProvider.kt:120-122,184-237,239-260; lib/pages/setting/models/extra_settings.dart:77-84
  When enabled, the provider serves the whole data dir, including `hive/account.hive` with plaintext SESSDATA and access keys, and the setting text does not warn about this. `retrieveFile` never normalises `..`, and `isChildDocument` is a plain `startsWith`, so an app holding a subtree grant can reach any file with `…/sub/../../hive/…`. The `mt:*` `call()` methods (chmod, symlink) do no grant check. **hypothesis:** exploitability under SELinux and grant rules.

## U26 (claude-xhigh)
- [P3] [A] biliSendCommAntifraud sends the full cookie string to an unverified package — android/app/src/main/java/com/example/piliplus/AndroidHelper.java:77-104; lib/utils/reply_utils.dart:69-93
  The explicit intent targets a package name only, with no signature or installer check. Any sideloaded app using that package name receives SESSDATA and bili_jct for every comment sent while the (opt-in) switch is on. Fix: verify the target's signing certificate first, or send only what the check needs.

## U27 (claude-xhigh)
- [P3] [B] Local follows: the box key and the `mid` field are not checked against each other on import — lib/services/local_library.dart:52-70,87-100
  `checkImport` validates value shapes but not that key == `'$mid'`. A hand-edited or merged backup with a mismatched key shows the UP in the follow list, while `isFollowed(mid)` is false. Following again creates a second entry and "unfollow" cannot remove the first. Fix: re-key imported follows by their `mid`.

## U28 (claude-xhigh)
- [P3] [A] macOS: a custom download path does not survive a restart under the sandbox — **hypothesis** — macos/Runner/Release.entitlements:5-10; lib/main.dart:62-80
  Only `files.user-selected.read-write` is granted, and no security-scoped bookmark is stored for the picked folder. At the next launch, access to the folder is presumably gone. `_initDownPath` then either fails to create it and silently deletes the setting, or keeps a path it cannot write to. Fix: store and resolve an app-scope bookmark.

## U29 (agent-net)
- [P1] [A] Network-error toasts show the full request URL, including `access_key` and `csrf` — lib/utils/accounts/account_manager/account_mgr.dart:169-189 (called from :149 and lib/http/init.dart:301)
  `toast()` shows `dioError(err) + err.requestOptions.uri.toString()`. `onRequest` has already added `access_key`, `appkey`, `ts` and `sign` to the query of account-bound app GETs (:78-86). Probe: after `onRequest`, the URI of a login-mode GET to `app.bilibili.com/x/v2/account/myinfo` was `...?foo=1&access_key=SECRET_ACCESS_KEY&appkey=...&sign=...`. So a timeout on any account-bound app GET puts the long-lived access token on screen, where a screenshot for a bug report exposes it. The same happens with `csrf` (the bili_jct cookie value) on web writes. Fix: show only scheme, host and path, or strip `access_key`, `mobile_access_key`, `csrf`, `csrf_token`, `biliCSRF` and `sign` before showing.

## U30 (agent-net)
- [P1] [A] Leftover from the pass-1 fix: GETs that were made anonymous still send the account's `csrf` (bili_jct) — lib/utils/accounts/account_manager/account_mgr.dart:53,261-281; lib/utils/accounts/login_policy.dart:370-378
  Pass 1 made "GET with csrf" anonymous, but `_scrubAccessKey` removes only `access_key` and `mobile_access_key`. The call sites still add `csrf: Accounts.main.csrf`: dynamics.dart:284 (`dynamicDetail`), reply.dart:75 (`replyReplyList`), video.dart:954 (`archiveNoteList`, always), member.dart:759 (`upowerRank`). Probe: in login mode all four go out as `AnonymousAccount` with only the anonymous buvid3 cookie, but the query still holds `csrf=SECRETJCT`. The "anonymous" request therefore carries a per-account secret and can be tied to the account. Fix: also scrub the csrf keys when binding anonymously (re-signing if needed), or remove `csrf` from these GETs.

## U31 (agent-net)
- [P2] [A] The comment-visibility check no longer checks as the logged-in user, so its verdicts are wrong — lib/utils/reply_utils.dart:198-285 with lib/http/reply.dart:59-78
  The check compares "as the account" (`isLogin: true`) against "without an account". `Api.replyReplyList` is not in `_accountApis`, so the "as the account" request is now also sent anonymously (confirmed by the probe above). Both sides are then anonymous, so the shadow-ban case (only visible to yourself) reports "无法找到你的评论" instead of "shadow ban". A reply missing from page 1 of the main list reports the false "评论区被戒严" warning. Fix: have these check calls pass the account explicitly and add `replyReplyList` to `_explicitAccountApis`. Otherwise drop the account half of the check and change the messages.

## U32 (agent-net)
- [P2] [A] Turning on the proxy silently turns off TLS certificate checks — lib/http/init.dart:148-175
  When `enableSystemProxy` is on, both adapters get `badCertificateCallback => true` / `onBadCertificate => true`, whatever the "禁用 SSL 证书验证" switch says. The proxy dialog does not mention this. Any proxy, or anything on the path to it, can then intercept SESSDATA, `access_key` and passwords. A settings import can switch the proxy on as well, since proxy settings are part of the export. Fix: tie certificate bypass only to `Pref.badCertificateCallback`, and warn in the proxy dialog.

## U33 (agent-net)
- [P2] [A] Importing settings wipes a whole settings box when the backup lacks that section, and turns login mode off — lib/utils/storage.dart:95-111
  `setting.clear().then(putAll(map['setting']))` and the same for `video` run with no check. `LocalLibrary.checkImport` only validates the local-library boxes. Probe: importing `{'setting':{...}}` threw `type 'Null' is not a subtype of 'Map'` and left `video` empty. Importing `{'video':{...}}` left `setting` completely empty, including `loginMode`, because the `put(loginMode)` step never ran. This also applies to WebDAV restore (webdav.dart:114). Fix: check that both maps are present and are maps before clearing anything, like `checkImport`. If one is missing, skip that box.

## U34 (agent-net)
- [P2] [A] A failed danmaku fetch blocks the whole video download — lib/services/download/download_service.dart:363-392,422-424
  `_startDownload` returns as soon as `downloadDanmaku` fails. Any failed segment (`.data` throws on `Error`) sets `failDanmaku`, and the video is never fetched. If `totalTimeMilli` is 0 (`page.duration` null at :159, or a pgc episode with no duration at :227), `seg <= 0` throws on every attempt, so that item can never be downloaded. Fix: treat danmaku as optional (log it, continue with the video, retry later via `isUpdate`), and skip it when the duration is unknown.

## U35 (agent-net)
- [P2] [A] Resuming a download can append bytes from a different stream onto the partial file — lib/http/download.dart:26-39,60-86; lib/services/download/download_manager.dart:177-193
  Each start asks for a new play URL and picks the stream again from current settings: `Pref.preferCodecs`, the video-role login state, and `tryLook: !isLogin && Pref.p1080`. `index.json` is overwritten. `_attempt` resumes with `Range: bytes=<received>-` and only checks the start offset. It never compares the new stream's total size (or id/codec) with the one that was partly saved. So pausing, changing the preferred codec or login mode, then resuming at the same quality can write an AVC start and an HEVC end into the same `video.m4s`. The merge then fails or produces a broken file. If the quality changes instead, `typeTag` changes, so the partial files are left behind in the old folder. Fix: save the chosen stream id/codecid/size on first start and reuse them when resuming, or restart from 0 when the Content-Range total differs from the saved `totalBytes`.

## U36 (agent-net)
- [P2] [A] Changing the download folder leaves the old queue in memory and can queue items twice — lib/services/download/download_service.dart:72-84 (called from lib/pages/setting/models/extra_settings.dart:775,791)
  `_readDownloadList` clears `downloadList` but not `waitDownloadQueue`. Switching A→B keeps A's unfinished entries in the queue, and they still point at A. Switching back to A adds them a second time. The download that is running keeps writing into the old folder. Fix: clear the queue (and pause or cancel the current download) before re-reading, or refuse to change the path while downloads are queued.

## U37 (agent-net)
- [P2] [A] Automatic retry resends POST writes that the server may already have processed — lib/http/retry_interceptor.dart:52-73
  With the defaults (retryCount 2, HTTP/2 off, so the dart:io adapter), dio maps "Connection closed before full header was received" to `connectionError` after the body was fully sent (dio io_adapter.dart:178-186, read). `sendTimeout` and `unknown` are retried too. Only HTTP/2 `TransportConnectionException` is excluded. So a comment, danmaku, coin or dynamic post can be sent twice. **Hypothesis** (not probed): that the server really does process the first attempt in these cases. Fix: retry only idempotent methods, or only connection errors raised before the request was sent.

## U38 (agent-net)
- [P3] [A] A failed WBI key fetch is cached until restart; the date check compares only the day of the month; the fetch sends the account — lib/utils/wbi_sign.dart:77-109
  If the first fetch of the day fails, `_getWbiKeys` returns `''` without storing it. On an install with no cached key, the next calls go through `_future ??=` and get the same `''`, so every WBI-signed request (search, space lists) is signed with an empty key until the app restarts. The `.day ==` check also treats the same day of a different month as "today". The fetch uses `Api.userInfo`, which is in `_accountApis`, so in login mode the first anonymous WBI request of each day is preceded by a request carrying the account's cookies. Fix: reset `_future` on failure, compare the full date, and fetch `/nav` with `NoAccount`.

## U39 (agent-net)
- [P3] [A] Crash logs are on by default and are written to the user's Documents folder, which is shared — lib/services/logger.dart:22-31; lib/utils/storage_pref.dart:665-666; lib/utils/json_file_handler.dart:175-179
  `.pili_logs.json` goes to `getApplicationDocumentsDirectory()`. On Windows and Linux that is `~/Documents` (often cloud-synced). The self-test profile is not kept apart from it. Upstream PiliPlus uses the same file name, so both apps write to and clear the same file. It grows without limit. In `JsonFileHandler.add`, one failed write leaves `_future` failed, and every later write fails with it. Fix: move the file into `appSupportDirPath`, cap its size, and recover the chain on error.

## U40 (agent-net)
- [P3] [D] The update check runs on every launch by default, and "查看完整更新" links to the upstream-mirror branch — lib/utils/update.dart:24-30,68-70; lib/utils/storage_pref.dart:475-476
  `autoUpdate` defaults to true, so a privacy-first build contacts api.github.com at every start. The commits link goes to `.../commits/main`, but the fork's code is on `librepili` (`main` tracks upstream). Fix: link to `librepili`, and consider making the check opt-in.

## U41 (agent-net)
- [P3] [A] Exported settings include the WebDAV password in plain text — lib/utils/storage.dart:83-90; lib/utils/storage_key.dart:190-193
  `exportAllSettings` writes the whole `setting` box: `webdavPassword`, `webdavUsername`, proxy host, `blockUserID`. The export goes to the clipboard or a shared file. Fix: leave the credential keys out of the export, or ask before including them.

## U42 (agent-net)
- [P3] [A] Saving original images on desktop moves the files out of the image cache — lib/utils/image_utils.dart:145-190; lib/utils/extension/file_ext.dart:19-26
  `downloadImg` gets files from `CacheManager.manager.getSingleFile` and calls `moveOrCopy`, which is `rename` first. The cache database still lists the moved file. Also, one failed image deletes the cached copies of the others (`cleanUp: tryDel`). Fix: copy instead of move, and do not delete cache files.

## U43 (agent-player)
- [P2] [A] A low-weight danmaku stops the rest of its 100 ms bucket from showing — lib/pages/danmaku/view.dart:115-118
  Inside `for (DanmakuElem e in currentDanmakuList)`, the check `if (e.weight < danmakuWeight) return;` leaves the whole position listener, so every element after the first low-weight one in that bucket is dropped. With the 屏蔽等级 (danmaku weight) set above 0, high-weight danmaku are silently lost. It gets worse for XML danmaku without the 9th field: `weight` is 0 there (download_extras.dart:333), so one such element blanks its bucket. Probed: the same loop shape with weights [1,9,9] added nothing. Fix: use `continue`.

## U44 (agent-player)
- [P2] [A] Tapping a live danmaku that contains a time string throws in build — lib/plugin/pl_player/view/view.dart:136-137, 2269, 2245-2255
  `_buildDmAction` calls `_getValidOffset(item.content.text)` before it checks the extra type. That reads `videoDetailController`, which is `late final … = widget.videoDetailController!`, and the live room passes null. With enableTapDm on (default true on mobile), tapping a live danmaku such as "今晚8:30见" throws a `_TypeError` inside the overlay build. Probed: the regex matches "8:30", and the late null-check throws `_TypeError`. Fix: only compute `seekOffset` in the `VideoDanmaku()` branch, or check `widget.videoDetailController != null`.

## U45 (agent-player)
- [P2] [A] Failed danmaku segments are re-requested every 100 ms — lib/pages/danmaku/controller.dart:43-61, 100-108
  `queryDanmaku` removes the segment from `_requestedSeg` on any error. `getCurrentDanmaku` runs on every 100 ms bucket while playing and asks again whenever the segment is missing. Offline, or on a server/risk-control error, this sends about 10 gRPC `dmSegMobile` requests per second for as long as playback continues, which can itself trigger rate limiting. Fix: keep the segment marked as failed and retry with backoff (or retry only on seek or segment change).

## U46 (agent-player)
- [P2] [A] Live danmaku stream dies silently after a disconnect and does not reconnect — lib/tcp/live.dart:204-209; lib/pages/live_room/controller.dart:469-488
  Socket `onDone`/`onError` → `close()`, but `LiveRoomController._msgStream` stays non-null. `startLiveMsg()` then returns early at `if (_msgStream != null) return;` (line 476). The same happens when every server fails in `init()`, which only shows a toast. After any network blip, live chat and danmaku stop until the user pauses and resumes or leaves the room. `dmInfo` (the token) is also cached for reuse. Fix: have `LiveMessageStream` report closure, clear `_msgStream`, and reconnect with backoff, fetching a new token if needed.

## U47 (agent-player)
- [P2] [A] The offline/local player shows 发弹幕 and sends danmaku to Bilibili — lib/pages/video/view.dart:1399-1414; lib/pages/video/widgets/header_control.dart:1861-1875; lib/pages/video/controller.dart:646-684
  Neither send button checks `isFileSource`: the tab-bar one is gated only on `!Pref.hideInteraction && Accounts.main.isLogin`, and the header one sits outside the `if (!isFileSource)` block. The Enter shortcut (player_focus.dart:236-241) reaches the same code. In an offline download this posts a danmaku to the real cid with the account. For plain local files (cid 0, bvid '') the request just fails. Fix: hide the buttons and short-circuit `showShootDanmakuSheet` when `isFileSource`.

## U48 (agent-player)
- [P3] [A] Danmaku actions on offline/local videos send like, recall and report requests — lib/plugin/pl_player/view/view.dart:2300-2368
  The tap overlay for `VideoDanmaku` is the same for file sources. Like, recall and report call `HeaderControl.likeDanmaku`, `deleteDanmaku` and `reportDanmaku` with `plPlayerController.cid!`. That is the real cid for downloads and 0 for local files, and XML danmaku ids are usually 0 (only `idStr` is set). Fix: show only copy and seek when `isFileSource`.

## U49 (agent-player)
- [P3] [A] Toggling fullscreen resets danmaku speed while playback is sped up — lib/pages/danmaku/view.dart:68-77
  `didUpdateWidget` calls `DanmakuOptions.get(notFullscreen: …)` without `speed:`, so `duration` goes back to the 1x value. For example, at 2x the danmaku move too slowly after entering fullscreen. The next `setPlaybackSpeed` then scales that wrong base (pl_player/controller.dart:1130-1141), so the error compounds: going back to 1x gives twice the normal duration. Fix: pass `speed: playerController.playbackSpeed`.

## U50 (agent-player)
- [P3] [A] Super-resolution state follows the shared player across video pages — lib/plugin/pl_player/controller.dart:687-689, 791-793
  `isAnim` and `superResolutionType` are `late final` on the singleton `PlPlayerController`, which nested video pages share through `getInstance` (it only increments the count). The shader is applied only when the player is created. Open an anime (pgcType 1/4) with SR on, then open a related UGC video: it plays with Anime4K shaders and shows the SR button. In the reverse order, SR is unavailable for the anime. Runtime not probed; confirmed by reading the code. Fix: recompute per `setDataSource` and re-apply or clear the shader.

## U51 (agent-player)
- [P3] [A] Pause never sends a heartbeat — lib/plugin/pl_player/controller.dart:937-955, 1491-1496
  In the `stream.playing` listener, the pause branch sets `playerStatus = .paused` before calling `makeHeartBeat(seconds, type: .status)`. `makeHeartBeat` returns early when `playerStatus.isPaused && !isManual`, so `.status` only fires on resume. The saved watch position can lag by up to about 5 s whenever the user pauses. Fix: pass `isManual: true` for status beats, or send the beat before changing the status.

## U52 (agent-player)
- [P3] [A] Live error handler can reopen the stream many times at once — lib/plugin/pl_player/controller.dart:1019-1025
  For live, each matching error event (`tcp: ffurl_read returned …`, `Failed to open https://…`) schedules its own `Future.delayed(3s, refreshPlayer)`, with no throttle, unlike the VOD path. A burst of error lines queues several overlapping `ctr.open(...)` calls. Fix: reuse the `EasyThrottle`/debounce used on the VOD branch.

## U53 (agent-player)
- [P3] [A] Keyboard shortcuts on the local player: W throws, T sends a watch-later write — lib/pages/video/widgets/player_focus.dart:250-263; lib/pages/video/introduction/local/controller.dart:18
  `PlayerFocus` wraps file-source pages too. When logged in, W → `actionCoinVideo` reads `copyright`, which LocalIntroController defines as `throw UnimplementedError()`. T/V → `viewLater()` sends `toViewLater(bvid)` from the offline player: a real write for downloads, a failing request for local files (bvid ''). Fix: skip the account-action keys when `isFileSource`.

## U54 (agent-player)
- [P3] [A] Mute key (M) gets out of sync with the volume keys and mobile volume — lib/pages/video/widgets/player_focus.dart:195-204
  M sets mpv volume to 0 but leaves `volume.value` alone, and keeps a separate `isMuted`. On desktop, pressing ↑/↓ unmutes through `setVolume` while `isMuted` stays true, so the next M shows "取消静音" instead of muting. On mobile, unmuting sets mpv volume to `volume.value*100`, which is the system volume fraction, not `Pref.playerVolume`. Fix: route mute through `setVolume` and clear `isMuted` whenever the volume changes.

## U55 (agent-player)
- [P3] [A] Local playback progress is only saved when the page closes or the item changes — lib/pages/video/controller.dart:353-359, 1314-1320, 1333-1336
  `cacheLocalProgress` runs only from `onClose` and `onReset`. If the process is killed (Android swipe-away, crash), the resume point for that session is lost. Network videos are covered by 5 s heartbeats. Fix: also save progress periodically or on pause (e.g. from `positionListener`, throttled).

## U56 (agent-player)
- [P3] [A] Live packet header length check is too short — lib/tcp/live.dart:50-63, 250-252
  `fromBytesData` accepts anything of 10 bytes or more but reads up to offset 16 (`getUint32(12)`). A 10–15 byte frame throws a RangeError in `onData`, where header parsing is outside any try, so it goes to the zone error handler. Fix: check `data.length < 16`.

## U57 (agent-player)
- [P3] [A] Self-test raises the player count and never lowers it — lib/utils/self_test.dart:137, 213
  `PlPlayerController.getInstance()` is called only to read state. It increments `_playerCount` and sets `isLive=false`, so after a self-test run the instance is never fully disposed (wakelock, listeners, mpv stay alive). Fix: use `PlPlayerController.instance`.

## U58 (agent-player)
- [P3] [A] **hypothesis** Nested player pages remove the global volume listener — lib/plugin/pl_player/view/view.dart:275-278, 385-387
  `FlutterVolumeController.addListener` and `removeListener` are process-global. When a nested video page's player widget is disposed, the listener is removed while the page below still shows a player, so hardware volume changes stop updating `volume` and the indicator there. Not probed.

## U59 (agent-ui)
- [P1] [A] WebDAV "恢复设置" replaces all settings and the local follows/favorites in one tap, with no confirmation and no merge — lib/pages/webdav/view.dart:108-117 (lib/pages/webdav/webdav.dart:102-119, lib/utils/storage.dart:95-110)
  `onPressed: WebDav().restore` runs `setting.clear()`+`putAll`, `video.clear()` and `LocalLibrary.importAll`, which clears and replaces the local-library boxes. Without an account those boxes are the only copy of follows/favorites. Mis-tapping it next to "备份设置", or restoring an older backup, silently loses everything added since that backup. Fix: add a confirm dialog that names what gets replaced, and either merge the library boxes by key or snapshot the current state first.

## U60 (agent-ui)
- [P1] [A] Closing the blacklist page cuts the local blacklist filter down to the rows that were loaded — lib/pages/blacklist/view.dart:27-35
  On `dispose`, `GlobalData().blackMids` and `Pref.blackMids` are overwritten with `response.map(mid)` from the loaded pages only (the API returns 50 per page, lib/http/black.dart:10). With more than 50 blocked users, opening the page and backing out drops the rest from the local filter, so their content comes back in the feeds. Fix: only overwrite when `isEnd`; otherwise apply just the removals made on this page.

## U61 (agent-ui)
- [P1] [A] A refresh during a load-more is dropped but still resets paging, which duplicates items — lib/pages/common/common_list_controller.dart:22-24,59-63
  `onRefresh` sets `page=1` and `isEnd=false`, then `queryData` returns at once because `isLoading` is true. The load-more still in flight then appends page N and does `page++` (giving 2), so the next load-more fetches page 2 again. The result is duplicate rows, and the refresh appears to do nothing. The same early return drops a second refresh (a quick filter or UP switch), so results can belong to the previous selection. This base class is shared by most list pages. Fix: use a request-generation counter to drop stale responses, and reset `page`/`isEnd` only when the request actually starts.

## U62 (agent-ui)
- [P2] [A] WebDAV backup deletes the remote file before writing the new one — lib/pages/webdav/webdav.dart:90-99
  `client.remove(path)` runs first, then `client.write`. If the write fails (timeout, quota, dropped connection), the only remote backup is gone and the user sees only "备份失败". Fix: write to a temp name and rename it over the old file, or let `write` overwrite.

## U63 (agent-ui)
- [P2] [A] A malformed import wipes all settings — lib/utils/storage.dart:95-110
  `LocalLibrary.checkImport` validates only the library boxes. `setting.clear().then(putAll(map['setting']))` throws on `putAll(null)` after the clear has already run, so the chained `loginMode` restore is skipped too. The `video` box behaves the same way. Scenario: pasting a partial or unrelated JSON into About › import, or restoring a truncated WebDAV file. Fix: check `map[setting.name] is Map` and `map[video.name] is Map` before clearing anything.

## U64 (agent-ui)
- [P2] [A] Card ⋮ menu offers "进入/退出无痕模式", which now flips the persistent login mode in one tap with no confirmation — lib/common/widgets/video_popup_menu.dart:308-314
  In upstream this was a session-only toggle. The fork's `MineController.onChangeAnonymity` (lib/pages/mine/controller.dart:157-172) writes `SettingBoxKey.loginMode`, calls `Accounts.refresh()` and `onLoginMain()`. Any user with a saved account can therefore leave incognito from any video card's menu, where it sits next to 拉黑/不感兴趣. Fix: remove the item from the card menu, or confirm before leaving incognito.

## U65 (agent-ui)
- [P2] [A] "拉黑" is shown in incognito, and it also doubles as the local-folder "remove" — lib/common/widgets/video_popup_menu.dart:264-306
  Unlike 稍后再看 at :58, it is not gated on `Accounts.main.isLogin`. In incognito (the default) it sends `relationMod act=5` anonymously with an empty csrf, and the user gets a server-error toast. Fix: wrap it in `if (Accounts.main.isLogin)`.

## U66 (agent-ui)
- [P2] [A] 稍后再看 in the long-press cover dialog is not gated on login — lib/common/widgets/image/image_save.dart:64-73
  It is shown whenever an aid or bvid exists, on roughly 30 card types. In incognito it sends `UserHttp.toViewLater` anonymously with an empty csrf and toasts the error. This is inconsistent with VideoPopupMenu:58. Fix: add `Accounts.main.isLogin &&` to the condition.

## U67 (agent-ui)
- [P2] [A] 不感兴趣 checks the recommend account, but the web branch acts through the main account — lib/common/widgets/video_popup_menu.dart:103-109,205-260
  The guard checks `Accounts.get(.recommend).accessKey`. For items that are not `RcmdVideoItemAppModel` (search, hot, rank…), the action is `VideoHttp.dislikeVideo`, which is bound to the main account. If the two roles are different accounts, the user gets a misleading "请退出账号后重新登录" or "账号未登录". Fix: in the web branch, check `Accounts.main`, or hide the item.

## U68 (agent-ui)
- [P2] [A] Removing a video from a local favorite folder is only possible through Bilibili 不感兴趣 / 拉黑 — lib/pages/local/favs.dart:244-250
  `onRemove: LocalLibrary.removeFromFolder(...)` is passed to `VideoCardH`. VideoPopupMenu only calls `onRemove` after a successful dislike or blacklist (video_popup_menu.dart:139,228,295). In incognito, removing an item is impossible. In login mode, removing one blacklists the UP on the account (or records 不感兴趣). Fix: add a dedicated "移出收藏夹" entry, and hide the account-only actions on this page.

## U69 (agent-ui)
- [P2] [A] "重置cookie" in the WebView menu leaves the account cookies in the shared WebView store for the rest of the session — lib/pages/webview/view.dart:386-399
  `LoginUtils.setWebCookie()` installs the `Accounts.main` cookies. Unlike the account-cookie path at :228-249, `_accountCookie` is not set, so `dispose` never restores the anonymous jar. Every later in-app page (articles, links, live) then loads signed in until the next launch or the next `onLoginMain`. This is a new path, not covered by the pass-2 U7/U23 fix. Fix: set `_accountCookie = true` on this path as well.

## U70 (agent-ui)
- [P2] [A] Quick favorite failure toasts "Instance of 'Success<…>'", and an empty folder list leaves the loading dialog stuck — lib/pages/common/common_intro_controller.dart:275-292
  In the failure branch, `res.toast()` is called on the folder-query `Success`. `Success` does not override `toString` (lib/http/loading_state.dart:34-51), so the toast shows the class name instead of the error. The bug is upstream: in 94e413ac0 it is the `res.toast()` at line 247. Separately, `favFolderId` → `list.first` inside `.then` throws when the folder list is empty, and the loading dialog is never dismissed. Fix: use `result.toast()` and guard the empty list.

## U71 (agent-ui)
- [P2] [A] Login SMS risk-verification "发送验证码" crashes after a failed pre-captcha — lib/pages/login/controller.dart:313-320
  The failure branch shows a toast but has no `return`, so `preCaptureRes['data']['gee_gt']` is read on null and throws. Fix: add `return;` after the toast.

## U72 (agent-ui)
- [P2] [A] Article "liked" state comes from the total like count — lib/pages/article/controller.dart:148-151
  `status: response.stats?.like == 1` shows the article as liked whenever exactly one person has liked it. The next tap then sends the opposite action and adjusts the count the wrong way (:203-214). Fix: use the user's own like flag from the response.

## U73 (agent-ui)
- [P2] [A] Follow group tabs keep a stale `_tag`, so a later delete can dispose a controller that another tab is using — lib/pages/follow/child/child_view.dart:62-73
  When a controller for `newTag` already exists, `_followController` is switched but `_tag` is not updated. A later `Get.delete(tag: _tag)` or dispose then targets the old tag's controller (and its ScrollController), which another tab may still be using. Fix: set `_tag = newTag` in both branches.

## U74 (agent-ui)
- [P2] [A] Rows are removed by a list index captured before the network call — lib/pages/blacklist/controller.dart:34-48; lib/pages/dynamics_tab/controller.dart:55-65; lib/pages/fav_detail/controller.dart:35-49; lib/pages/later/controller.dart:49-83
  `removeAt(index)` runs after the await. A refresh or another delete landing in between removes the wrong row or throws a RangeError. Blacklist was re-read by me; the other three were re-read by the sub-auditor. The same pattern is **hypothesis** (sweep only, not re-read) in fan, fav/{topic,article,cheese,pgc}, history_search, live_dm_block and danmaku_block. Fix: remove by identity or id.

## U75 (agent-ui)
- [P2] [A] Dynamic detail comments stay on the skeleton forever when the detail request fails — lib/pages/dynamics_detail/controller.dart:34-41
  On failure it only toasts, so `oid`/`replyType` are never set and nothing can retry. On success, `basic!.commentIdStr!` is force-unwrapped. Fix: set an Error loading state, null-check the fields, and let reload retry the detail request.

## U76 (agent-ui)
- [P2] [C] "移除粉丝" can never appear in login mode — lib/pages/member/controller.dart:91 (lib/pages/member/view.dart:363)
  `isFollowed` is read from the space response, which is fetched anonymously (`Api.space` is not in `_accountApis`). The pass-2 `_queryRelation` fix restores only the account's own relation to this UP, not whether this UP follows the account. Fix: fetch the reverse relation with an account-bound call.

## U77 (agent-ui)
- [P2] [A] A stale SponsorBlock response can apply the previous video's segments — lib/pages/sponsor_block/block_mixin.dart:61-77,118-200
  `querySponsorBlock` resets and then awaits with no bvid/cid token, and its caller (video/controller.dart:910-912) does not await it. On a quick episode switch or auto-next, the old response lands after the new reset, causing wrong auto-skips and a wrong progress-bar overlay. Fix: compare the current cid before applying the response.

## U78 (agent-ui)
- [P2] [A] Folder sort can be opened while the folder is shown in a non-mtime order or reversed — lib/pages/fav_detail/controller.dart:216-226
  The sort requests use neighbours from the displayed order, so the real folder order gets scrambled. Fix: only allow sorting when `order == mtime && !pageDesc`.

## U79 (agent-ui)
- [P2] [A] **hypothesis** (sub-auditor sweep, not re-read by me): "search all folders" applies the default folder's `mediaId` to results from other folders (fav/view.dart:235-249). Audio playlist loadNext/loadPrev can load a page twice (audio/controller.dart:246-266,754-776). Editing a danmaku block rule deletes before adding, so a failed add loses the rule (danmaku_block/view.dart:199-211).

## U80 (agent-ui)
- [P2] [A] **hypothesis** "从剪贴板导入" checks `context.mounted` on the dialog it has just closed — lib/common/widgets/dialog/export_import.dart:246-256
  `Get.back()` runs before `importFromClipBoard(context)`, and `context` here is the dialog builder's context. If the clipboard read outlasts the close animation, the import silently does nothing. Whether this happens depends on timing. Fix: capture the outer context before popping.

## U81 (agent-ui)
- [P2] [A] CI release APKs are signed with a throwaway debug key when the signing secret is missing — .github/workflows/build.yml:85-94; android/app/build.gradle.kts:46-66
  If `SIGN_KEYSTORE_BASE64` is unset, the key step silently does nothing and `signingConfig = config ?: signingConfigs["debug"]` uses the runner's debug key. The release is still published. Each release is signed differently, so updating fails and users must uninstall, which deletes local follows, favorites and history. Fix: fail the job for a tagged release when the secret is empty.

## U82 (agent-ui)
- [P3] [A] Download multi-select keeps its count after a list reload but loses the ticks — lib/pages/download/controller.dart:37-72
  A finished download triggers `_loadList`, which rebuilds the items with `checked=false` but leaves `rxCount` and `enableMultiSelect` unchanged. The user sees N selected with nothing ticked, and 删除 confirms but deletes nothing. Fix: carry `checked` over by pageId, or reset the selection state.

## U83 (agent-ui)
- [P3] [A] Hiding `ActionPanel` in incognito also removes the read-only comment entry and the counts — lib/pages/dynamics/widgets/dynamic_panel.dart:111-112
  Fix: hide only the repost and like buttons.

## U84 (agent-ui)
- [P3] [A] Local quick-unfavorite toasts "已取消本地收藏" while the item is still in other local folders — lib/pages/common/common_intro_controller.dart:227-240

## U85 (agent-ui)
- [P3] [A] The download settings can't be found in settings search — lib/pages/settings_search/view.dart:31-38
  `_settings` spreads extra/privacy/recommend/video/play/style but not the fork's `downloadSettings`. Fix: add `...downloadSettings`.

## U86 (agent-ui)
- [P3] [A] my_reply switches on `oid` where it should switch on reply type — lib/pages/my_reply/view.dart:131-142
  `switch (oid) { 1 => av2bv(oid) … }` only matches when oid == 1, so video comments pass the raw aid to the anti-fraud helper. This is upstream code. Fix: `switch (replyInfo.type.toInt())`.

## U87 (agent-ui)
- [P3] [D] The "了解账号模式" dialog lists `ApiType.apiTypeSet` as account-bound, but `LoginPolicy.bind` sends most of those anonymously — lib/pages/setting/models/privacy_settings.dart:22-65

## U88 (agent-ui)
- [P3] [A] Destructive actions run without confirmation: 删除已看记录 (lib/pages/history/controller.dart:99-108) and a local unfollow on a single tap in incognito (lib/pages/member/controller.dart:244-258).

## U89 (agent-ui)
- [P3] [A] Watch later: `toViewDel` failures show no toast, and `updateCount` only lowers the current tab's count — lib/pages/later/controller.dart:39-43,71-76

## U90 (agent-ui)
- [P3] [A] **hypothesis** `pubdate!` force-unwrap on search result cards — lib/common/widgets/video_card/video_card_h.dart:143
  `SearchVideoItemModel` may leave `pubdate` null, and the callee already accepts null. Fix: drop the `!`.

## U91 (agent-ui)
- [P3] [A] The cover dialog's `_ImageDecoration` leaves `imageHeight` out of `==` and `hashCode`, so its hit-test uses a stale height after a desktop window resize — lib/common/widgets/image/image_save.dart:137-155

## U92 (agent-ui)
- [P3] [A] On Windows, `--selftest` exits 0 without running when LibrePili is already running — windows/runner/main.cpp:81-83
  `SendAppLinkToInstance()` returns true even with no link to send. Fix: skip both `Send*ToInstance` calls when `--selftest` is on the command line.

## U93 (agent-ui)
- [P3] [A] On Linux, relative file paths forwarded to the running instance are resolved against that instance's working directory — linux/runner/my_application.cc:103-133
  They then fall through to the "未知路径" toast. Fix: `g_canonicalize_filename` the arguments before forwarding.

## U94 (agent-ui)
- [P3] [D] Debug build is still labelled "PiliPlus debug" — android/app/src/debug/res/values/string.xml:2
  Fix: `LibrePili debug`.

## U95 (agent-ui)
- [P3] [A] Privacy and supply-chain hygiene — android/app/src/main/AndroidManifest.xml:252,270-272; .github/workflows/*.yml
  - `READ_MEDIA_*` and `WRITE_SETTINGS` are declared but never requested from Dart. **hypothesis:** a plugin may need them.
  - Every job gets `permissions: write-all`.
  - Third-party actions are pinned by tag, not by SHA.
  - `appimagetool` comes from the moving `continuous` tag with no checksum check.

## U96 (agent-ui)
- [P3] [A] **hypothesis** (sweep only, not re-read):
  - The like button crashes when `like.status` is null (dynamics/widgets/action_panel.dart:127).
  - dynamics_topic "load folded" can remove a real item on a double tap (controller.dart:137-147).
  - `onUnfold` un-hides by position rather than id (dynamics_tab/controller.dart:81-92).
  - fav_create calls `setState` in `.then` without a mounted check (view.dart:51-65).
  - Unchecking every home tab crashes the next launch (home/controller.dart:30,67-80).
  - The scheduled-post "6 minutes ahead" check only compares within the same hour (dynamics_create/view.dart:524-536).
  - `cookie_info` is read without a null check (login/controller.dart:99-103,490-494).
  - 清除失效内容 runs without confirmation (fav_detail/view.dart:292-295).

