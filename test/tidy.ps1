#Requires -Version 5.1
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
$hostExecutable = (Get-Process -Id $PID).Path
$temp = Join-Path ([IO.Path]::GetTempPath()) "scoop tidy tests $PID $([Guid]::NewGuid().ToString('N'))"
$log = Join-Path $temp 'calls.log'
$variables = @('SCOOP_UPGRADE_SCOOP_COMMAND', 'SCOOP_RESILIENT_SCOOP_COMMAND', 'SCOOP_RESILIENT_TEST_LOG', 'SCOOP_RESILIENT_TEST_APPS',
    'SCOOP_RESILIENT_TEST_IS_ADMINISTRATOR', 'SCOOP_RESILIENT_TEST_ELEVATION_RESPONSE', 'SCOOP_RESILIENT_TEST_ELEVATION_BYPASS',
    'SCOOP_RESILIENT_TEST_ROOT', 'SCOOP_RESILIENT_TEST_CORE', 'SCOOP_RESILIENT_TEST_GLOBAL_APPS',
    'SCOOP_RESILIENT_TEST_NO_JUNCTION', 'SCOOP_RESILIENT_TEST_DELETE_FAILURE', 'SCOOP_RESILIENT_TEST_NATIVE_SCOOP',
    'SCOOP', 'SCOOP_GLOBAL', 'SCOOP_CACHE', 'XDG_CONFIG_HOME')
$previous = @{}
foreach ($name in $variables) { $previous[$name] = [Environment]::GetEnvironmentVariable($name) }

function Assert-Tidy {
    param([bool] $Condition, [string] $Message)
    if (!$Condition) { throw $Message }
}
function New-TestFile {
    param([string] $Path, [string] $Contents = 'keep this data')
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [IO.File]::WriteAllText($Path, $Contents)
}
function New-TestLink {
    param([string] $Path, [string] $Target)
    $type = if ($env:OS -eq 'Windows_NT') { 'Junction' } else { 'SymbolicLink' }
    New-Item -ItemType $type -Path $Path -Target $Target | Out-Null
}
function New-TestApp {
    param([string] $Name, [switch] $Global, [string] $Version = '2.0', [switch] $Legacy, [switch] $NoLink)
    $scope = if ($Global) { 'global' } else { 'local' }
    $app = Join-Path (Join-Path (Join-Path $env:SCOOP_RESILIENT_TEST_ROOT $scope) 'apps') $Name
    foreach ($old in @('1.0', '1.5')) { New-TestFile -Path (Join-Path (Join-Path $app $old) 'old.txt') }
    $active = Join-Path $app $Version
    $prefix = if ($Legacy) { '' } else { 'scoop-' }
    New-TestFile -Path (Join-Path $active "$($prefix)manifest.json") -Contents "{`"version`":`"$Version`"}"
    New-TestFile -Path (Join-Path $active "$($prefix)install.json") -Contents '{"architecture":"64bit"}'
    New-TestFile -Path (Join-Path $active 'active.txt')
    if (!$NoLink) { New-TestLink -Path (Join-Path $app 'current') -Target $active }
    return $app
}
function Reset-TestInstallation {
    param([string] $Apps = 'broken,healthy')
    # Each scenario gets a fresh tree. Do not recursively delete a tree containing
    # junctions: cleanup itself is also used by the test teardown below.
    $env:SCOOP_RESILIENT_TEST_ROOT = Join-Path $temp ([Guid]::NewGuid().ToString('N'))
    $env:SCOOP_RESILIENT_TEST_APPS = $Apps
    $env:SCOOP_RESILIENT_TEST_IS_ADMINISTRATOR = 'false'
    $env:SCOOP_RESILIENT_TEST_ELEVATION_RESPONSE = ''
    $env:SCOOP_RESILIENT_TEST_ELEVATION_BYPASS = ''
    $env:SCOOP_RESILIENT_TEST_GLOBAL_APPS = ''
    $env:SCOOP_RESILIENT_TEST_NO_JUNCTION = ''
    $env:SCOOP_RESILIENT_TEST_DELETE_FAILURE = ''
    $env:SCOOP_RESILIENT_TEST_NATIVE_SCOOP = ''
    New-Item -ItemType Directory -Path (Join-Path $env:SCOOP_RESILIENT_TEST_ROOT 'cache') -Force | Out-Null
}
function Invoke-TestTidy {
    param([string[]] $Options = @('-a'))
    $ErrorActionPreference = 'Continue'
    $PSNativeCommandUseErrorActionPreference = $false
    $output = @(& $hostExecutable -NoProfile -File (Join-Path $project 'scoop-tidy.ps1') @Options 2>&1)
    return [PSCustomObject]@{ Code = $LASTEXITCODE; Output = ($output -join "`n") }
}

New-Item -ItemType Directory -Path $temp | Out-Null
try {
    $env:SCOOP_RESILIENT_TEST_CORE = Join-Path $temp 'core'
    New-Item -ItemType Directory -Path (Join-Path $env:SCOOP_RESILIENT_TEST_CORE 'lib') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures/tidy-core.ps1') -Destination (Join-Path $env:SCOOP_RESILIENT_TEST_CORE 'lib/core.ps1')
    $fixture = Join-Path $PSScriptRoot 'fixtures/fake-scoop.ps1'
    if ($env:OS -eq 'Windows_NT') {
        $launcher = Join-Path $temp 'scoop.cmd'
        @('@echo off', "`"$hostExecutable`" -NoProfile -File `"$fixture`" %*", 'exit /b %ERRORLEVEL%') | Set-Content -LiteralPath $launcher -Encoding ASCII
    } else {
        $launcher = Join-Path $temp 'scoop'
        @('#!/bin/sh', "exec '$hostExecutable' -NoProfile -File '$fixture' `"`$@`"") | Set-Content -LiteralPath $launcher -Encoding ASCII
        & chmod +x $launcher
    }
    $env:SCOOP_UPGRADE_SCOOP_COMMAND = $launcher
    $env:SCOOP_RESILIENT_SCOOP_COMMAND = $launcher
    $env:SCOOP_RESILIENT_TEST_LOG = $log

    Reset-TestInstallation
    $broken = New-TestApp broken
    $healthy = New-TestApp healthy -Legacy
    $env:SCOOP_RESILIENT_TEST_DELETE_FAILURE = '/broken/1\.0/'
    $result = Invoke-TestTidy
    Assert-Tidy ($result.Code -eq 1) $result.Output
    Assert-Tidy (Test-Path (Join-Path $broken '1.0/old.txt')) 'Failed version must remain.'
    Assert-Tidy (!(Test-Path (Join-Path $broken '1.5'))) 'A failed version must not block other versions of the same app.'
    Assert-Tidy (!(Test-Path (Join-Path $healthy '1.0'))) 'A failed app must not block the next app.'
    Assert-Tidy (Test-Path (Join-Path $healthy 'current/active.txt')) 'Current version must remain usable.'

    Reset-TestInstallation 'healthy'
    $healthy = New-TestApp healthy
    $persist = Join-Path $env:SCOOP_RESILIENT_TEST_ROOT 'persist/settings'
    New-TestFile -Path (Join-Path $persist 'settings.txt') -Contents 'persistent sentinel'
    New-TestLink -Path (Join-Path $healthy '1.0/settings') -Target $persist
    $hardLink = Join-Path $healthy '1.5/settings.txt'
    New-Item -ItemType HardLink -Path $hardLink -Target (Join-Path $persist 'settings.txt') | Out-Null
    $result = Invoke-TestTidy
    Assert-Tidy ($result.Code -eq 0) $result.Output
    Assert-Tidy ((Get-Content -LiteralPath (Join-Path $persist 'settings.txt') -Raw) -eq 'persistent sentinel') 'Persisted junction/hard-link targets must survive.'
    Assert-Tidy (!(Test-Path (Join-Path $healthy '1.0'))) 'Old directories with persisted links should be removed.'

    Reset-TestInstallation 'healthy'
    $healthy = New-TestApp healthy
    $null = New-TestApp healthy -Global -Version '3.0'
    $cache = Join-Path $env:SCOOP_RESILIENT_TEST_ROOT 'cache'
    foreach ($name in @('healthy#1.0#lock.zip', 'healthy#1.5#remove.zip', 'healthy#2.0#keep.zip', 'healthy#3.0#keep.zip', 'orphan.download', 'other#1.0#keep.zip')) { New-TestFile -Path (Join-Path $cache $name) }
    $env:SCOOP_RESILIENT_TEST_DELETE_FAILURE = 'healthy#1\.0#'
    $result = Invoke-TestTidy -Options @('-ak')
    Assert-Tidy ($result.Code -eq 1) $result.Output
    Assert-Tidy (Test-Path (Join-Path $cache 'healthy#1.0#lock.zip')) 'Failed cache removal should remain and report failure.'
    foreach ($name in @('healthy#2.0#keep.zip', 'healthy#3.0#keep.zip', 'other#1.0#keep.zip')) { Assert-Tidy (Test-Path (Join-Path $cache $name)) "Cache must retain $name" }
    foreach ($name in @('healthy#1.5#remove.zip', 'orphan.download')) { Assert-Tidy (!(Test-Path (Join-Path $cache $name))) "Cache failure must not block $name" }

    Reset-TestInstallation
    $broken = New-TestApp broken
    $healthy = New-TestApp healthy
    New-TestFile -Path (Join-Path $broken '2.0/scoop-manifest.json') -Contents '{broken json'
    $result = Invoke-TestTidy -Options @('-ak')
    Assert-Tidy ($result.Code -eq 0) $result.Output
    Assert-Tidy ($result.Output.Contains('[Metadata]')) 'Uncertain current version must be reported as skipped.'
    Assert-Tidy (Test-Path (Join-Path $broken '1.0/old.txt')) 'Uncertain metadata must preserve all versions.'
    Assert-Tidy (!(Test-Path (Join-Path $healthy '1.0'))) 'A skipped app must not block subsequent cleanup.'

    Reset-TestInstallation 'held,damaged'
    $held = New-TestApp held
    $damaged = New-TestApp damaged
    $result = Invoke-TestTidy
    Assert-Tidy ($result.Code -eq 0) $result.Output
    Assert-Tidy (!(Test-Path (Join-Path $held '1.0'))) 'Held apps remain eligible for cleanup.'
    Assert-Tidy (!(Test-Path (Join-Path $damaged '1.0'))) 'Export repair flags alone must not prevent safe cleanup with valid current metadata.'

    Reset-TestInstallation 'healthy'
    $env:SCOOP_RESILIENT_TEST_NO_JUNCTION = 'true'
    $healthy = New-TestApp healthy -NoLink -Legacy
    $result = Invoke-TestTidy
    Assert-Tidy ($result.Code -eq 0) $result.Output
    Assert-Tidy (Test-Path (Join-Path $healthy '2.0/active.txt')) 'NO_JUNCTION current version must remain.'
    Assert-Tidy (!(Test-Path (Join-Path $healthy '1.0'))) 'NO_JUNCTION obsolete versions should be removed.'

    Reset-TestInstallation 'healthy'
    $env:SCOOP_RESILIENT_TEST_NO_JUNCTION = 'true'
    $healthy = New-TestApp healthy -NoLink
    New-TestFile -Path (Join-Path $healthy '1.0/scoop-install.json') -Contents '{"architecture":"64bit"}'
    New-TestFile -Path (Join-Path $healthy '1.0/scoop-manifest.json') -Contents '{"version":"1.0"}'
    $timestamp = [DateTime]::UtcNow.AddMinutes(-10)
    (Get-Item -LiteralPath (Join-Path $healthy '1.0/scoop-install.json')).LastWriteTimeUtc = $timestamp
    (Get-Item -LiteralPath (Join-Path $healthy '2.0/scoop-install.json')).LastWriteTimeUtc = $timestamp
    $result = Invoke-TestTidy
    Assert-Tidy ($result.Output.Contains('[Metadata]')) 'Tied installation timestamps must be treated as uncertain.'
    Assert-Tidy (Test-Path (Join-Path $healthy '1.0')) 'Ambiguous NO_JUNCTION selection must preserve all versions.'

    Reset-TestInstallation 'healthy'
    $env:SCOOP_RESILIENT_TEST_NO_JUNCTION = 'true'
    $healthy = New-TestApp healthy
    [IO.Directory]::Delete((Join-Path $healthy 'current'), $false)
    New-TestLink -Path (Join-Path $healthy 'current') -Target (Join-Path $healthy '1.0')
    $result = Invoke-TestTidy
    Assert-Tidy ($result.Output.Contains('[Metadata]')) 'A conflicting current link must prevent cleanup in NO_JUNCTION mode.'
    Assert-Tidy (Test-Path (Join-Path $healthy '1.0/old.txt')) 'Existing current targets must be preserved even when NO_JUNCTION selection differs.'

    Reset-TestInstallation 'healthy,global-one'
    $healthy = New-TestApp healthy
    $global = New-TestApp global-one -Global
    $result = Invoke-TestTidy
    Assert-Tidy (Test-Path (Join-Path $global '1.0')) 'All without -g must preserve global installations.'
    $result = Invoke-TestTidy -Options @('-ag', '--no-elevation-prompt')
    Assert-Tidy ($result.Output.Contains('[Elevation]')) 'Global apps should explain skipped elevation.'
    $env:SCOOP_RESILIENT_TEST_ELEVATION_RESPONSE = 'y'
    $env:SCOOP_RESILIENT_TEST_ELEVATION_BYPASS = 'true'
    $result = Invoke-TestTidy -Options @('-ag')
    Assert-Tidy ($result.Code -eq 0) $result.Output
    Assert-Tidy (!(Test-Path (Join-Path $global '1.0'))) 'The elevated batch should perform global cleanup.'
    Assert-Tidy ($result.Output.Contains('(global) [Version]')) 'Item-level elevated results should merge into the parent summary.'

    Reset-TestInstallation 'healthy'
    $healthy = New-TestApp healthy
    $result = Invoke-TestTidy -Options @('healthy', 'missing')
    Assert-Tidy ($result.Code -eq 1) 'An uninstalled explicit app should make the aggregate fail.'
    Assert-Tidy (!(Test-Path (Join-Path $healthy '1.0'))) 'A missing explicit target must not block valid targets.'
    $result = Invoke-TestTidy -Options @()
    Assert-Tidy ($result.Code -eq 1) 'Tidy requires an app or --all.'
    $result = Invoke-TestTidy -Options @('-af')
    Assert-Tidy ($result.Code -eq 1) 'Tidy must reject update-only flags.'

    Reset-TestInstallation 'healthy'
    $healthy = New-TestApp healthy -Version 'nightly-20261003'
    New-TestFile -Path (Join-Path $healthy 'nightly-20261003/scoop-manifest.json') -Contents '{"version":"nightly"}'
    $result = Invoke-TestTidy
    Assert-Tidy ($result.Code -eq 0) $result.Output
    Assert-Tidy (Test-Path (Join-Path $healthy 'nightly-20261003/active.txt')) 'Nightly must retain the dated current target.'
    Assert-Tidy (!(Test-Path (Join-Path $healthy '1.0'))) 'Nightly old versions should be removed.'

    Reset-TestInstallation 'healthy'
    $healthy = New-TestApp healthy
    $outside = Join-Path $env:SCOOP_RESILIENT_TEST_ROOT 'outside/2.0'
    New-TestFile -Path (Join-Path $outside 'scoop-manifest.json') -Contents '{"version":"2.0"}'
    New-TestFile -Path (Join-Path $outside 'sentinel.txt')
    [IO.Directory]::Delete((Join-Path $healthy 'current'), $false)
    New-TestLink -Path (Join-Path $healthy 'current') -Target $outside
    $result = Invoke-TestTidy
    Assert-Tidy ($result.Code -eq 0) $result.Output
    Assert-Tidy ($result.Output.Contains('[Metadata]')) 'An outside current target must be skipped.'
    Assert-Tidy (Test-Path (Join-Path $healthy '1.0')) 'An outside current link must preserve all app versions.'
    Assert-Tidy (Test-Path (Join-Path $outside 'sentinel.txt')) 'Outside link targets must be preserved.'

    Reset-TestInstallation 'healthy'
    $healthy = New-TestApp healthy
    $global = New-TestApp healthy -Global -Version '3.0'
    $env:SCOOP_RESILIENT_TEST_GLOBAL_APPS = 'healthy'
    $env:SCOOP_RESILIENT_TEST_IS_ADMINISTRATOR = 'true'
    $result = Invoke-TestTidy -Options @('healthy', '-g')
    Assert-Tidy ($result.Code -eq 0) $result.Output
    Assert-Tidy (Test-Path (Join-Path $healthy '1.0')) 'Explicit -g must retain the local installation.'
    Assert-Tidy (!(Test-Path (Join-Path $global '1.0'))) 'Explicit -g must clean the global installation.'

    Reset-TestInstallation 'healthy'
    $healthy = New-TestApp healthy
    $global = New-TestApp healthy -Global
    New-TestFile -Path (Join-Path $global '2.0/scoop-manifest.json') -Contents '{invalid'
    $cache = Join-Path $env:SCOOP_RESILIENT_TEST_ROOT 'cache'
    New-TestFile -Path (Join-Path $cache 'healthy#1.0#retain.zip')
    $result = Invoke-TestTidy -Options @('-ak')
    Assert-Tidy ($result.Code -eq 0) $result.Output
    Assert-Tidy (Test-Path (Join-Path $cache 'healthy#1.0#retain.zip')) 'Unknown global current metadata must retain shared cache.'
    Assert-Tidy (!(Test-Path (Join-Path $healthy '1.0'))) 'Unknown other-scope metadata must not block local version cleanup.'

    $realCore = Join-Path $PSScriptRoot 'upstream-scoop'
    if (!(Test-Path (Join-Path $realCore 'lib/core.ps1'))) { $realCore = Join-Path (Split-Path -Parent $project) 'scoop' }
    if (Test-Path (Join-Path $realCore 'lib/core.ps1')) {
        Reset-TestInstallation 'healthy'
        $healthy = New-TestApp healthy
        $previousCore = $env:SCOOP_RESILIENT_TEST_CORE
        $env:SCOOP_RESILIENT_TEST_CORE = $realCore
        $env:SCOOP = Join-Path $env:SCOOP_RESILIENT_TEST_ROOT 'local'
        $env:SCOOP_GLOBAL = Join-Path $env:SCOOP_RESILIENT_TEST_ROOT 'global'
        $env:SCOOP_CACHE = Join-Path $env:SCOOP_RESILIENT_TEST_ROOT 'cache'
        $env:XDG_CONFIG_HOME = Join-Path $env:SCOOP_RESILIENT_TEST_ROOT 'config'
        $result = Invoke-TestTidy
        Assert-Tidy ($result.Code -eq 0) $result.Output
        Assert-Tidy (!(Test-Path (Join-Path $healthy '1.0'))) 'The actual installed Scoop core must supply usable configured paths.'
        Assert-Tidy (Test-Path (Join-Path $healthy 'current/active.txt')) 'Actual Scoop core integration must preserve current data.'
        if ($env:OS -eq 'Windows_NT') {
            Reset-TestInstallation
            $env:SCOOP = Join-Path $env:SCOOP_RESILIENT_TEST_ROOT 'local'
            $env:SCOOP_GLOBAL = Join-Path $env:SCOOP_RESILIENT_TEST_ROOT 'global'
            $env:SCOOP_CACHE = Join-Path $env:SCOOP_RESILIENT_TEST_ROOT 'cache'
            $env:XDG_CONFIG_HOME = Join-Path $env:SCOOP_RESILIENT_TEST_ROOT 'config'
            $broken = New-TestApp broken -Version '1.0'
            $healthy = New-TestApp healthy
            New-Item -ItemType Directory -Path (Join-Path $env:SCOOP 'shims'), (Join-Path $env:SCOOP_GLOBAL 'apps') -Force | Out-Null
            New-TestFile -Path (Join-Path $env:XDG_CONFIG_HOME 'scoop/config.json') -Contents (@{last_update=[DateTime]::Now.ToString('o');aria2_enabled=$false} | ConvertTo-Json)
            $main = Join-Path $env:SCOOP 'buckets/main'
            $bucket = Join-Path $main 'bucket'
            foreach ($name in @('broken', 'healthy')) {
                $manifest = @{version='2.0';url="https://example.invalid/$name.zip";hash=('0' * 64)} | ConvertTo-Json
                New-TestFile -Path (Join-Path $bucket "$name.json") -Contents $manifest
                foreach ($version in @('1.0', '2.0')) {
                    $metadata = Join-Path $env:SCOOP "apps/$name/$version/scoop-install.json"
                    if (Test-Path $metadata) { New-TestFile -Path $metadata -Contents '{"architecture":"64bit","bucket":"main"}' }
                }
            }
            & git -C $main init --quiet
            Assert-Tidy ($LASTEXITCODE -eq 0) 'Could not initialize the fixture bucket.'
            & git -C $main remote add origin https://github.com/ScoopInstaller/Main
            Assert-Tidy ($LASTEXITCODE -eq 0) 'Could not configure the fixture bucket remote.'
            & git -C $main add -- bucket
            Assert-Tidy ($LASTEXITCODE -eq 0) 'Could not stage the fixture bucket manifests.'
            # export reads the bucket's last commit date. An unborn repository
            # makes git log print a fatal error, corrupting the exported JSON.
            & git -C $main -c user.name='Scoop-Resilient tests' -c user.email='scoop-resilient@example.invalid' -c commit.gpgsign=false commit --quiet -m 'test: initialize fixture bucket'
            Assert-Tidy ($LASTEXITCODE -eq 0) 'Could not create the fixture bucket commit.'
            # Scoop 0.6.0 recognizes legacy cache names, so this bad cached file
            # triggers its real hash-abort path without any download.
            New-TestFile -Path (Join-Path $env:SCOOP_CACHE 'broken#2.0#https_example.invalid_broken.zip') -Contents 'injected hash mismatch'
            $env:SCOOP_RESILIENT_TEST_NATIVE_SCOOP = Join-Path $realCore 'bin/scoop.ps1'
            $output = @(& $hostExecutable -NoProfile -File (Join-Path $project 'scoop-upgrade.ps1') broken healthy 2>&1)
            $code = $LASTEXITCODE
            Assert-Tidy ($code -eq 1) ($output -join "`n")
            Assert-Tidy (($output -join "`n").Contains('broken [Hash]')) 'Actual Scoop hash errors must be classified.'
            Assert-Tidy (($output -join "`n").Contains('healthy [Current]')) 'Actual Scoop abort must not block the next app.'
            $env:SCOOP_RESILIENT_TEST_NATIVE_SCOOP = ''
        }
        $env:SCOOP_RESILIENT_TEST_CORE = $previousCore
        foreach ($name in @('SCOOP', 'SCOOP_GLOBAL', 'SCOOP_CACHE', 'XDG_CONFIG_HOME')) { [Environment]::SetEnvironmentVariable($name, $previous[$name]) }
    }

    if ($env:OS -eq 'Windows_NT') {
        Reset-TestInstallation
        $broken = New-TestApp broken
        $healthy = New-TestApp healthy
        $lock = [IO.File]::Open((Join-Path $broken '1.0/old.txt'), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            $result = Invoke-TestTidy
            Assert-Tidy ($result.Code -eq 1) 'A real Windows file lock must be reported as failure.'
            Assert-Tidy (!(Test-Path (Join-Path $broken '1.5'))) 'A real lock must not block other versions.'
            Assert-Tidy (!(Test-Path (Join-Path $healthy '1.0'))) 'A real lock must not block other apps.'
        } finally { $lock.Dispose() }
    }
    Write-Host 'All scoop-tidy filesystem and integration tests passed.' -ForegroundColor Green
} finally {
    # Use the same non-traversing primitive so teardown cannot delete a junction's target.
    . (Join-Path $project 'lib/tidy.ps1')
    if (Test-Path -LiteralPath $temp) { Remove-TidyTree -Path $temp }
    foreach ($name in $variables) { [Environment]::SetEnvironmentVariable($name, $previous[$name]) }
}
