# Watch-page checks on the phone

The Android half of S0b's checks (design `feature-logs/watch-page-shell/design.md`
§6.3 「平台」, §6.4's phone items, §6.5 AC-S0 「每项 Android 检查的对照两边不同」).

| file | what |
|---|---|
| `wp_adb.ps1` | the driver: device check, the self-test gate, the phone's settings kept and put back, installs, cold-started runs, the host side of the tests' `host:` steps, reports pulled, profiles deleted, parent / this-step alternation. Its header lists the rules it keeps |
| `wp_fields/A-*.json` | one field table per Android check, run.ps1's format plus `platform: android`, `mutants: none` (Android checks never go into the mutants, §6.3) and `control` (the in-run contrast that must differ) |

The steps the tables use (`host:`, `sys:`, `syspip`, `setbrightness`,
`brightness`, `closeall`, `fs:…@orientation`) and the readings' `android`
part are in `lib/utils/self_test.dart` (`_wpSteps`'s doc comment) and
`lib/utils/self_test_watch.dart` (`_android`, `androidSystem`). The profile
wipe is the self test `--wipe-profile NAME`.

## The phone

Only the Pixel 4 XL, by identity. `-Serial` must be its USB serial
`9B131FFBA000PG` (the script's default) or `10.0.1.191:5555` (Wi-Fi); any
other serial, the OnePlus `1aa3f41f` first of all, is refused before adb is
started. Then two reads, and nothing else until both hold:
`ro.serialno` must be `9B131FFBA000PG` and `ro.product.model` `Pixel 4 XL`.
A phone that fails them gets no other command, cleanup included (the
script's cleanup only runs on an identified phone).

Only the dev package `com.zxa24.librepili.dev`, and only its user 0: the
phone has a work profile (user 11, running) that the dev package is not
installed in (`installed=false`). Installs are `install -r --user 0`;
`am start` and `am force-stop` carry `--user 0`. Before the session user 0
must have the package installed with a firstInstallTime; after each install
user 11's `installed=` must be what it was (a change stops the run, as a
downgrade does). The release package `com.zxa24.librepili` is never touched
(the driver refuses an APK whose name or manifest is not the dev package's,
and stops if the release package changes). Each user's values are read
inside that user's own block of `dumpsys package`.

Between S0b and S2 nothing else installs a dev package on the Pixel
(design §6.3, wp11#pixelBan: a commit-count build would be a downgrade from
5688 for every later comparison install).

## The APKs (CI; this machine has no Android SDK)

Every compared APK is built with the same versionCode, **5688** (the dev
package's 5687 on the phone + 1, design §6.3 「从不卸载」), so `install -r`
swaps them both ways. The workflow input `build_number` sets it (flutter
`--build-number`, which becomes Gradle's `flutter.versionCode`;
`android/app/build.gradle.kts` uses it for every split APK). It is refused
together with `tag`.

A dispatch builds the latest commit of the ref it is given, so each commit
that needs an APK has to be the head of a pushed branch when it is
dispatched. Pushing and dispatching need the user's go-ahead.

```
git push origin <commit>:refs/heads/wp-apk          # the user agrees first
gh workflow run build.yml --ref wp-apk -f build_android=true -f android_dev=true -f build_number=5688 -f build_ios=false -f build_mac=false -f build_win_x64=false -f build_linux_x64=false
gh run list --workflow build.yml --limit 3           # the run's id
gh run watch <run>
gh api repos/zxa24/PiliPlus/actions/runs/<run>/artifacts --jq '.artifacts[] | select(.name=="Android_arm64-v8a") | .id'
gh api repos/zxa24/PiliPlus/actions/artifacts/<artifact>/zip > _tmp/android/apk/<the file name below>
```

The artifact is uploaded unarchived (`archive: false`): the `zip` endpoint
gives the APK itself (DEV_LOG 2026-10-16; `gh run download` unpacks it as
if it were a zip). Its name is
`LibrePili_android_<x.y.z>-<sha9>+<commit count>_dev_vc5688_arm64-v8a.apk`:
`+<commit count>` is the version string's, the versionCode is the `_vc`
part. Check the run's log line `versionCode fixed at 5688`, and the
driver's `versionCode` after the install.

## Order of steps (part 6b, on the APK of S0b)

1. Build the S0b APK as above; keep it under `_tmp/android/apk/`.
2. `pwsh -NoProfile -File test/android/wp_adb.ps1 -CheckTables` (offline).
3. First install and the old build's leftover: the validation of part 6a
   ran the old build (5687) under profile `wp6aval`, which that build could
   not delete:
   `pwsh -NoProfile -File test/android/wp_adb.ps1 -Raw -Apk <S0b apk> -SelfTestArgs --metrics -ExpectChecks metrics -RawName wpinstall`
   (installs 5687 → 5688, an update; the run's own profile is wiped after
   it, which also shows the wipe works), then
   `pwsh -NoProfile -File test/android/wp_adb.ps1 -Wipe wp6aval`.
4. R8's sideways window (design §6.3 「横屏的对照」; see below): run
   `-Checks A-R8-back-hsoff -Commit <S0b> -Passes 1 -LandscapeMethod freeform`.
   It works when `moments.sideways.android.orientation` is `landscape`,
   `moments.sideways.android.canPop` is `false` and the upright one `true`.
   If not, the same with `-LandscapeMethod wmsize`. Write the one that
   works into the table's `landscapeMethod` and the design's §6.3 line.
5. Calibration: `-Checks all -Commit <S0b> -Passes 2 -LandscapeMethod <chosen>`,
   then `pwsh -NoProfile -File test/mutants/run.ps1 -Plan watch_page -Compare <Out>\<sha9> -FieldTables test\android\wp_fields -Out <Out>\calibration`;
   mark what varies `unstable` in the tables. `controls.json` beside the
   reports must say `differ` for every table and pass (AC-S0: a control
   that does not differ makes that check 不灵敏, not evidence).
6. Later comparisons (AC-S1 and on): one APK of the step and one of its
   parent, both 5688, then
   `-Alternate -ParentApk <apk> -Parent <rev> -NewApk <apk> -Commit <rev> -Passes 2 -LandscapeMethod <chosen>`
   (parent, this step, parent, this step; each pass's APK installed over the
   other, versions checked, each check under a new profile deleted after the
   pass), then run.ps1's `-Compare <parentDir>,<newDir> -FieldTables test\android\wp_fields`.

Every run is a cold start (`am force-stop --user 0`, then `am start --user 0`
with the arguments; a running engine takes no new ones). The gate
(`debug.librepili.selftest`) is armed for cleanup before it is opened, and
shut and read back at the session's end, whatever happened.

After every run `user_rotation` and `wm size` are put back to the
session's values and read back (a run's host steps change them; the next
run must not start from them). The freeform globals are set only around
the R8 runs that need them (`-LandscapeMethod freeform`) and put back right
after. At the end every setting is put back on its own: one that fails
does not stop the others; each is read back, failures are listed and the
exit code is 2 (1 when the session stopped). A session that stops (an
error, Ctrl+C) shuts the gate and puts the settings back before anything
else and starts no wipe run: the pass's profiles are listed for a later
`-Wipe`.

`-Controls <side folder>` recomputes that folder's `controls.json` offline
(no adb): a row for every table and pass, `differ`, `不灵敏` (a pair equal,
or a pinned value other than the table's `expect`) or `无结果` with the
reason (no report, no partner report, unparseable, no check, not measured,
a value missing or unread). A run whose wait timed out is not measured:
every `waitfor` in the tables is followed by a `require` of the same
condition (`-CheckTables` refuses a table without it).

## The checks

| table | phone item | control (must differ) |
|---|---|---|
| `A-R3-rotate-hson` | R3 / F0: upright, into native fullscreen (landscape) and out, 横屏适配 on | window size before / in fullscreen |
| `A-R3-rotate-hsoff` | the same with 横屏适配 off (the exit always asks portrait) | the same |
| `A-R3-held-landscape` | R3 横着拿着退出: turned landscape in fullscreen (host `user_rotation 1`), out; 3 s of frames after | window size held / turned back |
| `A-R3-threecol-portraitfs` | R3 三栏 → 竖屏全屏: portrait video, phone landscape, fullscreen asks portrait; side column width before / after, uiErrors | window size before / in fullscreen |
| `A-F0-inapp` | F0's 「Android 应用内全屏（Shift+F）」 | window size before / in fullscreen |
| `A-R5-statusbar` | R5: status-bar icons at scrollRatio 0 and ≥ 0.5 | the icon brightness |
| `A-R8-back-hsoff` | R8: 横屏适配 off, back upright and sideways: canPop + didPop | canPop |
| `A-R9-brightness` | R9: the app's brightness reset when covered, restored on return | back without / after a brightness change |
| `A-R12-safearea-off`, `-on` | R12: padding and system bars; 嵌套观看页返回, 全屏中返回主页, 隐藏时离开本页 | the page's padding, one run against the other |
| `A-R15-syspip` | R15: system picture in picture renders only the player | what the page renders out of / in PiP |
| `A-R15-fspip-auto` | R3 / R15 全屏中进画中画 (autoPiP, home key) | in fullscreen / in PiP |

Not covered: R15's SDK < 31 `_onUserLeaveHint` path (the Pixel runs SDK 36,
design wp3#33); the window mode `isWindowMode` (needs the freeform window
of step 4; not a table yet).

## R8's sideways window

With 横屏适配 off the app locks portrait at start and after every
fullscreen exit, so on this phone "横屏适配关、横着" exists only in a window
that is not the whole screen. Two ways are written; neither has been run
(part 6a had no APK with these steps):

- `freeform` (tried first, as the design says): `enable_freeform_support`
  and `force_resizable_activities` set to 1 around that run only (recorded,
  put back and read back right after it), the run started with
  `am start --user 0 --windowingMode 5`, and
  `host:landscape` / `host:portrait` resize the task
  (`cmd activity task resize <task> l t r b`) to a landscape- or
  portrait-shaped window. In multi-window the app's orientation request
  does not apply. Unknown until run: whether this ROM honours freeform from
  `am start`, and whether the resize command has that form here.
- `wmsize`: `wm size 3040x1440` (a landscape-shaped display at rotation 0)
  and back. The design's 「假设」: the app's portrait request may turn the
  display back, in which case this way does not give a landscape window.

## What the phone keeps

The dev package at versionCode 5688 with its data, and one self-test
profile `wpwipe` (the profile the wipe itself runs under; small). Every
check's profile is deleted after its pass; reports are pulled and deleted
from `/sdcard/Android/data/com.zxa24.librepili.dev/files/`.
`accelerometer_rotation`, `user_rotation`, `wm size` and the freeform
globals are as they were (the script prints them before and after).

## Stops (`STOP: …`) and what to do

| message | what to do |
|---|---|
| `… is the OnePlus` / `… is not the Pixel 4 XL's` | wrong `-Serial`. adb was not started |
| `device … has serial number …` / `device … is '…', not Pixel 4 XL` | the serial reached another phone. Only the two identity reads were sent; nothing was changed |
| `user 11 (work profile) changed` | the install reached the work profile. Never uninstall; tell the user |
| `… not installed for user 0` / `no firstInstallTime for user 0` | the dev package is not where this procedure expects it; ask the user |
| `downgrade refused by the phone` | an APK with a lower versionCode than the phone's. **Never uninstall** (it deletes the package's data). Tell the user; rebuild with the phone's versionCode |
| `signature mismatch` | the APK was not signed with the CI key. Never uninstall; tell the user |
| `versionCode after install is …` | the APK was built without `build_number`. Rebuild |
| `firstInstallTime changed` | the package was reinstalled, not updated: its data may be gone. Stop and tell the user |
| `the release package changed during the install` | should not happen (the APK checks run first). Stop and tell the user |
| `… is not installed` | the procedure only updates the dev package; ask the user before installing it fresh |
| `… not a dev arm64 APK by its name` / `manifest does not name …` | the wrong file |

A run that does not finish (`error: no finished report`, `the app ended
without a finished report`) is that check's 无结果 for the pass: rerun it
into a new pass. A check whose report says `host:…: no answer from the host`
lost its handshake (the script stopped or adb dropped).

`PUT BACK BY HAND: …` lists what the cleanup could not restore (exit code
2, or 1 with a stop). `-FailAt probe-after-rotation` (with `-ProbeRotation`)
and `-FailAt raw-after-gate` (with `-Raw`) are test switches: they throw at
that point, to show the cleanup puts everything back.

If the script is killed hard (the process ended, not Ctrl+C), put the
phone back by hand:

```
adb -s 9B131FFBA000PG shell setprop debug.librepili.selftest 0
adb -s 9B131FFBA000PG shell setprop debug.librepili.ack 0
adb -s 9B131FFBA000PG shell settings put system accelerometer_rotation <before>
adb -s 9B131FFBA000PG shell settings put system user_rotation <before>
adb -s 9B131FFBA000PG shell wm size reset          # or the Override it had
adb -s 9B131FFBA000PG shell am force-stop --user 0 com.zxa24.librepili.dev
adb -s 9B131FFBA000PG shell settings put global enable_freeform_support <before>   # or settings delete, if it was null
adb -s 9B131FFBA000PG shell settings put global force_resizable_activities <before>
```

The values from before are the first lines the script printed, and in each
report folder's `manifest.json` (`phoneSettingsBefore`). Every adb command
of a session is in `<Out>\adb.log`.
