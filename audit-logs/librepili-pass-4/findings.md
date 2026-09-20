## U1 (codex)
- [P1] Linux purge deletes every user’s app data — assets/linux/DEBIAN/postrm:20-23  
  On `dpkg --purge`, this root maintainer script recursively removes `/home/*/.local/share/com.zxa24.librepili` and root’s app data. That can erase settings, local follows/favorites, logs, and other user-owned state for every account on the machine without per-user consent. Debian packages should generally remove package-owned files only; leave user data in place or provide an explicit in-app/user-scoped cleanup path.

## U2 (codex)
- [P3] Uninstall kills all matching app processes system-wide — assets/linux/DEBIAN/prerm:3-6  
  `pkill -x librepili` during package removal terminates every process with that executable name, including sessions owned by other users. That can interrupt playback, downloads, or pending writes. Prefer not killing user processes from the maintainer script, or scope shutdown to a known package-managed service/session.

## U3 (codex)
- [P3] Shortcut creation assumes decoded avatar bitmap is non-null — android/app/src/main/java/com/example/piliplus/AndroidHelper.java:311-321  
  The Android shortcut path decodes a cached remote avatar file and immediately passes it to `Icon.createWithAdaptiveBitmap`. If the cache contains a corrupt, unsupported, or non-image response, `BitmapFactory.decodeFile` can return null and the native call can throw. Add a null check and fall back to the app icon or return a controlled error before building the shortcut.

## U4 (claude-xhigh)
- [P1] [A] In-app WebView has no URL-scheme allowlist: `bilibili://browser/?url=file:///…` renders arbitrary local files — lib/utils/app_scheme.dart:379-387,924-937; lib/pages/webview/view.dart:221,486-500; lib/utils/extension/string_ext.dart:1-4
  `case 'browser'` takes `uri.queryParameters['url']` verbatim into route params; `_url = (...).http2https` only rewrites `http://` and `//`, so `file:`, `content:`, `javascript:` survive and go straight into `URLRequest(url: WebUri...)`. `MainActivity` is `exported` + `BROWSABLE` for the `bilibili` scheme, so any web page or installed app can make the app open `file:///data/data/com.example.piliplus/hive/account.hive` in its own WebView (`javaScriptEnabled: true`). `PageUtils.launchURL` (page_utils.dart:433-445) likewise hands any scheme to `launchUrl(..., externalApplication)`. Fix: accept only `http`/`https` in `_toWebview`/`launchURL`. **hypothesis:** the exact Android `allowFileAccess` default of flutter_inappwebview 6.1.5 (not set here, so platform default applies).

## U5 (claude-xhigh)
- [P1] [A] “重置所有数据（含登录信息）” leaves the WebDAV password and SponsorBlock userID on disk in plaintext — lib/utils/storage.dart:119-143,266-278; lib/pages/about/view.dart:332-338
  Every import/WebDAV-restore writes `appSupportDir/snapshots/before_import_<ts>.json` via `exportAllSettings(includeCredentials: true)`, keeping the newest 5. `GStorage.clear()` clears only the Hive boxes and `Accounts.clear()`; nothing ever deletes the snapshot directory. A user who restores a backup once and later taps “reset all data” to wipe the account still has `webdavPassword` / `webdavUsername` / `blockUserID` readable on disk (and reachable through the optional Documents provider on Android). Fix: delete `_snapshotDir` in `clear()`.

## U6 (claude-xhigh)
- [P2] [C] One failed WBI-key fetch marks the day as done, then serves yesterday’s key for the rest of the day — lib/utils/wbi_sign.dart:103-119,79-101
  The “new day” branch writes `LocalCacheKey.timeStamp = now` *before* fetching. If `_getWbiKeys()` fails (offline at launch, transient error) it returns the **cached previous-day key**. Every later call that day takes the same-day branch, finds a non-null `mixinKey`, and returns that stale key without ever refetching — so search, space lists and every other WBI-signed endpoint fail until the calendar day rolls over. The pass-3 fix (`_future = null`, full-date compare) does not cover this. Fix: store `timeStamp` next to `put(mixinKey)` on success only.

## U7 (claude-xhigh)
- [P2] [B] `entry.json` fields that are optional in the constructor are required in `fromJson`, and the parse failure is swallowed — lib/models_new/download/bili_download_entry_info.dart:147-215,281-309,365-401; lib/services/download/download_service.dart:115-135
  `EpInfo.link/bvid/sortIndex`, `PageInfo.width/height/rotate`, `BiliDownloadEntryInfo.mediaType/hasDashAudio/qualityPithyDescription/timeUpdateStamp/timeCreateStamp/canPlayInAdvance/interruptTransformTempFile` all declare defaults but are read as `json[k] as int|bool|String` (non-nullable). Any entry.json written by an older build or by the official Bilibili app that omits one field throws, and `_readDownloadDirectory`’s `catch (_) {}` (line 129) drops it: the download vanishes from the list with no message while its files stay on disk. Fix: `as T? ?? default` for every field that has a constructor default, and log/surface skipped entries.

## U8 (claude-xhigh)
- [P2] [A] A trailing `|` in any keyword filter silently empties the feed / comments / dynamics — lib/pages/setting/models/model.dart:209-265; lib/utils/recommend_filter.dart:10-14,34-36; lib/grpc/reply.dart:12-16,39-42; lib/models/dynamics/result.dart:46,71
  The dialog literally instructs “使用|隔开，如：尝试|测试”, and the input is compiled with `RegExp(banWord)`. `测试|` is a valid pattern with an empty alternative, so `hasMatch()` is true for every string: `filterTitle`, `ReplyGrpc.needRemoveGrpc` and the dynamics filter then drop **everything**, with no error and no hint that the pattern is the cause. Fix: reject/normalise patterns that match the empty string (or escape plain keywords and join with `|` yourself).

## U9 (claude-xhigh)
- [P2] [A] Saving an invalid keyword pattern throws after the dialog has already reported success — lib/pages/setting/models/model.dart:249-259
  The save button runs `Get.back(); banWord = editValue; setState(); onChanged(RegExp(banWord, …)); showToast('已保存'); put(key, banWord);` — in that order. A pattern like `(` or `[` makes `RegExp` throw at line 255: the row already shows the new text, the toast never appears, the filter keeps the old value, and nothing is persisted, so the UI and the actual state disagree until restart. Fix: build the `RegExp` in a try/catch before mutating any state, and toast the error.

## U10 (claude-xhigh)
- [P2] [A] `patch.ps1` patches whichever `material_ui-*` cache dir sorts last, which need not be the one the build uses — lib/scripts/patch.ps1:213-253,290-298
  `Get-ChildItem … | Where-Object { $_.Name -like "material_ui-*" } | Select-Object -Last 1` sorts lexicographically, so `material_ui-1.0.9` wins over `material_ui-1.0.10`. The delete-then-`pub get`-then-`git apply` dance would then land all nine material patches on a version nothing links against; `git apply` succeeds on the pristine copy, so the job stays green and ships an **unpatched** UI. Fix: resolve the directory from `pubspec.lock`/`.dart_tool/package_config.json` instead of a name glob. **hypothesis:** that two `material_ui` versions actually coexist in the flutter-action pub cache.

## U11 (claude-xhigh)
- [P2] [A] Deep-link parsing throws on malformed input in several places, so crafted links silently do nothing — lib/utils/app_scheme.dart:286-318,215-236,602-608,727-754,829-846,736
  `int.parse(pathSegments[1..3])` for `bilibili://comment/detail/a/b/c`, `int.parse(cid)` for `bilibili://video/1?cid=abc`, `int.parse(sid)`, `int.parse(rootIdStr)`, `int.parse(oid|root|pageType)` for `…/h5/comment/sub?…`, and `IdUtils.bv2av(res.bv!)` (whose `invData[char]!` is null for `0`/`I`/`O`/`l`, which `bvRegex` accepts) are all unguarded. `routePush` is `async`, so `routePushFromUrl`’s `try/catch` (line 139) cannot catch them — the error escapes as an unhandled future. Fix: `int.tryParse` everywhere and make `bv2av` return null on an out-of-alphabet character.

## U12 (claude-xhigh)
- [P2] [A] Live room: if the **first** danmaku-token fetch fails, no retry is ever scheduled — lib/pages/live_room/controller.dart:516-531,503-514,443-452
  `_connectDm()` only calls `_scheduleDmReconnect()` in the `else if (_dmRetryCount > 0)` branch, i.e. when already reconnecting. Entering a room while offline (or a transient error on `liveRoomGetDanmakuToken`) leaves `_msgStream == null` and `_dmRetryTimer == null`, and `startLiveMsg()` is not re-driven, so live chat stays dead for the whole visit with no indication. Fix: schedule the backoff on the first failure too.

## U13 (claude-xhigh)
- [P2] [A] Clearing the cache on mobile deletes everything the app is currently writing under the temp dir — lib/utils/cache_manager.dart:70-91; lib/utils/path_utils.dart:28-41
  On mobile `appTempDirectory()` *is* `getTemporaryDirectory()`, so `tmpDirPath` and the cache root are the same folder. `clearLibraryCache` then `delete(recursive: true)`s every child except the image-cache dir and `local_documents` — including any in-flight temp file (share/export/remux scratch) another task is holding. The pass-3 `local_documents` carve-out fixed one instance of this, not the class. Fix: put app scratch under a named subfolder and skip it, or clear only known cache folders.

## U14 (claude-xhigh)
- [P3] [A] A time-like danmaku with an over-long number throws inside `build` — lib/plugin/pl_player/view/view.dart:2249-2260,2278; lib/utils/duration_utils.dart:21-31
  `_timeRegExp` allows unbounded `\d+` for the hour/minute groups, and `parseDuration` maps each part through `int.parse`, which throws `FormatException` above 2^63. `_getValidOffset` is called from `_buildDmAction` with no try/catch, so tapping a danmaku containing e.g. `99999999999999999999:59` raises during overlay build. `videoDetailController.data.timeLength!` on the next line is likewise force-unwrapped. Fix: bound the digit groups (`\d{1,4}`) and use `tryParse`.

## U15 (claude-xhigh)
- [P3] [A] FLV→MP4 join emits one chunk per sample, so merging does ~10⁵ tiny seek/read/write round-trips — lib/utils/flv_demux.dart:271-291; lib/utils/mp4_remux.dart:187-212,608
  `build()` adds `_Chunk(... )..sampleCount = 1` per sample, unlike the fragmented-MP4 path which groups samples into `_maxChunkSeconds` (1 s) chunks. A 30-min download becomes ~130 000 chunks: 130 000 `setPosition` + `readInto` + `writeFrom` pairs, 130 000 `onProgress` callbacks, and ~1 MB of `stco`/`stsz` in the moov. Fix: accumulate consecutive samples of the same file/descIndex into ~1 s chunks as the mp4 path does.

## U16 (claude-xhigh)
- [P3] [A] The SponsorBlock private user id is generated with `dart:math`’s non-secure `Random()` — lib/utils/storage_pref.dart:323-332; lib/utils/utils.dart:9
  `blockUserID` is 16 bytes from `Utils.random = Random()` hex-encoded; it is the credential that authenticates submissions and votes to the block server (and is what pass-3 U18/U41 kept out of exports). `Random.secure()` exists and costs nothing here. Fix: use `Random.secure()`. **hypothesis:** how predictable the VM’s default `Random()` seed actually is on the target platforms.

## U17 (claude-xhigh)
- [P3] [D] iOS registers `http`/`https` as app URL schemes and carries a nested, ignored `CFBundleURLTypes` that lists hosts as schemes — ios/Runner/Info.plist:85-127
  The first `CFBundleURLTypes` entry declares `CFBundleURLSchemes = [http, https]` (reserved by the system, and an App Store review trigger), and inside that same dict a second `CFBundleURLTypes` key holds `m.bilibili.com`, `bilibili.com`, … as “schemes”. `CFBundleURLTypes` is not a valid key at that nesting level, so the whole block is dead config inherited from upstream. Fix: delete the nested block and the `http`/`https` scheme registration; use Universal Links if those hosts are wanted.

## U18 (claude-xhigh)
- [P3] [A] macOS registers no URL scheme and no document types, so `bilibili://` links and “Open with LibrePili” never reach the app — macos/Runner/Info.plist:1-41; lib/utils/app_scheme.dart:43-66,87-97
  The plist has no `CFBundleURLTypes` and no `CFBundleDocumentTypes`, while Windows (`windows/runner/main.cpp:63-68`) and Linux (`assets/linux/com.zxa24.librepili.desktop:11`) both wire up the scheme and the video MIME types. `PiliScheme.init()`’s listener therefore never fires on macOS, and the fork’s local-player “open with” entry point is missing on that platform.

## U19 (claude-xhigh)
- [P3] [C] Retried GET failures are swallowed: `handler.reject` skips the rest of the error chain — lib/http/retry_interceptor.dart:84-95; lib/utils/accounts/account_manager/account_mgr.dart:143-167
  On the final retry failure the interceptor calls `handler.reject(error)`, which completes the request immediately; `AccountManager.onError` (registered after it) then never runs, so neither `toast(err)` nor `_saveCookies` happens. The same network failure on a request that was *not* retried does toast. Fix: `handler.next(error)`.

## U20 (claude-xhigh)
- [P3] [B] The reply ban-word list is saved case-sensitive but reloaded case-insensitive — lib/common/widgets/context_menu/reply_menu_helper.dart:56-62; lib/grpc/reply.dart:12-16
  “加入过滤” builds `RegExp(filter, caseSensitive: true)` and persists the pattern; at the next launch `ReplyGrpc.replyRegExp` is rebuilt with `caseSensitive: false`. The same stored rule therefore filters a different set of comments before and after a restart. (The settings dialog, model.dart:255, also uses `caseSensitive: false`.) Fix: pick one and use it in all three places.

## U21 (claude-xhigh)
- [P3] [A] A live frame with `totalSize == 0` can recurse until the stack dies — lib/tcp/live.dart:229-252
  `_processingData` recurses on `if (subHeader.totalSize < data.length) _processingData(sublistView(data, subHeader.totalSize))`; with `totalSize == 0` the slice is the same buffer. The body-decoding branch that would normally throw first is skipped when `_eventListeners` is empty, so the recursion is unbounded. The outer `catch (_)` swallows the resulting `StackOverflowError`, turning it into an unexplained stall. Fix: require `subHeader.totalSize >= 16` before recursing.

## U22 (claude-xhigh)
- [P3] [B] Dead `fromJson` family in the download media model, and the one live path has no test — lib/models_new/download/bili_download_media_file_info.dart:64-90,202-212,253-266; lib/utils/mp4_remux.dart:112-117; test/utils/
  `Type1.fromJson`, `Type2.fromJson`, `Type2File.fromJson` and `Type1PlayerCodecConfig.fromJson` have no call sites (index.json is read with raw `jsonDecode` in download_service.dart:778-785); only `Type1Segment.fromJson` is live. Meanwhile `debugMp4JoinTracks` is documented “for tests only” but `test/utils/` has `flv_demux_test.dart` and no mp4-join test, although `joinMp4` is on the real export path (download_service.dart:957-962). Fix: delete the dead factories, add a join test.

## U23 (claude-xhigh)
- [P3] [A] `lib/scripts/patch.ps1` rewrites the machine’s **global** git identity — lib/scripts/patch.ps1:5-6
  `git config --global user.name "ci"` / `user.email "example@example.com"` runs unconditionally, including when a contributor runs `patch.ps1` locally to build the app (the README-level entry point for desktop builds). Fix: scope it with `-C $env:FLUTTER_ROOT --local`, or only set it when `$env:GITHUB_ACTIONS` is set.

## U24 (claude-xhigh)
- [P3] [A] “Open with” on Windows blocks forever if the running instance is busy — windows/runner/main.cpp:63-68
  `SendMessage(s.found, WM_COPYDATA, …)` has no timeout; the new process stays alive and invisible until the existing instance pumps its message queue. Fix: `SendMessageTimeout` with `SMTO_ABORTIFHUNG` and a short timeout, falling back to starting normally.

## U25 (claude-xhigh)
- [P3] [D] `linux_x64.yml` declares a `tag` input it never reads, has no `permissions` block, and contains two no-op `sed` calls — .github/workflows/linux_x64.yml:4-10,219-220,210-211
  The release step gates on `github.event.inputs.tag` rather than the declared `inputs.tag`, so the `with: tag:` passed by build.yml is ignored (it happens to resolve to the same value only because the caller is dispatch-triggered). Dispatching this workflow directly gives it the repository-default `GITHUB_TOKEN` permissions instead of `contents: write`. `sed -i 's|Exec=librepili|Exec=librepili|g'` and the matching `Icon=` line substitute a string with itself.

## U26 (claude-xhigh)
- [P3] [D] `build.yml` still gates jobs on the upstream repository and on a disabled trigger — .github/workflows/build.yml:3-12,52,112-116,155,171
  The `pull_request` trigger is commented out, yet several `if:` conditions and two whole steps (“Flutter Build Dev Apk”) are keyed on `github.event_name == 'pull_request' && github.repository == 'bggRGjQaUbCoE/PiliPlus'` — dead in this fork. The keystore secrets are also interpolated directly into the `run:` shell (lines 89-94) rather than passed via `env:`, which breaks on a password containing a quote.

## U27 (claude-xhigh)
- [P3] [D] Third-party git dependencies are pinned to moving branches — pubspec.yaml:38-230
  ~20 packages come from `bggRGjQaUbCoE/*`, `My-Responsitories/*`, `Predidit/*` and `wgh136/*` at `ref: main|dev|develop|master|upstream|mod|const`. `pubspec.lock` does carry `resolved-ref` commit pins (e.g. lines 104-105), so a normal `pub get` is reproducible — but any `pub upgrade` silently adopts whatever those branches point at, with no signature or checksum gate, for a build that ships with the user’s session cookies. Fix: pin the `ref:` to the commit SHAs already recorded in the lock.

## U28 (claude-xhigh)
- [P3] [D] The package still identifies as upstream — pubspec.yaml:1-2; assets/linux/DEBIAN/control:11
  `name: PiliPlus`, `description: A new Flutter project.`, and the Debian `Homepage:` points at `github.com/zxa24/PiliPlus` while the app id is `com.zxa24.librepili`. Cosmetic, but it is what shows up in crash reports, `dpkg -s` output and the `PiliPlus/...` import prefix throughout `lib/`.

## U29 (claude-xhigh)
- [P3] [A] Subtitle export can emit out-of-range timecodes — lib/utils/subtitle_utils.dart:15-22,36-44
  `_vttTimecode` formats the seconds remainder with `toStringAsFixed(3)`, so `59.9996` becomes `60.000` → `00:00:60.000`; `_srtTimecode` rounds the millisecond part separately and can produce `,1000`. Both are rejected or mis-parsed by strict players. Fix: round to milliseconds first, then decompose.

## U30 (claude-xhigh)
- [P3] [A] Any future timestamp renders as “刚刚” — lib/utils/date_utils.dart:19-38
  `diff.inMinutes < 1` is true for every negative difference, so a server clock skew or a scheduled/pinned item dated in the future is shown as “just now” regardless of how far ahead it is. Fix: handle `diff.isNegative` explicitly.

---

## U31 (agent-accounts)
- [P1] [A] 登录信息导出无任何确认，凭据可落入剪贴板 — lib/pages/about/view.dart:239-260
  `onExport: () => Utils.jsonEncoder.convert(Accounts.account.toMap())` serialises every stored `LoginAccount` (`toJson` = 全部 cookie 含 SESSDATA/bili_jct + `accessKey` + `refresh`，account.dart:100-107) and `showImportExportDialog` offers 「导出至剪贴板」 with **no** `beforeExport` hook — unlike 「导入/导出设置」 right below (line 261-300), which gates mere WebDAV 凭据 behind a confirm dialog. Failure: user taps 导出至剪贴板 to move accounts between devices; on Android the clipboard is readable by other apps and surfaced in the system clipboard preview, so a full session token leaks silently. Fix: pass a `beforeExport`/confirm dialog for 登录信息 too (and prefer file export), mirroring the settings path.

## U32 (agent-accounts)
- [P1] [A] 「重置所有数据（含登录信息）」后 UI 仍处于已登录/登录模式 — lib/pages/about/view.dart:332-338, lib/utils/storage.dart:266-278, lib/utils/accounts.dart:56-65
  `GStorage.clear()` → `Accounts.clear()` wipes the box and `accountMode`, but never calls `LoginUtils.onLogoutMain()`, never resets `AccountService.isLogin`/`face`, never resets `MineController.anonymity`. Failure: after the reset, `Pref.loginMode` is back to `false` (setting box cleared) yet the mine page still shows avatar/昵称/收藏/观看记录/稍后再看 and the header icon still says 「已开启登录模式」; every tap issues an anonymous request that fails until restart. Fix: have `Accounts.clear()` (or its caller) run `LoginUtils.onLogoutMain()` and set `MineController.anonymity.value = true`.

## U33 (agent-accounts)
- [P1] [A] Cookie 登录不触发登录模式 opt-in，登录后仍全程匿名 — lib/pages/login/controller.dart:161-208 (vs setAccount 642-665)
  `setAccount` (QR/密码/短信) does `GStorage.setting.put(SettingBoxKey.loginMode, true)` + `Accounts.refresh()` + `MineController.anonymity.value = false` + `onLoginMain()`; `loginByCookie` does none of it — it only persists the account and opens `switchAccountDialog`. Since incognito is the default, `Accounts.set` then parks the role dormant (accounts.dart:120-126) and `AccountService.isLogin` stays false. Failure: user pastes a cookie, sees 「登录成功」, and the app is still fully anonymous with all login UI hidden and no hint why. Fix: run the same opt-in sequence as `setAccount`.

## U34 (agent-accounts)
- [P1] [A] 直播「不感兴趣」在登录模式下被匿名化并静默失败 — lib/utils/accounts/login_policy.dart:22-77, lib/http/live.dart:765-798
  `Api.liveFeedback` is assigned the recommend role (api_type.dart:85) and the call site puts `recommend.accessKey` into the signed params, but the path is in **neither** `_accountApis` nor `_recommendApis` — while the video equivalents `Api.feedDislike`/`feedDislikeCancel` are. So `LoginPolicy.bind` anonymises it and `AccountManager._scrubAccessKey` (account_mgr.dart:285-305) strips `access_key` and re-signs. Failure: 直播卡片长按「不感兴趣」in login mode always returns a server error / does nothing. Fix: add `Api.liveFeedback` to `_recommendApis`.

## U35 (agent-accounts)
- [P1] [A] 音频模式播放收藏夹/稍后再看时列表取不到 — lib/utils/accounts/login_policy.dart:79-85, lib/grpc/url.dart:58, lib/pages/audio/controller.dart:253-266
  `_grpcAccountApis` lists `GrpcUrl.audioPlayUrl` but not `GrpcUrl.audioPlayList`, even though `SourceType.fav` / `SourceType.watchLater` (models/common/video/source_type.dart:14-23) drive it with `PlaylistSource.USER_FAVOURITE` / `MEDIA_LIST` — account-scoped lists. The REST twins `Api.favResourceList`/`Api.mediaList` *are* listed with the comment "folder contents (private folders) and watch-later / fav 'play all'", so this is the same concept swept only on the REST half. Failure: 收藏夹/稍后再看「听视频」returns an empty or error playlist in login mode. Fix: add `GrpcUrl.audioPlayList` to `_grpcAccountApis`.

## U36 (agent-accounts)
- [P2] [A] 重置/登录后匿名 buvid 的激活调用是空操作 — lib/utils/accounts/account.dart:164-168, lib/utils/accounts.dart:56-65, lib/http/init.dart:62-65
  `AnonymousAccount.delete()` regenerates `buvid3` but never sets `activated = false`; `Request.buvidActive` returns immediately when `activated` is true, and it was set true at startup by `Accounts.refresh()`. So the explicit `Request.buvidActive(AnonymousAccount())` at accounts.dart:64 (and the implicit intent behind `AnonymousAccount().delete()` in login/controller.dart:652) never runs. Failure: after 重置所有数据 or a login, the fresh anonymous device id is unregistered → anonymous requests can start hitting risk-control (-352/-412) for the rest of the session. Fix: `activated = false` inside `AnonymousAccount.delete()`.

## U37 (agent-accounts)
- [P2] [A] 删光所有账号后仍停留在「登录模式」，且提示文案说反 — lib/utils/accounts.dart:66-78, lib/pages/setting/view.dart:222-226, lib/pages/mine/controller.dart:162-166
  `Accounts.deleteAll` clears roles and calls `onLogoutMain`, but never turns `SettingBoxKey.loginMode` off. `MineController.onChangeAnonymity` then early-returns on `Accounts.account.isEmpty` with 「当前为无痕模式（默认）」 — which is false, `Pref.loginMode` is still true, and the header icon still shows `incognitoOff`. Failure: the user cannot get back to the advertised default state and the UI asserts a privacy posture the app is not in. Fix: clear `loginMode` (and `anonymity`) when the account box becomes empty, or drop the `isEmpty` guard for the 进入无痕 direction.

## U38 (agent-accounts)
- [P2] [A] 跨源重定向仍带走 gRPC 的 access_key 与持久 buvid (**hypothesis**: reachability depends on B 站是否对 gRPC 端点发 3xx) — lib/http/retry_interceptor.dart:30-46, lib/utils/accounts/grpc_headers.dart:73-91
  On a cross-origin redirect the interceptor removes `cookie`/`authorization`/`x-bili-mid`/`x-bili-aurora-eid` and scrubs query+body, but leaves `x-bili-metadata-bin` — a base64 `Metadata` whose first field **is** `accessKey` — plus `buvid` and `x-bili-device-bin` (both the *persistent* `LoginUtils.buvid` for account-bound calls). `GrpcReq.options` (grpc/grpc_req.dart:17-20) does not disable dio's default `followRedirects`. Also `referer: https://www.bilibili.com` survives to the foreign origin. Fix: in the cross-origin branch drop every `x-bili-*` header plus `buvid` and `referer`, not an allow-list of four.

## U39 (agent-accounts)
- [P2] [A] 退出登录/进入无痕后 WebView cookie 仓库被清空且不重装匿名 jar — lib/utils/login_utils.dart:120-134, lib/pages/mine/controller.dart:171-172
  `onLogoutMain` calls `deleteAllCookies()` and stops there; `setAnonymousWebCookie()` (which installs the anonymous `buvid3`) only runs at startup (init.dart:43) and on `onLoginMain`. Failure: after 退出登录 or 进入无痕模式, every in-app WebView page for the rest of the session runs with an empty cookie jar → 直播/H5 页面更易触发风控或降级渲染. Fix: chain `setAnonymousWebCookie()` after the delete, as `setAnonymousWebCookie` itself does.

## U40 (agent-accounts)
- [P3] [A] wbi 密钥「今天已刷新」标记先于刷新成功写入 — lib/utils/wbi_sign.dart:103-119 (+79-101)
  The new-day branch writes `LocalCacheKey.timeStamp = now` *before* awaiting `_getWbiKeys()`. If that fetch fails, the catch returns the previous day's cached `mixinKey` and clears `_future`, but the timestamp already says "today", so every later call takes the same-day branch, finds a non-null (stale) key and never retries. Failure: one transient network error at the day boundary leaves all wbi-signed reads signed with yesterday's key until the next calendar day. Fix: write the timestamp only after `_getWbiKeys()` succeeds.

## U41 (agent-accounts)
- [P3] [A] 未登录时「动态/关注/粉丝」一行仍然显示且点击静默无效 — lib/pages/mine/view.dart:380-406 (+ controller.dart:238-243)
  `_buildActions` and `_buildFav` are correctly gated on `controller.isLogin`, but the three-stat row is not: logged out it renders `-/-/-` and `MineController.push` silently returns. That contradicts the "login-only UI is hidden when logged out" rule applied everywhere else on this page. Fix: wrap the row in the same `isLogin` guard.

## U42 (agent-accounts)
- [P3] [D] `exportAllSettings` 仍然导出 `loginMode`，与其自身契约不符 — lib/utils/storage.dart:98-109 vs 182-219
  `importAllJsonSettings` explicitly preserves the device's own `loginMode` ("login mode is a per-device opt-in: a backup must not switch it") and about/view.dart:319-327 re-puts it after a reset, but the export side only filters `credentialKeys`, so the backup file / clipboard blob still carries `"loginMode": true`. Fix: exclude `SettingBoxKey.loginMode` from `exportAllSettings` as well.

## U43 (agent-accounts)
- [P3] [D] 「了解账号模式」对话框把 `ApiType` 角色表当成实际策略展示 — lib/pages/setting/models/privacy_settings.dart:48-67
  The disclaimer paragraph is right, but the listed endpoints come from `ApiType.apiTypeSet`, which contains paths (`Api.liveFeedback`, `Api.searchByType`, `Api.videoIntro`, …) that `LoginPolicy` will anonymise regardless of role. Users reading the list will believe those calls carry the account. Fix: render the `LoginPolicy` sets (or mark each row 带账号/匿名) instead of the role map.

## U44 (agent-accounts)
- [P3] [C] `switchAccountDialog` 的确认按钮不 await `Accounts.set` — lib/pages/login/controller.dart:772-780
  Four `Accounts.set(...)` futures are fired and dropped inside the `onPressed`; a Hive write failure or the network round-trip inside `onLoginMain()` is unobserved, and the dialog closes before the main role's login state settles. Fix: `await Future.wait([...])` (the sync part already runs in order, so the ordering is safe) and surface errors.

## U45 (agent-media)
- [P1] [A] `mediaType` is never reset to 2, so a durl→dash entry merges and plays from the wrong files — lib/http/download.dart:41-149 (dash branch), lib/services/download/download_service.dart:769-819
  The durl branch sets `entry..mediaType = 1` (download.dart:172); the dash branch sets `typeTag`/`videoQuality`/`qualityPithyDescription` but never `mediaType = 2` (grep confirms `..mediaType = 1` is the *only* assignment in lib/). The stream is re-resolved on every `startDownload`, so an entry that once got durl (old video / anonymous / `fnval` differences) keeps `media_type: 1` in entry.json forever. Resume it after logging in and the bytes land in `video.m4s`/`audio.m4s` (download_service.dart:492-508) while `_mergeDownload` takes the `mediaType == 1` branch, looks for `0.mp4`, finds nothing, and `_exportType1` fails on a nonexistent input — and because that throw is a `FileSystemException`, `damaged` is false (line 843) so `_completeDownload` still sets `isCompleted = true` (line 677). Playback then builds `FileSource(isMp4: true)` → `<typeTag>/0.mp4` (data_source.dart:44), which does not exist. Fix: assign `entry.mediaType = 2` (and `hasDashAudio = audio != null && audio.isNotEmpty`) in the dash branch.

## U46 (agent-media)
- [P1] [A] A failed merge still marks a DASH download "complete", with no way to retry — lib/services/download/download_service.dart:665-700, 835-853
  `damaged` is computed as `entry.mediaType == 1 && e is FormatException`, so for DASH a `FormatException` out of `Mp4Remuxer.remux` (bad box / no moov / no samples / unexpected EOF — i.e. damaged `.m4s` bytes) never sets it. Control falls through to `entry.isCompleted = true`; the entry leaves `waitDownloadQueue`, joins `downloadList` as 已缓存, and tapping it goes straight to playback (pages/download/detail/widgets/item.dart:114-139) — `startDownload` is only reachable for `!isCompleted`, so the only recovery is delete + re-download. Fix: treat `FormatException` (and `RangeError`, see below) as damaged for `mediaType == 2` too, and keep the entry in the queue as `failMerge`.

## U47 (agent-media)
- [P1] [A] `deletePage` never stops a download that is running or queued inside that folder — lib/services/download/download_service.dart:1252-1278
  It walks only `downloadList` (completed entries) for `_cancelExtras` / `_deleteMerged`, then `pageDir.tryDel(recursive: true)`; it never touches `waitDownloadQueue` and never calls `cancelDownload` for `curDownload`. Pages of one video share `pageDirPath` (`<root>/<avid>`), so deleting a video from the list (pages/download/view.dart:250, detail/view.dart:163, controller.dart:113) while another of its pages is downloading wipes the live transfer's folder. `DownloadManager._attempt` immediately recreates it (`file.createSync(recursive: true)`, download_manager.dart:126) and `_completeDownload` rewrites `entry.json`, so the video the user just deleted reappears in the list. Fix: mirror `deleteDownload`'s handling — cancel `curDownload`/repair managers and remove queue entries whose `pageDirPath` matches before deleting the folder.

## U48 (agent-media)
- [P2] [A] `hasDashAudio` is only ever set to true — lib/http/download.dart:141, lib/plugin/pl_player/models/data_source.dart:46-49
  Set inside `if (audioDashList != null && audioDashList.isNotEmpty)` and never cleared. An entry that once had a dash audio stream and is later re-resolved to a video-only stream keeps the flag; `_mergeDownload:817` is guarded by `existsSync`, but `FileSource` is not — it hands the player `<typeTag>/audio.m4s`, which does not exist, for any unmerged entry. Fix: assign it unconditionally from the resolved stream.

## U49 (agent-media)
- [P2] [A] Local-document temp mirror leaks for the process lifetime once the playlist advances — lib/services/local_player.dart:145,151-184; lib/pages/video/introduction/local/controller.dart:139-156; lib/pages/video/controller.dart:1333
  `_openDocument` increments `_mirrorsInUse[mirror]`; `release` bails out at `if (entry.playUri == null) return`. `LocalIntroController.playIndex` replaces `videoDetailCtr.entry` with an ordinary download entry (no `playUri`), and `onClose` calls `LocalPlayer.release(entry)` with *that* entry — so the count is never decremented and `_mirrorDir`'s sweep (line 162) skips the folder forever. Reachable whenever the picked folder's `librepili.json` carries a cid that is also in the download list (onInit then builds the playlist from `DownloadPageController.pages`) and playback moves on. Fix: release by the mirror path captured at open time (or track the mirror on the video controller, not on the mutable `entry`).

## U50 (agent-media)
- [P2] [B] `path.join(entryDirPath, oldTypeTag)` collapses to the entry folder when `typeTag` is null, and the folder is then deleted recursively — lib/services/download/download_service.dart:447-462 (and the same pattern at :769)
  `BiliDownloadEntryInfo.typeTag` is `String?`. Probed: `path.join('/root/entry', null)` returns `/root/entry` (no throw, because the null is the last argument). So with `oldTypeTag == null` and a new non-null tag the guard passes and `Directory(entry.entryDirPath).tryDel(recursive: true)` removes `entry.json`, `danmaku.pb` and `cover.jpg` — including the danmaku just fetched a few lines earlier. Line 769 collapses `videoDir` onto the entry dir the same way. Reachability needs an `entry.json` without `type_tag` (a folder written by another tool) — **hypothesis** for reachability; the null-collapse itself is probed. Fix: `if (oldTypeTag != null && oldTypeTag != entry.typeTag)` and a non-null `typeTag` (or an explicit fallback) at line 769.

## U51 (agent-media)
- [P2] [A] A missing durl segment throws `FileSystemException` before anything can repair it, and the entry is marked complete — lib/services/download/download_service.dart:766-834, 950-957; lib/utils/mp4_remux.dart:43-51
  `_repairSegments` only runs when `index.json` parsed into `segments`; otherwise `inputs` falls back to `[videoDir/0.mp4]`. `_exportType1` then calls `inputs.every(Mp4Remuxer.isFlv)` → `_hasMagic` → `File(path).openSync()`, which throws `FileSystemException` on a missing file. That is not a `FormatException`, so `damaged` is false and `_completeDownload` marks the entry complete with no exported file. Fix: make `isFlv`/`isMp4` return false for unreadable files and treat a missing/unreadable input as damaged.

## U52 (agent-media)
- [P2] [A] Video failure leaves the audio transfer running — lib/services/download/download_service.dart:595-620
  On `_onDone(error)` the method sets the status and returns without `_audioDownloadManager?.cancel(...)`. The audio stream keeps downloading (and keeps retrying, up to 6 consecutive failures × back-off) for an entry the UI shows as 下载失败, until the user starts some other entry and `startDownload`'s `_lock` block cancels both. Bandwidth/battery cost, no data loss.

## U53 (agent-media)
- [P2] [A] `totalBytes` is never recorded for a resumed transfer, and `-1` can be persisted — lib/services/download/download_service.dart:580-590; lib/services/download/download_manager.dart:177,199-201
  `_onReceive` writes `totalBytes` only when `progress == 0`, and `DownloadManager` only emits `(0, expected)` when `received == 0`. So a paused-and-resumed download keeps whatever `totalBytes` the first attempt produced; if that attempt had no `Content-Length`, `expected` is `-1` and `_onReceive` stores `total_bytes: -1`, after which `_onDone` sets `downloadedBytes = totalBytes = -1`. The progress bar and the "缓存完成" size are then wrong for the life of the entry. Fix: emit/record the total whenever a non-negative `expected` becomes known, not only at offset 0.

## U54 (agent-media)
- [P3] [A] `RangeError` from a truncated box header escapes as a non-damaged merge failure — lib/utils/mp4_remux.dart:447-473; lib/utils/mp4_join.dart:140-163
  Both readers do `read(16)` while the loop only guarantees `pos + 8 <= length`, then `hd.getUint64(8)` for `size == 1` → `RangeError`. `checkSegment` catches it (mp4_remux.dart:102) but `remux`/`joinMp4`/`remuxFlv` do not, so `_mergeDownload:843` sees a `RangeError` rather than a `FormatException` and takes the "complete but unmerged" path of the P1 finding above. Fix: raise `FormatException` when fewer than `headerSize` bytes are available.

## U55 (agent-media)
- [P3] [A] Android single-file pick sets a `mergedPath` that is never written — lib/services/local_player.dart:64-86,133-147
  `_pickDocument` copies nothing into `mirror` (only `_pickTree` calls `LocalDocuments.copy`), yet `_openDocument` sets `mergedPath = path.join(mirror, video.name)`. Playback is fine (`FileSource` prefers `uri`), but every consumer that treats `mergedPath` as a real file sees a missing one — e.g. the comments lookup in `initFileSource` (pages/video/controller.dart:379-386) and the "视频文件已被移动或删除" check (pages/download/detail/widgets/item.dart:115). Fix: leave `mergedPath` null when nothing was mirrored and derive the side-file folder from `entryDirPath`.

## U56 (agent-media)
- [P3] [A] A merge that outlives a download-folder change re-registers itself with paths outside the new root — lib/services/download/download_service.dart:77-91, 641-700; lib/pages/setting/models/extra_settings.dart:775-793
  `downloadPath` is reassigned before `reloadDownloadList()`, and `cancelDownload` early-returns while `_mergingCids` holds the current entry. When that merge finishes, `_completeDownload` does `downloadList.insert(0, entry)` with `pageDirPath`/`entryDirPath` still pointing into the *old* folder. The list then mixes roots, and a later `deletePage`/`deleteDownload` on it deletes a folder outside the configured download root. **Hypothesis** (not exercised at runtime), but the path is plain in the code.

## U57 (agent-media)
- [P3] [C] `importAll` silently drops local follows that share a mid — lib/services/local_library.dart:41-56
  The re-keying `{for (final v in data.values) '${(v as Map)['mid']}': v}` collapses duplicate mids in a hand-edited/merged backup; `checkImport` passes, so the restore reports success with fewer follows than the backup held. These boxes are the only copy without an account, so a silent drop is worth at least a warning.

## U58 (agent-media)
- [P3] [A] `copyDocuments` deletes the existing file before a rename that may fail — android/.../MainActivity.kt:227-250
  `file.delete()` runs before `part.renameTo(file)`, and the `finally` deletes `part`. A rename failure therefore loses both the old and the new copy. Only the temp side-file mirror is affected (it is refilled on the next open), so the impact is low, but the order should be rename-then-replace.

## U59 (agent-anchored)
- [P1] [A] `mt:*` grant check never validates the URI's authority — `android/app/src/main/kotlin/com/example/piliplus/BiliDocumentsProvider.kt`:188-206
  The new gate takes `extras["uri"]`, calls `checkCallingOrSelfUriPermission(it, WRITE)`, then derives the documentId from **that same URI's path** — but never checks that the URI belongs to this provider's authority. A caller can pass a `content://<its-own-authority>/document/<pkg>%2Fdata%2Fhive%2Faccount.hive` URI it legitimately holds a write grant on; the grant check passes, `isTreeUri` is false so the subtree check is skipped, and `retrieveFile` then operates on LibrePili's private data — e.g. `mt:setPermissions` chmod 0777 on `hive/account.hive` (plaintext SESSDATA/access_key), or `mt:createSymlink` planting a link inside the data dir. Fix: require `it.authority == <this provider's authority>` (and that the document resolves under a root) before using the documentId. *(The authority check is provably absent; that an app can hold a write grant on a URI of its own provider is **hypothesis** — AOSP's uri-permission fast path for the provider's own uid — but the hole does not depend on it, any grantable URI shaped `/document/<id>` works.)*

## U60 (agent-anchored)
- [P1] [A] A download entry whose `entry.json` has no `type_tag` gets its **whole entry folder** deleted on start — `lib/services/download/download_service.dart`:455-462
  `oldTypeTag = entry.typeTag` is `String?`; after `getVideoUrl` always sets a tag, `oldTypeTag != entry.typeTag` is true and the code runs `Directory(path.join(entry.entryDirPath, oldTypeTag)).tryDel(recursive: true)`. `path.join` **drops null/empty parts** (verified in `W:/pub-cache/hosted/pub.dev/path-1.9.1/lib/src/context.dart:264-283` → `joinAll(parts.whereType<String>())`, and `joinAll` filters `part != ''`), so the target is `entryDirPath` itself — danmaku.xml, subtitles, comments, cover, every quality folder. The same hazard exists two lines later: with a null `typeTag`, `videoDir` is the entry dir and the `_streamKey` mismatch branch (`:463-475`) wipes it recursively. Fix: bail out (or skip both deletes) when `typeTag` is null/empty, and assert the computed directory is a strict child of `entryDirPath`. *(Reachability is **hypothesis**: in-app entries always set `typeTag` at `:172`/`:240`; the null case needs an `entry.json` written by another client, which `_readDownloadList` does parse.)*

## U61 (agent-anchored)
- [P2] [C] Empty `tabBarSort` still crashes at launch — `lib/pages/home/controller.dart`:67-80
  F26i hardened only the writer (`lib/pages/setting/pages/bar_set.dart`:50-57). `setTabConfig` still does `tabs.map(...)` with no emptiness check, so a `tabBarSort: []` persisted by a pre-pass-3 build — or restored by the now-supported settings import / WebDAV restore / snapshot path — yields `tabs == []` and `tabs[tabController.index]` throws on the home page, before the user can reach settings to fix it. Fix: `if (tabs == null || tabs.isEmpty) this.tabs = HomeTabType.values;` in the reader.

## U62 (agent-anchored)
- [P2] [A] Import snapshots write WebDAV password + SponsorBlock ID in plaintext into the directory the SAF provider serves — `lib/utils/storage.dart`:126-143
  `_saveSnapshot` calls `exportAllSettings(includeCredentials: true)` into `appSupportDirPath/snapshots/`, which is under `context.filesDir.parentFile` — exactly the tree "允许三方APP访问私有存储" exposes. D9 was specifically about keeping those keys out of files that leave the app, and the new warning text (`extra_settings.dart:78-81`) names only account cookies/access_key. Fix: exclude `credentialKeys` from the snapshot (restoring them from the live box), or extend the setting's warning to name them.

## U63 (agent-anchored)
- [P2] [A] An About-page import takes a snapshot the user can never find or undo from there — `lib/pages/about/view.dart`:285-298 vs `lib/pages/webdav/view.dart`:145-156
  `importAllJsonSettings` snapshots on every import, but only the WebDAV restore toasts the path (`webdav.dart:128`) and only the WebDAV page carries 恢复到导入前. A user who imports a bad backup from 关于 › 导入/导出设置 sees no indication that an undo exists. Fix: toast the snapshot path after the About import too and surface 恢复到导入前 next to the import entry.

## U64 (agent-anchored)
- [P3] [A] Live danmaku: the *first* token fetch failure still ends live chat silently — `lib/pages/live_room/controller.dart`:516-529
  `_connectDm` only reschedules when `_dmRetryCount > 0`, so `liveRoomGetDanmakuToken` failing on the initial connect leaves `_msgStream == null`, no timer, and `startLiveMsg` will re-enter — but nothing re-triggers it until the user pauses or leaves. This is the residue of U46's "init() only shows a toast". Fix: schedule the backoff on any token failure.

## U65 (agent-anchored)
- [P3] [A] `恢复到导入前` is one-shot and destroys the state it replaces — `lib/utils/storage.dart`:162-171
  `restoreLatestSnapshot` imports with `snapshot: false` and then deletes the file, so the post-import state is gone with no snapshot of its own and the undo cannot be repeated or reversed. Fix: snapshot before undoing (or keep the file until the next import).

## U66 (agent-anchored)
- [P3] [A] `markExpired` keeps a dead account's plaintext cookies forever — `lib/utils/accounts.dart`:82-95
  D1 replaced `deleteAll` (which called `cookieJar.deleteAll()`) with a flag flip, so an invalidated SESSDATA/`access_key` stays in `hive/account.hive` indefinitely, in the tree the SAF provider serves. Fix: clear the cookie jar (or at least SESSDATA) while keeping the record, or prompt to remove.

## U67 (agent-anchored)
- [P3] [A] Once today's timestamp is stamped, a stale WBI key is used all day with no retry — `lib/utils/wbi_sign.dart`:102-118
  `getWbiKeys` stores `timeStamp` *before* fetching; on failure with a cached key from a previous day the same-day branch returns that stale key on every later call and never refetches. U10/U38's "broken until midnight" is narrowed (no more `''`) but not closed. Fix: store the timestamp only after a successful fetch.

## U68 (agent-anchored)
- [P3] [D] `_streamKey` does not include the stream size the claim (and U35) asked for — `lib/services/download/download_service.dart`:531-545
  The dash key is `id/codecid/WxH` and the durl key is only the segment byte list; `Type2File.size` is `0` at this point so size genuinely cannot be used here. The claim "video/audio id, codec and **size**" overstates what is compared, and a same-id/same-codec stream of different length still resumes onto the old partial. Fix: reword the claim, or compare the `Content-Range` total against the saved `totalBytes` at resume time.

## U69 (agent-anchored)
- [P3] [A] Linux note cookies are still injected as script-readable `document.cookie` — `lib/utils/linux_cookie_manager.dart`:57-71
  A7 removed `max-age` and clears the store on close, but SESSDATA/`bili_jct` still go in via JS with no `HttpOnly`, so any script on the note page can read them for the lifetime of the window. U8 flagged both halves. Fix: inject through the WebKit cookie manager rather than `document.cookie`, or accept and document it.

## U70 (agent-anchored)
- [P3] [A] geetest captcha WebView still allows mixed content — `lib/pages/login/geetest/geetest_webview_dialog.dart`:218
  `MIXED_CONTENT_ALWAYS_ALLOW` survives A3 (deliberately, per the fixer). This WebView runs during login. Fix: try `MIXED_CONTENT_COMPATIBILITY_MODE` and verify the captcha still loads.

## U71 (agent-anchored)
- [P3] [A] Scheduled-post "same day" test still compares only the day of month — `lib/pages/dynamics_create/view.dart`:524-531
  `selectedDate.day == nowDate.day` treats e.g. 20 Sep and 20 Oct as the same day, so a future date with an earlier clock time is wrongly rejected with "至少选择6分钟之后". Same class of bug as the WBI date check fixed in A9b. Fix: compare `DateUtils.isSameDay`.

## U72 (agent-anchored)
- [P3] [C] Pull-to-refresh is no longer de-duplicated — `lib/pages/common/common_list_controller.dart`:29
  The guard changed from `isLoading || (!isRefresh && isEnd)` to `!isRefresh && (isLoading || isEnd)`, so every refresh now issues a request even while one is in flight (the generation counter discards the older response). Correct, but it doubles requests on a fast second pull across most list pages. Fix: if traffic matters, coalesce concurrent refreshes instead of racing them.

## U73 (agent-anchored)
- [P3] [B] `--selftest` JSON now emits `null` for `durationMs`/`positionMs` — `lib/utils/self_test.dart`:146-149, :224-226
  Switching to the nullable `PlPlayerController.instance` changed these fields from always-int to nullable for a documented scripted-check interface. Fix: default to `0` (as `positionMs` already does at `:146`) or document the nullability.

## U74 (agent-anchored)
- [P3] [A] The CI signing guard covers only one of the four secrets, and gradle still falls back to the debug key — `.github/workflows/build.yml`:86-102, `android/app/build.gradle.kts`:46-65
  If `SIGN_KEYSTORE_BASE64` is set but `KEYSTORE_PASSWORD`/`KEY_ALIAS`/`KEY_PASSWORD` are empty, the guard passes and `signingConfig = config ?: signingConfigs["debug"]` is unchanged, so a release can still be produced with a key that cannot update installed builds. Fix: check all four secrets, and fail the gradle release variant when no release config exists.

## U75 (agent-anchored)
- [P3] [A] WebDAV backup leaves an orphan `.tmp` when the MOVE fails — `lib/pages/webdav/webdav.dart`:96-102
  If the server rejects `rename(..., overwrite: true)`, the old backup is correctly preserved but the user sees only "备份失败: …" and `<file>.json.tmp` accumulates remotely. Fix: delete the temp file in the catch and say the old backup is intact.

## U76 (agent-anchored)
- [P3] [A] `_isBlockServer` matches host only — `lib/utils/accounts/account_manager/account_mgr.dart`:228-235
  Scheme, port and path are ignored, so a `blockServer` pointing at a bilibili host (e.g. `https://api.bilibili.com/sb`) would once again make `_skipCookie` true for every API request — the U5 catastrophe, now requiring a deliberate value that the dialog accepts. Fix: also require the path prefix, or reject bilibili hosts.

## U77 (agent-anchored)
- [P3] [D] `fixerA-resume.txt` line 71 is stale — `audit-logs/librepili-pass-3/fixerA-resume.txt`:71 vs `android/app/src/main/java/com/example/piliplus/AndroidHelper.java`:90-92
  The report states "the list is empty and **the feature is off** until one is added"; at HEAD `ANTIFRAUD_CERT_SHA256` contains `0225A7553765722353B0A27980F779A4ECF8302AFB27911E3D42AACBECAA31BF` (added by the `fixerA-cert` follow-up), so the feature is on. Anyone reading the pass-3 report to decide whether cookies can reach the anti-fraud app gets the wrong answer.

---

