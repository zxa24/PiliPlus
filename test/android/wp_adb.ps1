# The watch-page checks on the phone (design feature-logs/watch-page-shell/
# design.md §6.3 「Android 的做法」, S0b's Android procedure; README.md beside
# this script has the order of steps and what to do at each stop).
#
#   pwsh -NoProfile -File test/android/wp_adb.ps1 -CheckTables
#   pwsh -NoProfile -File test/android/wp_adb.ps1 -Alternate
#        -ParentApk <apk> -Parent <rev> -NewApk <apk> -Commit <rev>
#        [-Checks id,id] [-Passes 2] [-Out <dir>] [-LandscapeMethod freeform|wmsize]
#   pwsh -NoProfile -File test/android/wp_adb.ps1 -Checks id,id -Commit <rev>
#        [-Apk <apk>] [-Passes 2] [-Out <dir>]     (one commit: calibration)
#   pwsh -NoProfile -File test/android/wp_adb.ps1 -Raw -SelfTestArgs a,b
#        -ExpectChecks name [-RawName <profile>] [-NoWipe]   (one plain run)
#   pwsh -NoProfile -File test/android/wp_adb.ps1 -Wipe name,name
#   pwsh -NoProfile -File test/android/wp_adb.ps1 -ProbeRotation
#   pwsh -NoProfile -File test/android/wp_adb.ps1 -Controls <sideDir> [-Checks id,id]
#        (offline: that folder's controls.json recomputed; no adb)
#   any of them with -DryRun: every adb command printed, none run
#   -FailAt <point>: test only, throws at that point (README 「停下时」)
#
# The rules it keeps (each one is the design's, §6.3):
# - one phone: the Pixel 4 XL, by identity. `-Serial` must be its USB serial
#   9B131FFBA000PG or 10.0.1.191:5555 (Wi-Fi); anything else, and the OnePlus
#   1aa3f41f in particular, is refused before adb starts. The first adb calls
#   only read: ro.serialno must be 9B131FFBA000PG and ro.product.model
#   "Pixel 4 XL". Until both hold no adb command that changes anything is
#   sent, cleanup included. Every adb call carries -s <serial>.
# - only the dev package com.zxa24.librepili.dev, and only its user 0 (the
#   phone has a work profile, user 11, the package is not installed in):
#   `install -r --user 0` (no -d, no uninstall anywhere), after its file name
#   and its manifest say it is the dev package; `am start` / `am force-stop`
#   with `--user 0`. Before the session user 0 must have it installed with a
#   firstInstallTime; after each install versionCode must be
#   -ExpectVersionCode, user 0 installed with the same firstInstallTime (an
#   update, the data kept), user 11's installed= what it was, and the release
#   package's versionCode / lastUpdateTime unchanged. Any other answer stops
#   the run: see README.
# - the self-test gate: armed for cleanup before `setprop
#   debug.librepili.selftest 1`; the cleanup sets 0 and reads it back,
#   whatever happened. The handshake's `debug.librepili.ack` goes to 0 with
#   it.
# - the phone's settings: accelerometer_rotation, user_rotation, the `wm
#   size` override and the two freeform globals recorded before; user_rotation
#   and `wm size` put back and read back after every run; the freeform
#   globals set only around the R8 runs that need them and put back right
#   after; at the end each setting restored in its own try, all attempted,
#   each read back, failures listed and the exit code non-zero. When the
#   session stops (an error, Ctrl+C) the gate is shut and the settings put
#   back first; no wipe run is started while stopping (the pass's profiles
#   are listed for a later -Wipe).
# - a cold start per run: `am force-stop --user 0`, then `am start --user 0`
#   with `--esa selftest_args` (am splits that at every comma: an argument
#   with a comma is refused, except a --pref value, whose `%` and `,` are
#   written %25 / %2C — self_test_pref.dart decodes them). The command is a
#   script pushed to /data/local/tmp (no quoting through two shells), removed
#   after. Every phone path in a shell command is single-quoted. A fresh
#   report name per run, a stale one deleted first; the local copy is
#   deleted before the pull; a failed pull is 无结果; the report must name
#   the checks the run asked for.
# - names: profiles, the raw run's name and report names match
#   ^wp[A-Za-z0-9_-]*$ and are checked before any phone command.
# - profiles: one new --profile per check and pass (wp-<sha9>-p<pass>-<id>),
#   deleted on the phone after the pass by the app itself (`--wipe-profile`,
#   self_test.dart _wipeProfiles), run under the fixed profile wpwipe: a
#   release build's private storage is out of the shell's reach (run-as:
#   "package not debuggable"). The wipe profile itself stays (README).
# - the host side of a check's `host:ACTION` steps: the test writes
#   <report>.host, this script does the action and answers with
#   `setprop debug.librepili.ack <token>`. Actions: rotate:N (user_rotation),
#   home, front, landscape / portrait (R8's window shape, by
#   -LandscapeMethod; refused without it).
#
# Report folders have run.ps1's layout (WP_REPORT_SHAPE.md §5): per commit
# <Out>\parent-<sha9>\ and new-<sha9>\ (one commit: <Out>\<sha9>\) with
# manifest.json (plan watch_page, platform android), runs.jsonl and
# passN\pass.json + the reports, so the comparison is run.ps1's:
#   run.ps1 -Plan watch_page -Compare <parentDir>,<newDir> -FieldTables test\android\wp_fields
# Beside them controls.json: every requested table's control per pass
# (design §6.3 「Android 检查的对照」: differ, 不灵敏 or 无结果).
[CmdletBinding()]
param(
    [string]$Serial = '9B131FFBA000PG',
    [string]$Adb = 'C:\Users\Z14\Documents\Apps\Streaming\Escrcpy\resources\extra\win\android-platform-tools\adb.exe',
    [switch]$CheckTables,
    [string]$Controls = '',
    [string[]]$Checks = @(),
    [switch]$Alternate,
    [string]$ParentApk = '',
    [string]$NewApk = '',
    [string]$Apk = '',
    [string]$Parent = '',
    [string]$Commit = '',
    [int]$Passes = 2,
    [string]$Out = '',
    [switch]$Raw,
    [string[]]$SelfTestArgs = @(),
    [string[]]$ExpectChecks = @(),
    [string]$RawName = 'wpraw',
    [int]$RawMinutes = 5,
    [string[]]$Wipe = @(),
    [switch]$ProbeRotation,
    [ValidateSet('', 'freeform', 'wmsize')] [string]$LandscapeMethod = '',
    [int]$ExpectVersionCode = 5688,
    [switch]$NoWipe,
    [switch]$DryRun,
    # test only: throw at this point, to show the cleanup puts everything back
    [ValidateSet('', 'probe-after-rotation', 'raw-after-gate')] [string]$FailAt = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3
$Checks = @($Checks | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$Wipe = @($Wipe | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$ExpectChecks = @($ExpectChecks | ForEach-Object { $_ -split ',' } | Where-Object { $_ })

$here = $PSScriptRoot
$root = (git -C $here rev-parse --show-toplevel).Trim() -replace '/', '\'
$tablesDir = Join-Path $here 'wp_fields'
$Pkg = 'com.zxa24.librepili.dev'
$ReleasePkg = 'com.zxa24.librepili'
$Activity = "$Pkg/com.example.piliplus.MainActivity"
$PhoneFiles = "/sdcard/Android/data/$Pkg/files"
$PhoneScript = '/data/local/tmp/librepili_wp_start.sh'
$WipeProfile = 'wpwipe'
$OnePlus = '1aa3f41f'
$Model = 'Pixel 4 XL'
$PhoneSerialNo = '9B131FFBA000PG'
$AllowedSerials = @('9B131FFBA000PG', '10.0.1.191:5555')
$NamePattern = '^wp[A-Za-z0-9_-]*$'

# run.ps1's functions (the table loader, the plan's prefs, the run's
# command line) in a module of their own: dot-sourced here, its parameters
# would overwrite this script's
$runner = Join-Path $root 'test\mutants\run.ps1'
$null = New-Module -Name WpRunner -ArgumentList $runner -ScriptBlock {
    param($r)
    . $r -LoadOnly -Plan watch_page
    Export-ModuleMember -Function *
} | Import-Module -PassThru

function Stop-Wp([string]$why) { throw "STOP: $why" }

# set once the phone has been identified: nothing that changes the phone is
# sent before, cleanup included
$script:deviceOk = $false
$script:restoreFailures = [System.Collections.Generic.List[string]]::new()
$script:pendingWipe = [System.Collections.Generic.List[string]]::new()
$script:freeformOn = $false
$script:stayOnSet = $false
$script:wokeScreen = $false

# ------------------------------------------------------------------ names, quoting
function Assert-Name([string]$name, [string]$what) {
    if ($name -cnotmatch $NamePattern) { throw "$what '$name' does not match $NamePattern (refused before any phone command)" }
}

# one argument for the phone's sh: single-quoted, a ' inside written '\''
function Q([string]$s) { return "'" + $s.Replace("'", "'\''") + "'" }

# ------------------------------------------------------------------ adb
$script:adbLog = [System.Collections.Generic.List[string]]::new()

# one adb call, -s first. -DryRun prints it and returns $dry (what a read
# would answer, for the flow to go on); nothing reaches the phone.
function Invoke-Adb([string[]]$a, [string]$dry = '') {
    $line = "adb -s $Serial $($a -join ' ')"
    $script:adbLog.Add($line)
    if ($DryRun) { Write-Host "  [dry] $line"; return $dry }
    $out = & $Adb -s $Serial @a 2>&1
    $code = $LASTEXITCODE
    $text = (@($out) | ForEach-Object { "$_" }) -join "`n"
    if ($code -ne 0) { throw "adb failed ($code): $line`n$text" }
    return $text.TrimEnd()
}

function Invoke-Shell([string]$cmd, [string]$dry = '') { Invoke-Adb @('shell', $cmd) $dry }

# a command that changes the phone: only once it has been identified
function Invoke-Change([string]$cmd, [string]$dry = '') {
    if (-not $script:deviceOk) { throw "refused: '$cmd' before the phone was identified" }
    Invoke-Shell $cmd $dry
}

function Assert-Device {
    $sn = (Invoke-Shell 'getprop ro.serialno' $PhoneSerialNo).Trim()
    $m = (Invoke-Shell 'getprop ro.product.model' $Model).Trim()
    if ($sn -ne $PhoneSerialNo) { Stop-Wp "device $Serial has serial number '$sn', not $PhoneSerialNo (the Pixel 4 XL): refused, nothing changed" }
    if ($m -ne $Model) { Stop-Wp "device $Serial is '$m', not ${Model}: refused, nothing changed" }
    $script:sdk = (Invoke-Shell 'getprop ro.build.version.sdk' '36').Trim()
    $script:deviceOk = $true
    Write-Host "device $Serial = $Model, serial number $sn (sdk $($script:sdk))"
}

function Get-Prop([string]$name, [string]$dry) { (Invoke-Shell "getprop $name" $dry).Trim() }

function Set-Gate([string]$v) {
    $null = Invoke-Change "setprop debug.librepili.selftest $v"
    $back = Get-Prop 'debug.librepili.selftest' $v
    if ($back -ne $v) { throw "debug.librepili.selftest read back '$back', not $v" }
    Write-Host "selftest gate = $back (read back)"
}

function Set-Ack([string]$v) {
    $null = Invoke-Change "setprop debug.librepili.ack $v"
}

# ------------------------------------------------------------------ phone settings
function Read-Setting([string]$ns, [string]$key, [string]$dry = '0') { (Invoke-Shell "settings get $ns $key" $dry).Trim() }

function Read-WmOverride {
    $wm = Invoke-Shell 'wm size' 'Physical size: 1440x3040'
    if ($wm -match 'Override size:\s*(\d+x\d+)') { return $Matches[1] }
    return $null
}

function Read-PhoneSettings {
    return [ordered]@{
        accelerometer_rotation = Read-Setting system accelerometer_rotation
        user_rotation = Read-Setting system user_rotation
        wmSizeOverride = Read-WmOverride
        enable_freeform_support = Read-Setting global enable_freeform_support 'null'
        force_resizable_activities = Read-Setting global force_resizable_activities 'null'
        stay_on_while_plugged_in = Read-Setting global stay_on_while_plugged_in 'null'
        awake = Test-Awake
    }
}

# the screen: on (mWakefulness=Awake) and no lock screen showing
function Test-Awake {
    $p = Invoke-Shell 'dumpsys power' 'mWakefulness=Awake'
    return [bool]($p -match 'mWakefulness=Awake')
}

function Test-KeyguardShowing {
    $w = Invoke-Shell 'dumpsys window' 'isKeyguardShowing=false'
    return [bool]($w -match 'isKeyguardShowing=true')
}

# before every run: a dozing or locked phone does not resume the activity,
# so Flutter draws no frames and a pushed page is never built (6b: every
# watch-page run said "no new page"). The screen woken, the swipe lock
# dismissed; a lock with a credential cannot be, and stops the session.
function Wake-Phone {
    $script:wokeScreen = $true
    $null = Invoke-Change 'input keyevent KEYCODE_WAKEUP'
    Start-Sleep -Milliseconds 600
    $null = Invoke-Change 'wm dismiss-keyguard'
    $deadline = (Get-Date).AddSeconds(8)
    while ($true) {
        $awake = Test-Awake
        $locked = Test-KeyguardShowing
        if ($DryRun -or ($awake -and -not $locked)) { return }
        if ((Get-Date) -gt $deadline) { Stop-Wp "the phone could not be woken and unlocked (awake=$awake, lock screen showing=$locked): unlock it by hand, or it has a PIN / pattern the script must not enter (README)" }
        Start-Sleep -Milliseconds 500
    }
}

function Set-StayOn {
    if ($script:stayOnSet) { return }
    $script:stayOnSet = $true
    Set-Setting global stay_on_while_plugged_in '7'
}

function Set-Setting([string]$ns, [string]$key, [string]$v) {
    if ($v -eq 'null' -or $v -eq '') { $null = Invoke-Change "settings delete $ns $key" }
    else { $null = Invoke-Change "settings put $ns $key $v" }
}

function Set-WmSize($override) {
    if ($override) { $null = Invoke-Change "wm size $override" } else { $null = Invoke-Change 'wm size reset' }
}

# one setting put back and read back, on its own: a failure is collected,
# never stops the others
function Restore-One([string]$name, [scriptblock]$set, [scriptblock]$read, $want) {
    try {
        & $set
        $got = & $read
        $okNow = ("$got" -eq "$want") -or ($DryRun)
        if (-not $okNow) { $script:restoreFailures.Add("$name read back '$got', not '$want'") }
        return "$name=$got"
    } catch {
        $script:restoreFailures.Add("$name`: $_")
        return "$name=(failed)"
    }
}

# after every run: what a run's host steps can change
function Restore-RunSettings($saved) {
    $before = $script:restoreFailures.Count
    $a = Restore-One 'user_rotation' { Set-Setting system user_rotation $saved.user_rotation } { Read-Setting system user_rotation } $saved.user_rotation
    $b = Restore-One 'wm size' { Set-WmSize $saved.wmSizeOverride } { Read-WmOverride } $saved.wmSizeOverride
    if ($script:restoreFailures.Count -gt $before) { throw "the phone's settings could not be put back after the run ($a, $b): $($script:restoreFailures -join '; ')" }
}

function Set-Freeform {
    Set-Setting global enable_freeform_support '1'
    Set-Setting global force_resizable_activities '1'
    $script:freeformOn = $true
}

function Restore-Freeform($saved) {
    $before = $script:restoreFailures.Count
    $null = Restore-One 'enable_freeform_support' { Set-Setting global enable_freeform_support $saved.enable_freeform_support } { Read-Setting global enable_freeform_support 'null' } $saved.enable_freeform_support
    $null = Restore-One 'force_resizable_activities' { Set-Setting global force_resizable_activities $saved.force_resizable_activities } { Read-Setting global force_resizable_activities 'null' } $saved.force_resizable_activities
    $script:freeformOn = $false
    if ($script:restoreFailures.Count -gt $before) { throw "the freeform globals could not be put back: $($script:restoreFailures -join '; ')" }
}

# the session's end, stopping or not: each setting on its own, all attempted
function Restore-AllSettings($saved) {
    $parts = @(
        Restore-One 'accelerometer_rotation' { Set-Setting system accelerometer_rotation $saved.accelerometer_rotation } { Read-Setting system accelerometer_rotation } $saved.accelerometer_rotation
        Restore-One 'user_rotation' { Set-Setting system user_rotation $saved.user_rotation } { Read-Setting system user_rotation } $saved.user_rotation
        Restore-One 'wm size' { Set-WmSize $saved.wmSizeOverride } { Read-WmOverride } $saved.wmSizeOverride
    )
    if ($script:freeformOn) {
        $parts += Restore-One 'enable_freeform_support' { Set-Setting global enable_freeform_support $saved.enable_freeform_support } { Read-Setting global enable_freeform_support 'null' } $saved.enable_freeform_support
        $parts += Restore-One 'force_resizable_activities' { Set-Setting global force_resizable_activities $saved.force_resizable_activities } { Read-Setting global force_resizable_activities 'null' } $saved.force_resizable_activities
    } else {
        foreach ($k in 'enable_freeform_support', 'force_resizable_activities') {
            try {
                $g = Read-Setting global $k 'null'
                if ($g -ne $saved[$k]) { $script:restoreFailures.Add("$k is '$g', not '$($saved[$k])' (untouched by this session?)") }
                $parts += "$k=$g"
            } catch { $script:restoreFailures.Add("$k read: $_") }
        }
    }
    if ($script:stayOnSet) {
        $parts += Restore-One 'stay_on_while_plugged_in' { Set-Setting global stay_on_while_plugged_in $saved.stay_on_while_plugged_in } { Read-Setting global stay_on_while_plugged_in 'null' } $saved.stay_on_while_plugged_in
    } else {
        try { $parts += "stay_on_while_plugged_in=$(Read-Setting global stay_on_while_plugged_in 'null')" } catch { }
    }
    # the screen as it was: off again when the session found it off
    if ($script:wokeScreen -and -not $saved.awake) {
        try {
            $null = Invoke-Change 'input keyevent KEYCODE_SLEEP'
            Start-Sleep -Milliseconds 800
            $a = Test-Awake
            if ($a -and -not $DryRun) { $script:restoreFailures.Add('the screen is still on (it was off before the session)') }
            $parts += "screen awake=$a"
        } catch { $script:restoreFailures.Add("screen off: $_") }
    } else {
        try { $parts += "screen awake=$(Test-Awake)" } catch { }
    }
    Write-Host "phone settings after: $($parts -join ', ')"
}

# ------------------------------------------------------------------ packages
# dumpsys package <pkg>: versionCode, lastUpdateTime, and per user its
# installed= and (user 0) firstInstallTime, each read inside its own user
# block (a line `User N:` and the lines indented under it)
function Read-Package([string]$pkg) {
    $d = Invoke-Shell "dumpsys package $pkg" "Packages:`n  Package [$pkg] (dry):`n    versionCode=$ExpectVersionCode minSdk=24`n    lastUpdateTime=dry`n    User 0: ceDataInode=1 installed=true hidden=false`n      firstInstallTime=dry`n    User 11: ceDataInode=0 installed=false hidden=false`n      firstInstallTime=dry"
    $lines = @($d -split "`n")
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match "^\s*Package \[$([regex]::Escape($pkg))\]") { $start = $i; break } }
    if ($start -lt 0) { return $null }
    $indent0 = ($lines[$start] -replace '^(\s*).*$', '$1').Length
    $end = $lines.Count
    for ($i = $start + 1; $i -lt $lines.Count; $i++) {
        $ind = ($lines[$i] -replace '^(\s*).*$', '$1').Length
        if ($lines[$i].Trim() -and $ind -le $indent0) { $end = $i; break }
    }
    $sect = $lines[$start..($end - 1)]
    $r = [ordered]@{ versionCode = $null; lastUpdateTime = $null; u0Installed = $null; u0FirstInstallTime = $null; u11Installed = 'absent' }
    foreach ($l in $sect) {
        if ($null -eq $r.versionCode -and $l -match 'versionCode=(\d+)') { $r.versionCode = [int]$Matches[1] }
        if ($null -eq $r.lastUpdateTime -and $l -match 'lastUpdateTime=([^\r\n]+)') { $r.lastUpdateTime = $Matches[1].Trim() }
    }
    for ($i = 0; $i -lt $sect.Count; $i++) {
        if ($sect[$i] -notmatch '^(\s*)User (\d+):(.*)$') { continue }
        $uIndent = $Matches[1].Length; $user = $Matches[2]; $rest = $Matches[3]
        $installed = if ($rest -match 'installed=(true|false)') { $Matches[1] } else { 'unknown' }
        $first = $null
        for ($j = $i + 1; $j -lt $sect.Count; $j++) {
            $ind = ($sect[$j] -replace '^(\s*).*$', '$1').Length
            if ($ind -le $uIndent) { break }
            if ($sect[$j] -match 'firstInstallTime=([^\r\n]+)') { $first = $Matches[1].Trim(); break }
        }
        if ($user -eq '0' -and $null -eq $r.u0Installed) { $r.u0Installed = $installed; $r.u0FirstInstallTime = $first }
        if ($user -eq '11' -and $r.u11Installed -eq 'absent') { $r.u11Installed = $installed }
        # the first block of each user only (a later section repeats them)
    }
    return $r
}

function Assert-Baseline($b) {
    if ($null -eq $b) { Stop-Wp "$Pkg is not installed: this procedure only updates it (README)" }
    if ($b.u0Installed -ne 'true') { Stop-Wp "$Pkg is not installed for user 0 (installed=$($b.u0Installed))" }
    if (-not $b.u0FirstInstallTime) { Stop-Wp "$Pkg has no firstInstallTime for user 0: the data-kept check would check nothing" }
}

# the dev package by its file name (CI: LibrePili_android_<ver>_dev[_vcN]_<abi>.apk)
# and by its manifest (the package name in AndroidManifest.xml's string pool)
function Assert-DevApk([string]$apkPath) {
    if (-not (Test-Path -LiteralPath $apkPath)) { if ($DryRun) { Write-Host "  [dry] (no file $apkPath)"; return }; Stop-Wp "no APK $apkPath" }
    $name = Split-Path -Leaf $apkPath
    if ($name -notmatch '^LibrePili_android_.*_dev(_vc\d+)?_arm64-v8a\.apk$') { Stop-Wp "$name is not a dev arm64 APK by its name (LibrePili_android_*_dev[_vcN]_arm64-v8a.apk): refused, the release package is never installed" }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $apkPath).Path)
    try {
        $e = $zip.GetEntry('AndroidManifest.xml')
        if ($null -eq $e) { Stop-Wp "$name has no AndroidManifest.xml" }
        $ms = [System.IO.MemoryStream]::new(); $s = $e.Open(); $s.CopyTo($ms); $s.Dispose()
        $bytes = $ms.ToArray()
    } finally { $zip.Dispose() }
    $u16 = [System.Text.Encoding]::Unicode.GetString($bytes)
    $u8 = [System.Text.Encoding]::UTF8.GetString($bytes)
    if (-not ($u16.Contains($Pkg) -or $u8.Contains($Pkg))) { Stop-Wp "$name's manifest does not name ${Pkg}: refused" }
}

function Install-DevApk([string]$apkPath, $baseline) {
    Assert-DevApk $apkPath
    $relBefore = Read-Package $ReleasePkg
    Write-Host "install -r --user 0 $apkPath"
    $res = ''
    if (-not $script:deviceOk) { throw 'refused: install before the phone was identified' }
    try { $res = Invoke-Adb @('install', '-r', '--user', '0', $apkPath) 'Success' }
    catch { $res = "$_" }
    if ($res -match 'INSTALL_FAILED_VERSION_DOWNGRADE') { Stop-Wp "downgrade refused by the phone ($res). Never uninstall: ask the user (README)" }
    if ($res -match 'INSTALL_FAILED_UPDATE_INCOMPATIBLE|signatures do not match|INSTALL_PARSE_FAILED_NO_CERTIFICATES|INCONSISTENT_CERTIFICATES') { Stop-Wp "signature mismatch ($res). Never uninstall: ask the user (README)" }
    if ($res -notmatch '(?m)^Success') { Stop-Wp "install did not succeed: $res" }
    $now = Read-Package $Pkg
    if (-not $DryRun) {
        if ($null -eq $now) { Stop-Wp "$Pkg is not there after the install" }
        if ($now.versionCode -ne $ExpectVersionCode) { Stop-Wp "versionCode after install is $($now.versionCode), not $ExpectVersionCode" }
        if ($now.u0Installed -ne 'true' -or -not $now.u0FirstInstallTime) { Stop-Wp "after the install user 0 has installed=$($now.u0Installed), firstInstallTime '$($now.u0FirstInstallTime)'" }
        if ($now.u0FirstInstallTime -ne $baseline.u0FirstInstallTime) { Stop-Wp "firstInstallTime changed ($($baseline.u0FirstInstallTime) -> $($now.u0FirstInstallTime)): the package was reinstalled, its data may be gone" }
        if ($now.u11Installed -ne $baseline.u11Installed) { Stop-Wp "user 11 (work profile) changed: installed=$($baseline.u11Installed) -> $($now.u11Installed). Never uninstall: ask the user (README)" }
        $relAfter = Read-Package $ReleasePkg
        if ((ConvertTo-Json $relBefore -Compress) -cne (ConvertTo-Json $relAfter -Compress)) { Stop-Wp "the release package changed during the install ($(ConvertTo-Json $relBefore -Compress) -> $(ConvertTo-Json $relAfter -Compress))" }
    }
    Write-Host "installed: versionCode $($now.versionCode), user 0 firstInstallTime $($now.u0FirstInstallTime) (unchanged), user 11 installed=$($now.u11Installed) (unchanged), release package unchanged"
    return [ordered]@{ apk = (Split-Path -Leaf $apkPath); sha256 = $(if (Test-Path -LiteralPath $apkPath) { (Get-FileHash -LiteralPath $apkPath -Algorithm SHA256).Hash.ToLower() } else { 'dry' }); versionCode = $now.versionCode; firstInstallTime = $now.u0FirstInstallTime; user11Installed = $now.u11Installed }
}

# ------------------------------------------------------------------ one run
# am's --esa splits at every comma (escape: none we rely on): refused, but
# in a --pref value, where self_test_pref.dart percent-decodes
function ConvertTo-EsaList([string[]]$argv) {
    $outList = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $argv.Count; $i++) {
        $a = $argv[$i]
        if ($i -gt 0 -and $argv[$i - 1] -eq '--pref') {
            $k, $v = $a -split '=', 2
            if ($null -ne $v) { $a = "$k=" + $v.Replace('%', '%25').Replace(',', '%2C') }
        }
        if ($a -eq '') { throw "an empty argument cannot go through --esa" }
        if ($a.Contains(',')) { throw "argument '$a' has a comma: am --esa would split it" }
        if ($a.Contains('\')) { throw "argument '$a' has a backslash: am --esa reads \, as an escape" }
        if ($a.Contains("'") -or $a.Contains("`n")) { throw "argument '$a' cannot go through the start script" }
        $outList.Add($a)
    }
    return ($outList -join ',')
}

function Start-AppRun([string[]]$argv, [string]$windowing = '') {
    $esa = ConvertTo-EsaList $argv
    $wm = if ($windowing) { " --windowingMode $windowing" } else { '' }
    $script = "am start --user 0 -W -n $Activity$wm --esa selftest_args '$esa'`n"
    if ($DryRun) {
        Write-Host "  [dry] start script: $($script.TrimEnd())"
        $null = Invoke-Adb @('push', '<the start script>', $PhoneScript)
        $null = Invoke-Shell "sh $(Q $PhoneScript)"
        $null = Invoke-Shell "rm -f $(Q $PhoneScript)"
        return
    }
    $script:adbLog.Add("  start script: $($script.TrimEnd())")
    # beside the reports (one scratch folder), removed after the push
    New-Item -ItemType Directory -Force -Path $Out | Out-Null
    $tmp = Join-Path $Out '_start.sh'
    try {
        [System.IO.File]::WriteAllText($tmp, $script, [System.Text.UTF8Encoding]::new($false))
        $null = Invoke-Adb @('push', $tmp, $PhoneScript)
        $r = Invoke-Change "sh $(Q $PhoneScript)" 'Status: ok'
        if ($r -match 'Error') { throw "am start: $r" }
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        try { $null = Invoke-Change "rm -f $(Q $PhoneScript)" } catch { Write-Warning "could not remove $PhoneScript`: $_" }
    }
}

function Read-PhoneJson([string]$path) {
    $t = Invoke-Shell "cat $(Q $path) 2>/dev/null || true" ''
    if (-not $t) { return $null }
    try { return $t | ConvertFrom-Json -AsHashtable } catch { return $null }
}

function Get-TaskId {
    $d = Invoke-Shell 'dumpsys activity activities' ''
    foreach ($l in ($d -split "`n")) { if ($l -match "Task\{[0-9a-f]+ #(\d+).*$([regex]::Escape($Pkg))") { return $Matches[1] } }
    return $null
}

# a test's host:ACTION
function Invoke-HostAction([string]$action, $saved) {
    switch -Regex ($action) {
        '^rotate:([0-3])$' { $null = Invoke-Change "settings put system user_rotation $($Matches[1])"; return }
        '^home$' { $null = Invoke-Change 'input keyevent KEYCODE_HOME'; return }
        '^front$' { $null = Invoke-Change "am start --user 0 -n $Activity"; return }
        '^(landscape|portrait)$' {
            $shape = $Matches[1]
            switch ($LandscapeMethod) {
                'wmsize' {
                    # a landscape-shaped display at rotation 0 (design §6.3 横屏的对照,
                    # 「假设」: the app's portrait request may turn it back; 6b decides)
                    if ($shape -eq 'landscape') { $null = Invoke-Change 'wm size 3040x1440' }
                    else { Set-WmSize $saved.wmSizeOverride }
                }
                'freeform' {
                    # the task (launched in freeform) resized to that shape
                    $id = Get-TaskId
                    if (-not $id -and -not $DryRun) { throw "host:$action`: no task of $Pkg found" }
                    $r = if ($shape -eq 'landscape') { '0 600 1440 1400' } else { '200 300 1240 2300' }
                    $null = Invoke-Change "cmd activity task resize $id $r"
                }
                default { throw "host:$action needs -LandscapeMethod freeform|wmsize (README: R8)" }
            }
            return
        }
        default { throw "host action '$action' is not one this script does" }
    }
}

# one cold-started self test: its report pulled to $localFile. Returns the
# run's record (runs.jsonl). $expect: the check names the report must hold.
# user_rotation and wm size are put back after it, whatever happened.
function Invoke-PhoneRun([string]$profileName, [string[]]$testArgs, [string]$localFile, [string[]]$expect, [int]$minutes, $saved, [string]$windowing = '') {
    Assert-Name $profileName 'profile'
    $stamp = Get-Date -Format 'yyyyMMddHHmmssfff'
    $base = "wp_${stamp}_$profileName"
    Assert-Name $base 'report name'
    $remote = "$PhoneFiles/$base.json"
    $files = "$(Q $remote) $(Q "$remote.progress") $(Q "$remote.host")"
    $argv = @('--selftest', '--profile', $profileName, '--out', $remote) + $testArgs
    $rec = [ordered]@{ profile = $profileName; remote = $remote; startedAt = (Get-Date).ToString('o'); expect = $expect; host = @() }
    $t0 = Get-Date
    try {
        $null = Invoke-Change "am force-stop --user 0 $Pkg"
        $null = Invoke-Change "rm -f $files"
        Set-Ack '0'
        Set-StayOn
        Wake-Phone
        Start-AppRun $argv $windowing
        if ($DryRun) {
            Write-Host "  [dry] (wait up to $minutes min for $remote, answering $remote.host; delete $localFile, pull it; rm the three files)"
            $rec.result = 'dry'
            return $rec
        }
        $deadline = $t0.AddMinutes($minutes)
        $lastN = 0
        $report = $null
        $deadFor = 0
        while ((Get-Date) -lt $deadline) {
            $h = Read-PhoneJson "$remote.host"
            if ($null -ne $h -and [int]$h['n'] -gt $lastN) {
                $lastN = [int]$h['n']
                $at = Get-Date
                Invoke-HostAction "$($h['action'])" $saved
                $token = "$($h['token'])"
                if ($token -cnotmatch '^selftest-wp[A-Za-z0-9_-]*:\d+$') { throw "host token '$token' is not one a run of this script writes" }
                Set-Ack $token
                $rec.host += @{ n = $lastN; action = "$($h['action'])"; token = $token; doneAt = $at.ToString('o') }
                Write-Host "    host:$($h['action']) done ($token)"
                continue
            }
            # finished = the phone's copy names finishedAt (the app writes the
            # whole report at once); it is read after the pull, as bytes:
            # adb's console text is decoded in the console's code page
            $fin = (Invoke-Shell "grep -c finishedAt $(Q $remote) 2>/dev/null || true" '').Trim()
            if ($fin -match '^[1-9]') { $report = 'finished'; break }
            $alive = (Invoke-Shell "pidof $Pkg || true" '').Trim()
            if (-not $alive) { $deadFor++ } else { $deadFor = 0 }
            if ($deadFor -ge 8) { break }
            Start-Sleep -Milliseconds 700
        }
        $rec.ms = [int]((Get-Date) - $t0).TotalMilliseconds
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $localFile) | Out-Null
        # the local copy deleted first: an old file must never be read as this run's
        foreach ($f in $localFile, "$localFile.progress") { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force } }
        $pulled = $true
        if ($null -ne $report) {
            try { $null = Invoke-Adb @('pull', $remote, $localFile) } catch { $pulled = $false; $rec.pullError = "$_" }
        } else {
            # what there is, beside: an unfinished report says how far it got
            if (Test-Path -LiteralPath "$localFile.unfinished") { Remove-Item -LiteralPath "$localFile.unfinished" -Force }
            try { $null = Invoke-Adb @('pull', $remote, "$localFile.unfinished") } catch { }
        }
        try { $null = Invoke-Adb @('pull', "$remote.progress", "$localFile.progress") } catch { }
        $null = Invoke-Change "rm -f $files"
        $null = Invoke-Change "am force-stop --user 0 $Pkg"
        if ($null -eq $report) {
            $rec.result = $(if ($deadFor -ge 8) { 'error: the app ended without a finished report (无结果)' } else { "error: no finished report in $minutes min (无结果)" })
            return $rec
        }
        if (-not $pulled -or -not (Test-Path -LiteralPath $localFile)) { $rec.result = 'error: the report could not be pulled (无结果)'; return $rec }
        try { $local = Get-Content -LiteralPath $localFile -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -DateKind String } catch { $local = $null; $rec.parseError = "$_" }
        if ($null -eq $local -or -not $local.Contains('finishedAt')) { $rec.result = 'error: the pulled report is not a finished report (无结果)'; return $rec }
        $names = @($local['checks'] | ForEach-Object { "$($_['name'])" })
        $missing = @($expect | Where-Object { $names -notcontains $_ })
        $rec.checks = $names
        $rec.checkPass = $local['pass']
        $rec.measured = [ordered]@{}
        foreach ($c in @($local['checks'])) { $rec.measured["$($c['name'])"] = $c['measured'] }
        $rec.result = $(if ($missing.Count) { "error: the report has no $($missing -join ', ') (it has $($names -join ', '))" } else { 'ok' })
        return $rec
    } finally {
        # what this run's host steps changed, put back whatever happened
        if ($null -ne $saved) { Restore-RunSettings $saved }
    }
}

function Invoke-Wipe([string[]]$names, [string]$localDir, $saved) {
    if (-not $names.Count) { return $null }
    foreach ($n in $names) { Assert-Name $n 'profile to wipe' }
    $argv = @(foreach ($n in $names) { '--wipe-profile'; $n })
    $f = Join-Path $localDir "wipe_$(Get-Date -Format 'HHmmssfff').json"
    $rec = Invoke-PhoneRun $WipeProfile $argv $f @('wipeProfiles') 3 $saved
    if ($rec.result -eq 'ok' -and -not $DryRun) {
        $rep = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json -AsHashtable
        $c = @($rep['checks'] | Where-Object { $_['name'] -eq 'wipeProfiles' })
        if (-not $c.Count -or $c[0]['pass'] -ne $true) { $rec.result = "error: the wipe did not delete them all: $(ConvertTo-Json $rep['checks'] -Compress -Depth 6)" }
    }
    if ($rec.result -ne 'ok' -and $rec.result -ne 'dry') { foreach ($n in $names) { $script:pendingWipe.Add($n) } }
    Write-Host "  wipe $($names -join ', '): $($rec.result)"
    return $rec
}

# ------------------------------------------------------------------ tables
function Read-AndroidTables {
    $set = Get-WpFieldTables $tablesDir
    $errs = [System.Collections.Generic.List[string]]::new()
    foreach ($t in $set.tables.Values) {
        $id = $t['id']
        if ($id -cnotmatch '^[A-Za-z0-9_-]+$') { $errs.Add("$id`: an id of letters, digits, - and _ (it goes into a profile name)") }
        if ($t['platform'] -ne 'android') { $errs.Add("$id`: platform must be android") }
        if ($t['mutants'] -ne 'none') { $errs.Add("$id`: mutants must be none (design §6.3: Android checks never go into the mutants)") }
        foreach ($f in @($t['fields'])) { if (@($f['expectedFor']).Where({ $_ }).Count) { $errs.Add("$id`: field $($f['name']) names a mutant") } }
        if (@($t['uiErrors']['expectedFor']).Where({ $_ }).Count) { $errs.Add("$id`: uiErrors names a mutant") }
        if ($null -ne $t['batch']) { $errs.Add("$id`: batch must be null (a phone covers none of the user's screens)") }
        if ("$($t['run']['profile'])" -ne 'fresh') { $errs.Add("$id`: run.profile must be fresh (a snapshot cannot reach the phone's private storage)") }
        foreach ($a in @($t['run']['args'])) { if ("$a" -match '^--window-size$|^--monitor$|\$\{') { $errs.Add("$id`: run.args '$a' is desktop only") } }
        $steps = "$(@($t['run']['args'])[([array]::IndexOf(@($t['run']['args']), '--wp-steps')) + 1])"
        foreach ($w in [regex]::Matches($steps, 'waitfor:([a-z]+)(@\d+)?')) {
            if ($steps -notmatch [regex]::Escape($w.Value) + ';require:' + $w.Groups[1].Value + '(;|$)') { $errs.Add("$id`: $($w.Value) is not followed by require:$($w.Groups[1].Value) (a timed-out wait must not leave a measured run)") }
        }
        $c = $t['control']
        if ($c -isnot [System.Collections.IDictionary]) { $errs.Add("$id`: no control (design §6.3 Android 检查的对照)"); continue }
        switch ($c['kind']) {
            'inRun' {
                if (@($c['pairs']).Count -eq 0) { $errs.Add("$id`: control.pairs is empty") }
                foreach ($p in @($c['pairs'])) { if (-not ($p['a'] -and $p['b'])) { $errs.Add("$id`: a control pair without a and b") } }
                foreach ($e in @($c['expect'] | Where-Object { $_ })) { if (-not $e['path'] -or -not $e.Contains('equals')) { $errs.Add("$id`: a control expect without path and equals") } }
            }
            'pair' {
                if (-not $c['with'] -or -not $c['path']) { $errs.Add("$id`: a pair control needs with and path") }
                elseif (-not $set.tables.Contains($c['with'])) { $errs.Add("$id`: control.with $($c['with']) is no table") }
            }
            default { $errs.Add("$id`: control.kind must be inRun or pair") }
        }
        $uses = $steps -match 'host:(landscape|portrait)'
        if ($uses -and -not $t['landscapeMethod']) { $errs.Add("$id`: uses host:landscape, so it says landscapeMethod: choose (README R8)") }
    }
    if ($errs.Count) { throw "Android field tables: $($errs -join '; ')" }
    return $set
}

function Get-RunArgsFor($t, $plan, [string]$profileName) {
    # run.ps1's own assembly (plan prefs, the table's, merged by key), then
    # the self-test's start (--selftest --profile --out) dropped: this
    # script adds its own with the phone's path
    $argv = Get-WpRunArgs $t $plan $profileName 'X' '' $root ''
    return , @($argv | Select-Object -Skip 5)
}

function Get-ProfileName([string]$sha, [int]$pass, [string]$id) { "wp-$($sha.Substring(0, 9))-p$pass-$id" }

# a path's value, or $null when the report does not have it (Get-WpValue
# answers @{ found; value })
function Get-Value($obj, [string]$path) {
    try { $r = Get-WpValue $obj $path } catch { return $null }
    if ($r.found) { return $r.value } else { return $null }
}

# a pass's check object: @{ check } or @{ why } (no report, unparseable, no
# such check, not measured)
function Get-CheckObj([string]$file, [string]$name) {
    if (-not (Test-Path -LiteralPath $file)) { return @{ why = 'no report' } }
    try { $rep = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json -AsHashtable } catch { return @{ why = 'unparseable report' } }
    if ($rep -isnot [System.Collections.IDictionary]) { return @{ why = 'unparseable report' } }
    $c = @($rep['checks'] | Where-Object { $_ -is [System.Collections.IDictionary] -and $_['name'] -eq $name })
    if (-not $c.Count) { return @{ why = "no check $name" } }
    if ($c[0]['measured'] -ne $true) { return @{ why = 'not measured' } }
    return @{ check = $c[0] }
}

# design §6.3 「Android 检查的对照」: a row for every requested table and pass
# (differ, 不灵敏, 无结果 with the reason); never skips, never throws
function Test-Controls($set, [string[]]$ids, [string]$sideDir) {
    $outRows = [System.Collections.Generic.List[object]]::new()
    $passes = @(if (Test-Path -LiteralPath $sideDir) { Get-ChildItem -LiteralPath $sideDir -Directory | Where-Object { $_.Name -match '^pass\d+$' } | Sort-Object { [int]($_.Name -replace '^pass', '') } })
    foreach ($pass in $passes) {
        $ran = $null
        $pj = Join-Path $pass.FullName 'pass.json'
        if (Test-Path -LiteralPath $pj) { try { $ran = @((Get-Content -LiteralPath $pj -Raw | ConvertFrom-Json -AsHashtable)['checks']) } catch { $ran = $null } }
        foreach ($id in $ids) {
            if ($null -ne $ran -and $ran -notcontains $id) { continue }
            $row = [ordered]@{ pass = $pass.Name; id = $id; verdict = '无结果'; why = $null; values = @() }
            try {
                $t = $set.tables[$id]
                $c = $t['control']
                $row.control = $c
                $self = Get-CheckObj (Join-Path $pass.FullName $t['report']) $t['check']
                if (-not $self.Contains('check')) { $row.why = "this table: $($self.why)" }
                else {
                    $comparisons = @()
                    if ($c['kind'] -eq 'pair') {
                        $o = $set.tables[$c['with']]
                        $other = Get-CheckObj (Join-Path $pass.FullName $o['report']) $o['check']
                        if (-not $other.Contains('check')) { $row.why = "partner $($c['with']): $($other.why)" }
                        else { $comparisons += , @{ a = $c['path']; b = "$($c['with']):$($c['path'])"; va = (Get-Value $self.check $c['path']); vb = (Get-Value $other.check $c['path']) } }
                    } else {
                        foreach ($p in @($c['pairs'])) { $comparisons += , @{ a = $p['a']; b = $p['b']; va = (Get-Value $self.check $p['a']); vb = (Get-Value $self.check $p['b']) } }
                    }
                    if (-not $row.why) {
                        $verdict = 'differ'
                        foreach ($x in $comparisons) {
                            $row.values += [ordered]@{ a = $x.a; b = $x.b; va = $x.va; vb = $x.vb }
                            if ($null -eq $x.va -or $null -eq $x.vb -or (Test-WpUnread $x.va) -or (Test-WpUnread $x.vb)) { $verdict = '无结果'; $row.why = "no value at $($x.a) / $($x.b)"; break }
                            if ((ConvertTo-WpCanon $x.va) -ceq (ConvertTo-WpCanon $x.vb)) { $verdict = '不灵敏'; $row.why = "$($x.a) = $($x.b)" }
                        }
                        if ($verdict -ne '无结果') {
                            foreach ($e in @($c['expect'] | Where-Object { $_ })) {
                                $v = Get-Value $self.check $e['path']
                                $row.values += [ordered]@{ path = $e['path']; equals = $e['equals']; value = $v }
                                if ($null -eq $v -or (Test-WpUnread $v)) { $verdict = '无结果'; $row.why = "no value at $($e['path'])"; break }
                                if ((ConvertTo-WpCanon $v) -cne (ConvertTo-WpCanon $e['equals'])) { $verdict = '不灵敏'; $row.why = "$($e['path']) is $(ConvertTo-WpCanon $v), not $(ConvertTo-WpCanon $e['equals'])" }
                            }
                        }
                        $row.verdict = $verdict
                    }
                }
            } catch { $row.verdict = '无结果'; $row.why = "control could not be read: $_" }
            $outRows.Add($row)
        }
    }
    if (-not $passes.Count) { foreach ($id in $ids) { $outRows.Add([ordered]@{ pass = $null; id = $id; verdict = '无结果'; why = 'no pass folder' }) } }
    $outRows | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $sideDir 'controls.json') -Encoding utf8NoBOM
    foreach ($r in $outRows) { Write-Host ("  control {0} {1}: {2}{3}" -f $r.pass, $r.id, $r.verdict, $(if ($r.why) { " ($($r.why))" } else { '' })) }
}

# ------------------------------------------------------------------ a side
function Get-Sha([string]$rev, [string]$what) {
    $s = git -C $root rev-parse --verify --quiet "$rev^{commit}" 2>$null
    if ($LASTEXITCODE -or -not $s) { throw "$what`: $rev is not a commit of this repository" }
    return "$s".Trim()
}

function Write-Manifest([string]$dir, [string]$sha, $install, $saved) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $mf = Join-Path $dir 'manifest.json'
    if (Test-Path -LiteralPath $mf) { return }
    $m = [ordered]@{
        plan = 'watch_page'; platform = 'android'; commit = $sha
        lib = (git -C $root rev-parse "${sha}:lib").Trim()
        fixtures = (git -C $root rev-parse "${sha}:test/fixtures").Trim()
        root = ''
        runner = (git -C $root hash-object (Join-Path $here 'wp_adb.ps1')).Trim()
        apk = $install
        device = [ordered]@{ serial = $Serial; serialNo = $PhoneSerialNo; model = $Model; sdk = "$($script:sdk)".Trim() }
        landscapeMethod = $LandscapeMethod
        phoneSettingsBefore = $saved
    }
    $m | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $mf -Encoding utf8NoBOM
}

function Get-PassCount([string]$dir) {
    if (-not (Test-Path -LiteralPath $dir)) { return 0 }
    $n = @(Get-ChildItem -LiteralPath $dir -Directory | Where-Object { $_.Name -match '^pass(\d+)$' } | ForEach-Object { [int]($_.Name -replace '^pass', '') })
    if (-not $n.Count) { return 0 }
    return ($n | Measure-Object -Maximum).Maximum
}

function Add-RunLine([string]$sideDir, $rec) {
    if ($DryRun) { return }
    ($rec | ConvertTo-Json -Compress -Depth 10) | Add-Content -LiteralPath (Join-Path $sideDir 'runs.jsonl') -Encoding utf8NoBOM
}

function Invoke-Pass($set, $plan, [string[]]$ids, [string]$sideDir, [string]$sha, [int]$passNo, $saved) {
    $passDir = Join-Path $sideDir "pass$passNo"
    if (-not $DryRun) {
        New-Item -ItemType Directory -Force -Path $passDir | Out-Null
        [ordered]@{ pass = $passNo; checks = $ids; started = (Get-Date).ToString('o') } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $passDir 'pass.json') -Encoding utf8NoBOM
    }
    $profiles = [System.Collections.Generic.List[string]]::new()
    $byReport = [ordered]@{}
    foreach ($id in $ids) { $t = $set.tables[$id]; if (-not $byReport.Contains($t['report'])) { $byReport[$t['report']] = $t } }
    try {
        foreach ($t in $byReport.Values) {
            $profileName = Get-ProfileName $sha $passNo $t['id']
            $profiles.Add($profileName)
            $argv = Get-RunArgsFor $t $plan $profileName
            $needsFree = $LandscapeMethod -eq 'freeform' -and $t['landscapeMethod']
            Write-Host "  pass $passNo $($t['id']) ($profileName)"
            $mins = if ($t['run']['minutes']) { [int]$t['run']['minutes'] } else { 10 }
            if ($needsFree) { Set-Freeform }
            try {
                $rec = Invoke-PhoneRun $profileName $argv (Join-Path $passDir $t['report']) @($t['check']) $mins $saved $(if ($needsFree) { '5' } else { '' })
            } finally {
                # the freeform globals only around this run
                if ($needsFree) { Restore-Freeform $saved }
            }
            $rec.passNo = $passNo; $rec.id = $t['id']; $rec.commit = $sha
            Add-RunLine $sideDir $rec
            Write-Host "    $($rec.result)"
        }
    } catch {
        # stopping: no wipe run now (the session puts the phone back first);
        # the profiles are listed for a later -Wipe
        foreach ($p in $profiles) { $script:pendingWipe.Add($p) }
        throw
    }
    if (-not $NoWipe) {
        $w = Invoke-Wipe $profiles.ToArray() $passDir $saved
        if ($null -ne $w) { Add-RunLine $sideDir $w }
    }
}

# ------------------------------------------------------------------ main
if ($CheckTables) {
    $set = Read-AndroidTables
    $plan = Read-WpPlan
    foreach ($t in $set.tables.Values) {
        $pn = Get-ProfileName '000000000' 1 $t['id']
        Assert-Name $pn 'profile'
        $argv = Get-RunArgsFor $t $plan $pn
        $null = ConvertTo-EsaList (@('--selftest', '--profile', 'x', '--out', 'y') + $argv)
        Write-Host ("{0,-28} {1,-9} control {2,-5} {3} fields" -f $t['id'], $t['type'], $t['control']['kind'], @($t['fields']).Count)
    }
    Write-Host "$($set.tables.Count) Android tables: loaded by run.ps1's Get-WpFieldTables, Android rules held (a require after every waitfor), every command line fits --esa"
    exit 0
}

if ($Controls) {
    $set = Read-AndroidTables
    if (-not $Checks.Count -or $Checks -contains 'all') { $Checks = @($set.tables.Keys) }
    foreach ($id in $Checks) { if (-not $set.tables.Contains($id)) { throw "no Android table $id" } }
    Test-Controls $set $Checks $Controls
    exit 0
}

$modes = @(@($Alternate, $Raw, [bool]$Wipe.Count, $ProbeRotation, [bool]($Checks.Count -and -not $Alternate)) | Where-Object { $_ })
if ($modes.Count -ne 1) { throw 'one of -Alternate, -Checks (one commit), -Raw, -Wipe, -ProbeRotation, -CheckTables' }
# the phone, before adb starts: only the Pixel's two names
if ($Serial -eq $OnePlus -or $Serial -like "*$OnePlus*") { Stop-Wp "serial $Serial is the OnePlus: never touched (design §6.3 哪台手机); adb was not started" }
if ($AllowedSerials -notcontains $Serial) { Stop-Wp "serial $Serial is not the Pixel 4 XL's ($($AllowedSerials -join ' or ')); adb was not started" }
if (-not $DryRun -and -not (Test-Path -LiteralPath $Adb)) { throw "no adb at $Adb" }
if ($FailAt -eq 'probe-after-rotation' -and -not $ProbeRotation) { throw '-FailAt probe-after-rotation goes with -ProbeRotation' }
if ($FailAt -eq 'raw-after-gate' -and -not $Raw) { throw '-FailAt raw-after-gate goes with -Raw' }

# every name checked before any phone command
Assert-Name $WipeProfile 'wipe profile'
if ($Raw) { Assert-Name $RawName '-RawName' }
foreach ($n in $Wipe) { Assert-Name $n '-Wipe name' }

$set = $null; $plan = $null; $pSha = $null; $nSha = $null; $sha = $null
if ($Alternate -or $Checks.Count) {
    $set = Read-AndroidTables
    $plan = Read-WpPlan
    if (-not $Checks.Count -or $Checks -contains 'all') { $Checks = @($set.tables.Keys) }
    foreach ($id in $Checks) { if (-not $set.tables.Contains($id)) { throw "no Android table $id" } }
    $needs = @($Checks | Where-Object { $set.tables[$_]['landscapeMethod'] })
    # the method the tables name (6b settled freeform), unless -LandscapeMethod says otherwise
    if ($needs.Count -and -not $LandscapeMethod) {
        $named = @($needs | ForEach-Object { "$($set.tables[$_]['landscapeMethod'])" } | Select-Object -Unique)
        if ($named.Count -eq 1 -and $named[0] -in 'freeform', 'wmsize') { $LandscapeMethod = $named[0]; Write-Host "landscape method: $LandscapeMethod (from the tables)" }
        else { throw "$($needs -join ', ') make the window landscape-shaped: pass -LandscapeMethod freeform|wmsize (README: R8)" }
    }
    if ($Alternate) {
        if (-not ($ParentApk -and $NewApk -and $Parent -and $Commit)) { throw '-Alternate needs -ParentApk, -Parent, -NewApk and -Commit' }
        $pSha = Get-Sha $Parent '-Parent'; $nSha = Get-Sha $Commit '-Commit'
        if ((git -C $root rev-parse "$nSha^").Trim() -ne $pSha) { throw "-Parent $pSha is not -Commit $nSha's parent" }
        $shas = @($pSha, $nSha)
    } else {
        if (-not $Commit) { throw '-Checks on one commit needs -Commit (the installed build''s, or -Apk''s)' }
        $sha = Get-Sha $Commit '-Commit'
        $shas = @($sha)
    }
    for ($p = 1; $p -le 99; $p++) { foreach ($s in $shas) { foreach ($id in $Checks) { Assert-Name (Get-ProfileName $s $p $id) 'profile' } } }
}
if (-not $Out) { $Out = Join-Path $root "_tmp\android\$(Get-Date -Format 'yyyyMMdd-HHmmss')" }

$saved = $null
$gateArmed = $false
$sessionDone = $false
$failure = $null
try {
    Assert-Device
    $saved = Read-PhoneSettings
    Write-Host "phone settings before: $(ConvertTo-Json $saved -Compress)"
    $baseline = Read-Package $Pkg
    Assert-Baseline $baseline
    Write-Host "dev package before: versionCode $($baseline.versionCode), user 0 installed=$($baseline.u0Installed) firstInstallTime $($baseline.u0FirstInstallTime), user 11 installed=$($baseline.u11Installed)"

    if ($ProbeRotation) {
        # the restore path, checked: user_rotation changed once (the cleanup restores)
        $null = Invoke-Change 'settings put system user_rotation 1'
        Write-Host "user_rotation now $(Read-Setting system user_rotation '1') (read back)"
        if ($FailAt -eq 'probe-after-rotation') { throw 'INJECTED FAILURE (-FailAt probe-after-rotation): user_rotation is 1' }
        Start-Sleep -Seconds 2
    }
    else {
    if ($saved.accelerometer_rotation -ne '0') { Set-Setting system accelerometer_rotation '0' }

    # armed before the write: a failure between setprop and its read-back
    # must still shut it
    $gateArmed = $true
    Set-Gate '1'
    if ($FailAt -eq 'raw-after-gate') { throw 'INJECTED FAILURE (-FailAt raw-after-gate): the gate is open' }

    if ($Raw) {
        if ($Apk) { $null = Install-DevApk $Apk $baseline }
        $dir = Join-Path $Out 'raw'
        $rec = Invoke-PhoneRun $RawName $SelfTestArgs (Join-Path $dir "$RawName.json") $ExpectChecks $RawMinutes $saved
        Write-Host "raw run: $($rec.result) (pulled to $dir)"
        if (-not $DryRun) { New-Item -ItemType Directory -Force -Path $dir | Out-Null; ($rec | ConvertTo-Json -Compress -Depth 10) | Add-Content -LiteralPath (Join-Path $dir 'runs.jsonl') -Encoding utf8NoBOM }
        if (-not $NoWipe) { $null = Invoke-Wipe @($RawName) $dir $saved }
    }
    elseif ($Wipe.Count) {
        $dir = Join-Path $Out 'wipe'
        if (-not $DryRun) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $null = Invoke-Wipe $Wipe $dir $saved
    }
    elseif ($Alternate) {
        $pDir = Join-Path $Out "parent-$($pSha.Substring(0, 9))"; $nDir = Join-Path $Out "new-$($nSha.Substring(0, 9))"
        # pass numbers from both sides: a session stopped between the parent's
        # pass N and the new side's pass N does not leave the new side without N
        $startAt = 1 + [Math]::Max((Get-PassCount $pDir), (Get-PassCount $nDir))
        for ($p = $startAt; $p -lt $startAt + $Passes; $p++) {
            # design §6.3 交替与 profile: parent, this step, parent, this step,
            # each pass on its own APK, installed over the other (same build number)
            $pi = Install-DevApk $ParentApk $baseline
            if (-not $DryRun) { Write-Manifest $pDir $pSha $pi $saved }
            Invoke-Pass $set $plan $Checks $pDir $pSha $p $saved
            $ni = Install-DevApk $NewApk $baseline
            if (-not $DryRun) { Write-Manifest $nDir $nSha $ni $saved }
            Invoke-Pass $set $plan $Checks $nDir $nSha $p $saved
        }
        if (-not $DryRun) { Test-Controls $set $Checks $pDir; Test-Controls $set $Checks $nDir }
        Write-Host "compare: pwsh -NoProfile -File test\mutants\run.ps1 -Plan watch_page -Compare $pDir,$nDir -FieldTables test\android\wp_fields -Out $Out\compare"
    }
    else {
        $install = if ($Apk) { Install-DevApk $Apk $baseline } else { [ordered]@{ apk = 'as installed'; versionCode = $baseline.versionCode; firstInstallTime = $baseline.u0FirstInstallTime; user11Installed = $baseline.u11Installed } }
        $sDir = Join-Path $Out $sha.Substring(0, 9)
        if (-not $DryRun) { Write-Manifest $sDir $sha $install $saved }
        $startAt = 1 + (Get-PassCount $sDir)
        for ($p = $startAt; $p -lt $startAt + $Passes; $p++) { Invoke-Pass $set $plan $Checks $sDir $sha $p $saved }
        if (-not $DryRun) { Test-Controls $set $Checks $sDir }
        Write-Host "calibrate: pwsh -NoProfile -File test\mutants\run.ps1 -Plan watch_page -Compare $sDir -FieldTables test\android\wp_fields -Out $Out\calibration"
    }
    }
    $sessionDone = $true
} catch {
    $failure = $_
} finally {
    # only on the identified phone; first the gate and the settings, then
    # the rest; each on its own
    if ($script:deviceOk) {
        if ($gateArmed) {
            try { Set-Gate '0' } catch { $script:restoreFailures.Add("THE SELFTEST GATE MAY BE OPEN ($_): adb -s $Serial shell setprop debug.librepili.selftest 0") }
        }
        try {
            Set-Ack '0'
            $ack = Get-Prop 'debug.librepili.ack' '0'
            if ($ack -ne '0' -and $ack -ne '') { $script:restoreFailures.Add("debug.librepili.ack read back '$ack', not 0") }
        } catch { $script:restoreFailures.Add("ack reset: $_") }
        if ($null -ne $saved) { Restore-AllSettings $saved }
        try { $null = Invoke-Change "am force-stop --user 0 $Pkg" } catch { $script:restoreFailures.Add("force-stop: $_") }
    }
    # every adb command of this session, beside its reports
    if ($script:adbLog.Count -and -not $DryRun) {
        New-Item -ItemType Directory -Force -Path $Out | Out-Null
        $script:adbLog | Add-Content -LiteralPath (Join-Path $Out 'adb.log') -Encoding utf8NoBOM
    }
}
if ($script:pendingWipe.Count) { Write-Warning "profiles left on the phone (run -Wipe $(@($script:pendingWipe | Select-Object -Unique) -join ',') once the phone is fine)" }
if ($script:restoreFailures.Count) { Write-Warning "PUT BACK BY HAND (README 「停下时」): $($script:restoreFailures -join '; ')" }
if ($null -ne $failure) {
    Write-Host "stopped: $($failure.Exception.Message)" -ForegroundColor Red
    exit 1
}
if ($script:restoreFailures.Count) { exit 2 }
exit 0
