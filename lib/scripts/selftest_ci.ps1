# Runs the built app's offline self-test (`--selftest --ci-smoke`, see
# lib/utils/self_test.dart) and fails when any check in it failed.
#
# The app writes its own report and exits 0 only when every check passed,
# but a CI step cannot take that alone as the answer: a build that crashes
# before the report is written, or hangs on a runner with no desktop, has
# to fail too. So the exit code, the report's own verdict and the report
# being finished at all are each checked, and a hang is cut off by
# -TimeoutSec.
#
#   pwsh lib/scripts/selftest_ci.ps1 -Exe build/.../LibrePili.exe -Out selftest.json
#   pwsh lib/scripts/selftest_ci.ps1 -Exe xvfb-run -LauncherArgs '-a','bundle/librepili' -Out selftest.json
param(
    [Parameter(Mandatory)] [string]$Exe,
    [string[]]$LauncherArgs = @(),
    [Parameter(Mandatory)] [string]$Out,
    [int]$TimeoutSec = 600
)

$ErrorActionPreference = "Stop"
$Out = [System.IO.Path]::GetFullPath($Out)
Remove-Item -Force -ErrorAction SilentlyContinue $Out

# Start-Process joins the list with spaces and quotes nothing, so an
# argument with a space in it (a path, xvfb-run's '-screen 0 WxHxD') is
# quoted here or it arrives as several
$argv = @($LauncherArgs) + @('--selftest', '--ci-smoke', '--profile', 'ci', '--out', $Out) |
    ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } }
Write-Host "running: $Exe $($argv -join ' ')"
$clock = [System.Diagnostics.Stopwatch]::StartNew()
$proc = Start-Process -FilePath $Exe -ArgumentList $argv -PassThru
# the handle has to be touched before exit, or ExitCode reads empty for a
# process that has already gone (a .NET quirk of Start-Process -PassThru)
$null = $proc.Handle
$finished = $proc.WaitForExit($TimeoutSec * 1000)
if (-not $finished) {
    Write-Host "::error::self-test still running after $TimeoutSec s; killed"
    $proc.Kill($true)
}
$code = if ($finished) { $proc.ExitCode } else { $null }
Write-Host "exit code: $code after $([int]$clock.Elapsed.TotalSeconds) s"

$failures = @()
if (-not $finished) { $failures += "timed out" }
elseif ($code -ne 0) { $failures += "exit code $code" }

$report = $null
if (-not (Test-Path $Out)) {
    $failures += "no report written (the app never started)"
} else {
    $report = Get-Content -Raw $Out | ConvertFrom-Json
    if ($report.stage) {
        # only the markers a run leaves before its checks: 'started', or
        # 'error' when storage could not open
        $failures += "report stopped at stage '$($report.stage)': $($report.error)"
    } elseif (-not $report.finishedAt) {
        $failures += "report not finished"
    }
    $checks = @($report.checks)
    if ($report.finishedAt -and $checks.Count -eq 0) {
        $failures += "no checks ran"
    }
    foreach ($check in $checks) {
        $state = if ($check.pass -eq $true) { "PASS" } else { "FAIL" }
        Write-Host ("{0,-4} {1,-20} {2,7} ms" -f $state, $check.name, $check.ms)
        if ($check.pass -ne $true) {
            $failures += "check '$($check.name)' failed"
            # everything the check said, since which field is wrong differs
            # from one check to the next
            $check | ConvertTo-Json -Depth 6 | Write-Host
        }
    }
    if ($report.finishedAt -and $report.pass -ne $true -and $failures.Count -eq 0) {
        $failures += "report says pass=$($report.pass)"
    }
}

if ($failures.Count -gt 0) {
    foreach ($f in $failures) { Write-Host "::error::self-test: $f" }
    exit 1
}
Write-Host "self-test passed: $(@($report.checks).Count) checks"
