#Requires -Version 5.1

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$commandPath = Join-Path $projectRoot 'scoop-upgrade.ps1'
$fixturePath = Join-Path $PSScriptRoot 'fixtures/fake-scoop.ps1'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) "scoop-resilient-upgrade-$PID-$([Guid]::NewGuid().ToString('N'))"
$logPath = Join-Path $tempRoot 'calls.log'
$hostExecutable = (Get-Process -Id $PID).Path

function Assert-Equal {
    param($Expected, $Actual, [string] $Message)

    if ($Expected -ne $Actual) {
        throw "$Message`nExpected: $Expected`nActual:   $Actual"
    }
}

function Assert-Contains {
    param([string] $Text, [string] $Expected, [string] $Message)

    if (!$Text.Contains($Expected)) {
        throw "$Message`nMissing: $Expected`nOutput:`n$Text"
    }
}

function Assert-Sequence {
    param([string[]] $Expected, [string[]] $Actual, [string] $Message)

    Assert-Equal ($Expected -join '|') ($Actual -join '|') $Message
}

function New-FakeScoopCommand {
    if ($env:OS -eq 'Windows_NT') {
        $wrapperPath = Join-Path $tempRoot 'scoop.cmd'
        @(
            '@echo off'
            "`"$hostExecutable`" -NoProfile -File `"$fixturePath`" %*"
            'exit /b %ERRORLEVEL%'
        ) | Set-Content -LiteralPath $wrapperPath -Encoding ASCII
        return $wrapperPath
    }

    $wrapperPath = Join-Path $tempRoot 'scoop'
    @(
        '#!/bin/sh'
        "exec '$hostExecutable' -NoProfile -File '$fixturePath' `"`$@`""
    ) | Set-Content -LiteralPath $wrapperPath -Encoding ASCII
    & chmod +x $wrapperPath
    if ($LASTEXITCODE -ne 0) {
        throw "Could not make the fake Scoop command executable."
    }
    return $wrapperPath
}

function Invoke-Scenario {
    param(
        [AllowEmptyString()]
        [string] $FailApp,
        [bool] $ExportFailure = $false,
        [bool] $SyncFailure = $false,
        [string] $Apps = '',
        [ValidateSet('', 'true', 'false')]
        [string] $IsAdministrator = '',
        [string] $ElevationResponse = '',
        [ValidateSet('', 'Canceled', 'Failed')]
        [string] $ElevationState = '',
        [bool] $ElevationBypass = $false,
        [switch] $NoElevationPrompt,
        [string[]] $CommandOptions = @('-a')
    )

    if (Test-Path -LiteralPath $logPath) {
        Remove-Item -LiteralPath $logPath -Force
    }
    $env:SCOOP_RESILIENT_TEST_FAIL_APP = $FailApp
    $env:SCOOP_RESILIENT_TEST_EXPORT_FAILURE = $ExportFailure.ToString().ToLowerInvariant()
    $env:SCOOP_RESILIENT_TEST_SYNC_FAILURE = $SyncFailure.ToString().ToLowerInvariant()
    $env:SCOOP_RESILIENT_TEST_APPS = $Apps
    $env:SCOOP_RESILIENT_TEST_IS_ADMINISTRATOR = $IsAdministrator
    $env:SCOOP_RESILIENT_TEST_ELEVATION_RESPONSE = $ElevationResponse
    $env:SCOOP_RESILIENT_TEST_ELEVATION_STATE = $ElevationState
    $env:SCOOP_RESILIENT_TEST_ELEVATION_BYPASS = $ElevationBypass.ToString().ToLowerInvariant()

    $commandArguments = @('-NoProfile', '-File', $commandPath) + $CommandOptions
    if ($NoElevationPrompt) {
        $commandArguments += '-NoElevationPrompt'
    }
    if ('*' -in $CommandOptions) {
        # PowerShell 7.6 on Unix expands native wildcard arguments. Feed literal
        # argv directly when testing Scoop's Windows wildcard command syntax.
        $start = New-Object Diagnostics.ProcessStartInfo
        $start.FileName = $hostExecutable
        $start.UseShellExecute = $false
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        if ($start.PSObject.Properties.Name -contains 'ArgumentList') {
            foreach ($argument in $commandArguments) { [void]$start.ArgumentList.Add($argument) }
        } else { $start.Arguments = ($commandArguments | ForEach-Object { '"' + $_ + '"' }) -join ' ' }
        $process = [Diagnostics.Process]::Start($start)
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $output = @($stdout.Result, $stderr.Result)
        $exitCode = $process.ExitCode
        $process.Dispose()
    } else {
        $output = @(& $hostExecutable @commandArguments 2>&1)
        $exitCode = $LASTEXITCODE
    }

    return [PSCustomObject]@{
        ExitCode = $exitCode
        Output = $output -join [Environment]::NewLine
        Calls = @(Get-Content -LiteralPath $logPath)
    }
}

$previousCore = $env:SCOOP_RESILIENT_TEST_CORE
$previousWorkerLog = $env:SCOOP_RESILIENT_TEST_WORKER_LOG
$previousStatusError = $env:SCOOP_RESILIENT_TEST_STATUS_ERROR
$previousCommand = $env:SCOOP_UPGRADE_SCOOP_COMMAND
$previousToolsCommand = $env:SCOOP_RESILIENT_SCOOP_COMMAND
$previousNativeScoop = $env:SCOOP_RESILIENT_TEST_NATIVE_SCOOP
$previousGlobalApps = $env:SCOOP_RESILIENT_TEST_GLOBAL_APPS
$previousLog = $env:SCOOP_RESILIENT_TEST_LOG
$previousFailApp = $env:SCOOP_RESILIENT_TEST_FAIL_APP
$previousExportFailure = $env:SCOOP_RESILIENT_TEST_EXPORT_FAILURE
$previousSyncFailure = $env:SCOOP_RESILIENT_TEST_SYNC_FAILURE
$previousApps = $env:SCOOP_RESILIENT_TEST_APPS
$previousIsAdministrator = $env:SCOOP_RESILIENT_TEST_IS_ADMINISTRATOR
$previousElevationResponse = $env:SCOOP_RESILIENT_TEST_ELEVATION_RESPONSE
$previousElevationState = $env:SCOOP_RESILIENT_TEST_ELEVATION_STATE
$previousElevationBypass = $env:SCOOP_RESILIENT_TEST_ELEVATION_BYPASS

New-Item -ItemType Directory -Path $tempRoot | Out-Null
try {
    $env:SCOOP_UPGRADE_SCOOP_COMMAND = New-FakeScoopCommand
    $env:SCOOP_RESILIENT_SCOOP_COMMAND = $env:SCOOP_UPGRADE_SCOOP_COMMAND
    $env:SCOOP_RESILIENT_TEST_NATIVE_SCOOP = ''
    $env:SCOOP_RESILIENT_TEST_GLOBAL_APPS = ''
    $env:SCOOP_RESILIENT_TEST_LOG = $logPath
    $env:SCOOP_RESILIENT_TEST_CORE = Join-Path $tempRoot 'core'
    New-Item -ItemType Directory -Path (Join-Path $env:SCOOP_RESILIENT_TEST_CORE 'lib') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures/plan-core.ps1') -Destination (Join-Path $env:SCOOP_RESILIENT_TEST_CORE 'lib/core.ps1')
    $env:SCOOP_RESILIENT_TEST_WORKER_LOG = Join-Path $tempRoot 'workers.log'
    $env:SCOOP_RESILIENT_TEST_STATUS_ERROR = ''

    $partialFailure = Invoke-Scenario -FailApp 'broken'
    Assert-Equal 1 $partialFailure.ExitCode 'A failed app should produce aggregate exit code 1.'
    Assert-Sequence @('config last_update', 'update', 'export', 'prefix scoop', 'update broken', 'update healthy', 'update damaged') $partialFailure.Calls 'A failed app must not prevent the next app update.'
    Assert-Contains $partialFailure.Output 'Completed: 2' 'The summary should count successful updates.'
    Assert-Contains $partialFailure.Output 'Failed: 1' 'The summary should count failed updates.'
    Assert-Contains $partialFailure.Output 'Skipped: 1' 'The summary should count held apps while delegating repair to Scoop.'
    Assert-Contains $partialFailure.Output 'broken [Download] (exit 23)' 'The summary should classify download failures.'
    Assert-Contains $partialFailure.Output '(404) Not Found' 'The summary should retain the useful failure reason.'

    $success = Invoke-Scenario -FailApp ''
    Assert-Equal 0 $success.ExitCode 'All successful app commands should produce exit code 0.'
    Assert-Sequence @('config last_update', 'update', 'export', 'prefix scoop', 'update broken', 'update healthy', 'update damaged') $success.Calls 'Eligible apps should be updated exactly once.'
    Assert-Contains $success.Output 'Completed: 3' 'The successful summary should include all eligible apps.'
    Assert-Contains $success.Output 'Failed: 0' 'The successful summary should contain no failures.'

    $syncFailure = Invoke-Scenario -FailApp '' -SyncFailure $true
    Assert-Equal 1 $syncFailure.ExitCode 'A synchronization failure should produce aggregate exit code 1.'
    Assert-Sequence @('config last_update', 'update', 'export', 'prefix scoop', 'update broken', 'update healthy', 'update damaged') $syncFailure.Calls 'A synchronization failure must not prevent app updates.'
    Assert-Contains $syncFailure.Output 'Completed: 3' 'Apps should still complete after synchronization fails.'
    Assert-Contains $syncFailure.Output 'Failed: 1' 'The synchronization failure should appear in the summary.'

    $exportFailure = Invoke-Scenario -FailApp '' -ExportFailure $true
    Assert-Equal 2 $exportFailure.ExitCode 'An unusable Scoop export should produce setup exit code 2.'
    Assert-Sequence @('config last_update', 'update', 'export') $exportFailure.Calls 'No app should run when discovery fails.'

    $classified = Invoke-Scenario -FailApp '' -Apps 'running,current,missing,unsupported,admin-warning,hash-fail,locked,installer-fail,permission-fail,unknown-fail,healthy'
    Assert-Equal 1 $classified.ExitCode 'Classified failures should produce aggregate exit code 1.'
    Assert-Contains $classified.Output 'running [Running]' 'A zero-exit running process should be reported as skipped.'
    Assert-Contains $classified.Output 'current [Current]' 'An already-current package should not be reported as upgraded.'
    Assert-Contains $classified.Output 'missing [Manifest]' 'A zero-exit missing manifest should be reported as failed.'
    Assert-Contains $classified.Output 'unsupported [Architecture]' 'A zero-exit unsupported architecture should be reported as failed.'
    Assert-Contains $classified.Output 'admin-warning [Success]' 'A harmless admin-permission warning should not turn a successful update into a failure.'
    Assert-Contains $classified.Output 'hash-fail [Hash] (exit 24)' 'Hash failures should be classified.'
    Assert-Contains $classified.Output 'locked [InUse] (exit 25)' 'Locked files should be classified.'
    Assert-Contains $classified.Output 'installer-fail [Installer] (exit 26)' 'Installer failures should be classified.'
    Assert-Contains $classified.Output 'permission-fail [Permission] (exit 27)' 'Permission failures should be classified without automatic elevation.'
    Assert-Contains $classified.Output 'unknown-fail [Unknown] (exit 28)' 'Unrecognized failures should retain an unknown category.'
    Assert-Contains $classified.Output 'Current: 1' 'The summary should count already-current packages separately.'
    Assert-Contains $classified.Output 'Failed: 7' 'The summary should count all classified failures.'
    Assert-Contains $classified.Output 'Skipped: 1' 'The running package should be counted as skipped.'

    $inlineHook = Invoke-Scenario -FailApp '' -Apps 'clash-verge-rev,copyq,healthy'
    Assert-Equal 1 $inlineHook.ExitCode 'A zero-exit embedded hook error must make the aggregate fail.'
    Assert-Contains $inlineHook.Output 'clash-verge-rev [Elevation]' 'Missing administrator privileges should be an elevation failure.'
    Assert-Contains $inlineHook.Output 'copyq [Running]' 'A running app should remain skipped.'
    Assert-Contains $inlineHook.Output 'healthy [Success]' 'A hook failure must not stop later app workers.'
    Assert-Contains $inlineHook.Output 'Failed: 1' 'The failed hook must be counted accurately.'

    $elevationDisabled = Invoke-Scenario -FailApp '' -Apps 'healthy,global-one,global-two' -IsAdministrator false -NoElevationPrompt -CommandOptions @('-ag')
    Assert-Equal 0 $elevationDisabled.ExitCode 'Skipped global apps should not make a non-elevated run fail.'
    Assert-Sequence @('config last_update', 'update', 'export', 'prefix scoop', 'update healthy') $elevationDisabled.Calls 'Disabled elevation should leave global apps untouched.'
    Assert-Contains $elevationDisabled.Output 'Skipped: 2' 'Both global apps should be summarized as skipped.'
    Assert-Contains $elevationDisabled.Output 'elevation prompt was disabled' 'The summary should explain why global apps were skipped.'

    $elevationDeclined = Invoke-Scenario -FailApp '' -Apps 'global-one,global-two' -IsAdministrator false -ElevationResponse 'n' -CommandOptions @('-ag')
    Assert-Equal 0 $elevationDeclined.ExitCode 'Declining elevation should be a successful partial run.'
    Assert-Sequence @('config last_update', 'update', 'export', 'prefix scoop') $elevationDeclined.Calls 'Declining elevation should not invoke global updates.'
    Assert-Contains $elevationDeclined.Output 'Administrator retry was declined.' 'The summary should record a declined elevation prompt.'

    $elevationCanceled = Invoke-Scenario -FailApp '' -Apps 'global-one,global-two' -IsAdministrator false -ElevationResponse 'y' -ElevationState Canceled -CommandOptions @('-ag')
    Assert-Equal 0 $elevationCanceled.ExitCode 'Canceling UAC should leave global apps skipped rather than failed.'
    Assert-Sequence @('config last_update', 'update', 'export', 'prefix scoop') $elevationCanceled.Calls 'Canceling UAC should not invoke global updates.'
    Assert-Contains $elevationCanceled.Output 'global-one (global) [ElevationCanceled]' 'Canceled UAC should have a distinct category.'

    $elevationFailed = Invoke-Scenario -FailApp '' -Apps 'global-one,global-two' -IsAdministrator false -ElevationResponse 'y' -ElevationState Failed -CommandOptions @('-ag')
    Assert-Equal 1 $elevationFailed.ExitCode 'An unavailable elevated worker should make the accepted retry fail clearly.'
    Assert-Sequence @('config last_update', 'update', 'export', 'prefix scoop') $elevationFailed.Calls 'An elevation launch failure should not invoke global updates.'
    Assert-Contains $elevationFailed.Output 'global-one (global) [ElevationFailed]' 'Elevation launch failures should have a distinct category.'

    $elevatedSuccess = Invoke-Scenario -FailApp '' -Apps 'healthy,global-one,global-two' -IsAdministrator false -ElevationResponse 'y' -ElevationBypass $true -CommandOptions @('-ag')
    Assert-Equal 0 $elevatedSuccess.ExitCode 'A successful elevated batch should produce exit code 0.'
    Assert-Sequence @('config last_update', 'update', 'export', 'prefix scoop', 'update healthy', 'update global-one --global', 'update global-two --global') $elevatedSuccess.Calls 'One worker should update all deferred global apps in order.'
    Assert-Contains $elevatedSuccess.Output 'Completed: 3' 'Elevated successes should merge into the parent summary.'
    Assert-Contains $elevatedSuccess.Output 'global-one (global) [Success]' 'Elevated results should retain global labels.'

    $elevatedPartialFailure = Invoke-Scenario -FailApp 'global-one' -Apps 'global-one,global-two' -IsAdministrator false -ElevationResponse 'y' -ElevationBypass $true -CommandOptions @('-ag')
    Assert-Equal 1 $elevatedPartialFailure.ExitCode 'An elevated app failure should affect the aggregate exit code.'
    Assert-Sequence @('config last_update', 'update', 'export', 'prefix scoop', 'update global-one --global', 'update global-two --global') $elevatedPartialFailure.Calls 'An elevated app failure must not prevent later global updates.'
    Assert-Contains $elevatedPartialFailure.Output 'global-one (global) [Download] (exit 23)' 'Elevated failures should preserve their classification.'
    Assert-Contains $elevatedPartialFailure.Output 'global-two (global) [Success]' 'Later elevated apps should still complete.'

    $alreadyElevated = Invoke-Scenario -FailApp '' -Apps 'healthy,global-one,global-two' -IsAdministrator true -CommandOptions @('-ag')
    Assert-Equal 0 $alreadyElevated.ExitCode 'An already-elevated run should update all apps directly.'
    Assert-Sequence @('config last_update', 'update', 'export', 'prefix scoop', 'update healthy', 'update global-one --global', 'update global-two --global') $alreadyElevated.Calls 'An elevated parent should not defer global apps to another worker.'
    Assert-Contains $alreadyElevated.Output 'Completed: 3' 'Direct global successes should be included in the summary.'

    $syncOnly = Invoke-Scenario -FailApp '' -CommandOptions @()
    Assert-Equal 0 $syncOnly.ExitCode 'No arguments should synchronize only.'
    Assert-Sequence @('update') $syncOnly.Calls 'No-argument upgrade must mimic update.'

    $selected = Invoke-Scenario -FailApp 'broken' -CommandOptions @('broken', 'healthy', 'broken', '-fiqks')
    Assert-Equal 1 $selected.ExitCode 'Selected app failures should aggregate.'
    Assert-Sequence @('config last_update', 'update', 'export', 'prefix scoop', 'update broken --force --independent --quiet --no-cache --skip-hash-check', 'update healthy --force --independent --quiet --no-cache --skip-hash-check') $selected.Calls 'Explicit selection, deduplication and forwarding must preserve scope.'

    $localOnly = Invoke-Scenario -FailApp '' -Apps 'healthy,global-one' -IsAdministrator true
    Assert-Sequence @('config last_update', 'update', 'export', 'prefix scoop', 'update healthy') $localOnly.Calls 'All without -g must select only local apps, even as administrator.'

    $globalOnly = Invoke-Scenario -FailApp '' -Apps 'healthy,global-one' -IsAdministrator true -CommandOptions @('-g', 'global-one', '-f')
    Assert-Sequence @('config last_update', 'update', 'export', 'prefix scoop', 'update global-one --force --global') $globalOnly.Calls 'Explicit -g must select only that global app.'

    $env:SCOOP_RESILIENT_TEST_FRESH = 'true'
    try {
        $fresh = Invoke-Scenario -FailApp '' -CommandOptions @('healthy')
        Assert-Sequence @('config last_update', 'export', 'prefix scoop', 'update healthy') $fresh.Calls 'A fresh Scoop installation must not be synchronized unconditionally.'
    } finally { Remove-Item Env:SCOOP_RESILIENT_TEST_FRESH -ErrorAction SilentlyContinue }

    $zeroErrors = Invoke-Scenario -FailApp '' -Apps 'missing-current,stderr-success,healthy'
    Assert-Equal 1 $zeroErrors.ExitCode 'A later current message must not hide a manifest error.'
    Assert-Contains $zeroErrors.Output 'missing-current [Manifest]' 'Zero-exit errors should stay failed.'
    Assert-Contains $zeroErrors.Output 'Finished after stderr.' 'Successful stderr must not interrupt draining child output.'
    Assert-Contains $zeroErrors.Output 'healthy [Success]' 'Later apps should run after zero-exit failures.'

    $scoopOnly = Invoke-Scenario -FailApp '' -CommandOptions @('scoop')
    Assert-Sequence @('update') $scoopOnly.Calls 'Explicit scoop should synchronize without exporting apps.'

    $wildcard = Invoke-Scenario -FailApp '' -Apps 'healthy,global-one' -CommandOptions @('*')
    Assert-Sequence @('config last_update', 'update', 'export', 'prefix scoop', 'update healthy') $wildcard.Calls 'Wildcard must match --all local selection.'
    $qualified = Invoke-Scenario -FailApp '' -CommandOptions @('main/healthy@1.0', 'healthy')
    Assert-Sequence @('config last_update', 'update', 'export', 'prefix scoop', 'update healthy') $qualified.Calls 'Qualified names should be normalized and deduplicated as in update.'
    $missingTarget = Invoke-Scenario -FailApp '' -Apps 'healthy' -CommandOptions @('absent', 'healthy')
    Assert-Equal 1 $missingTarget.ExitCode 'Missing explicit apps should produce a failure exit code.'
    Assert-Contains $missingTarget.Output 'healthy [Success]' 'A missing target must not block installed targets.'
    $fatal = Invoke-Scenario -FailApp '' -Apps 'fatal-current,healthy'
    Assert-Equal 1 $fatal.ExitCode 'Zero-exit fatal git errors must not be reported as current.'
    Assert-Contains $fatal.Output 'healthy [Success]' 'Fatal diagnostics must not block later apps.'
    $jsonName = Invoke-Scenario -FailApp '' -Apps 'healthy,healthy.json' -CommandOptions @('healthy.json', 'https://example.invalid/healthy.json')
    Assert-Equal 1 $jsonName.ExitCode 'A URL is not an installed-app selector.'
    Assert-Sequence @('config last_update', 'update', 'export', 'prefix scoop', 'update healthy.json') $jsonName.Calls 'Installed names ending in .json must not select a different app.'

    Remove-Item -LiteralPath $env:SCOOP_RESILIENT_TEST_WORKER_LOG -ErrorAction SilentlyContinue
    $manyCurrent = (1..200 | ForEach-Object { "current-$_" }) -join ','
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $idle = Invoke-Scenario -FailApp '' -Apps $manyCurrent
    $timer.Stop()
    Assert-Equal 0 $idle.ExitCode 'An entirely current selection should succeed.'
    Assert-Sequence @('config last_update', 'update', 'export', 'prefix scoop') $idle.Calls 'Current apps must launch no individual updates.'
    Assert-Sequence @('preflight upgrade') @(Get-Content -LiteralPath $env:SCOOP_RESILIENT_TEST_WORKER_LOG) 'The whole selection must use one preflight process.'
    Assert-Contains $idle.Output 'Current: 200' 'Filtered apps must still appear in summary counts.'
    Write-Host "200 current apps: one preflight, zero update workers, $($timer.ElapsedMilliseconds) ms."

    $mixed = Invoke-Scenario -FailApp 'broken' -Apps 'current-one,broken,healthy,current-two'
    Assert-Sequence @('config last_update', 'update', 'export', 'prefix scoop', 'update broken', 'update healthy') $mixed.Calls 'Only outdated apps should launch workers and a failure must not block later jobs.'
    Assert-Contains $mixed.Output 'Current: 2' 'Mixed current apps should remain in the summary.'

    $forced = Invoke-Scenario -FailApp '' -Apps 'current-one,held' -CommandOptions @('-af')
    Assert-Sequence @('config last_update', 'update', 'export', 'prefix scoop', 'update current-one --force') $forced.Calls 'Force must include current apps but preserve holds.'

    $env:SCOOP_RESILIENT_TEST_STATUS_ERROR = 'current-one'
    try {
        $unknown = Invoke-Scenario -FailApp '' -Apps 'current-one,healthy'
        Assert-Sequence @('config last_update', 'update', 'export', 'prefix scoop', 'update current-one', 'update healthy') $unknown.Calls 'Inconclusive status must be diagnosed by a worker.'
    } finally { $env:SCOOP_RESILIENT_TEST_STATUS_ERROR = '' }

    $globalCurrent = Invoke-Scenario -FailApp '' -Apps 'global-current-one' -IsAdministrator false -ElevationResponse 'y' -ElevationState Failed -CommandOptions @('-ag')
    Assert-Equal 0 $globalCurrent.ExitCode 'Current global apps must not require elevation.'
    Assert-Sequence @('config last_update', 'update', 'export', 'prefix scoop') $globalCurrent.Calls 'Current globals must launch no worker.'

    $corePath = Join-Path $env:SCOOP_RESILIENT_TEST_CORE 'lib/core.ps1'
    $coreText = Get-Content -LiteralPath $corePath -Raw
    try {
        Set-Content -LiteralPath $corePath -Value "throw 'Injected planner failure'"
        $fallback = Invoke-Scenario -FailApp '' -Apps 'current,healthy'
        Assert-Equal 0 $fallback.ExitCode 'A failed planner must fall back to isolated app workers.'
        Assert-Sequence @('config last_update', 'update', 'export', 'prefix scoop', 'update current', 'update healthy') $fallback.Calls 'Planner failure must not hide selected apps.'
        Assert-Contains $fallback.Output 'Preflight unavailable' 'Planner fallback should explain its reason.'
    } finally { Set-Content -LiteralPath $corePath -Value $coreText }

    Write-Host 'All scoop-upgrade integration tests passed.' -ForegroundColor Green
} finally {
    $environment = @{
        SCOOP_RESILIENT_TEST_CORE = $previousCore
        SCOOP_RESILIENT_TEST_WORKER_LOG = $previousWorkerLog
        SCOOP_RESILIENT_TEST_STATUS_ERROR = $previousStatusError
        SCOOP_UPGRADE_SCOOP_COMMAND = $previousCommand
        SCOOP_RESILIENT_SCOOP_COMMAND = $previousToolsCommand
        SCOOP_RESILIENT_TEST_NATIVE_SCOOP = $previousNativeScoop
        SCOOP_RESILIENT_TEST_GLOBAL_APPS = $previousGlobalApps
        SCOOP_RESILIENT_TEST_LOG = $previousLog
        SCOOP_RESILIENT_TEST_FAIL_APP = $previousFailApp
        SCOOP_RESILIENT_TEST_EXPORT_FAILURE = $previousExportFailure
        SCOOP_RESILIENT_TEST_SYNC_FAILURE = $previousSyncFailure
        SCOOP_RESILIENT_TEST_APPS = $previousApps
        SCOOP_RESILIENT_TEST_IS_ADMINISTRATOR = $previousIsAdministrator
        SCOOP_RESILIENT_TEST_ELEVATION_RESPONSE = $previousElevationResponse
        SCOOP_RESILIENT_TEST_ELEVATION_STATE = $previousElevationState
        SCOOP_RESILIENT_TEST_ELEVATION_BYPASS = $previousElevationBypass
    }
    foreach ($entry in $environment.GetEnumerator()) {
        if ($null -eq $entry.Value) {
            Remove-Item -Path "Env:$($entry.Key)" -ErrorAction SilentlyContinue
        } else {
            Set-Item -Path "Env:$($entry.Key)" -Value $entry.Value
        }
    }
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

& "$PSScriptRoot/classification.ps1"
& "$PSScriptRoot/tidy.ps1"
& "$PSScriptRoot/package.ps1"
