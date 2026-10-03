#Requires -Version 5.1
param([string] $InstallDirectory, [string] $ManifestPath)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
$core = Join-Path $PSScriptRoot 'upstream-scoop'
if (!(Test-Path (Join-Path $core 'bin/scoop.ps1'))) { $core = Join-Path (Split-Path -Parent $project) 'scoop' }
if (!(Test-Path (Join-Path $core 'bin/scoop.ps1'))) { throw 'Scoop 0.6.0 is required for shim integration tests.' }
$hostExecutable = (Get-Process -Id $PID).Path
$temp = Join-Path ([IO.Path]::GetTempPath()) "scoop shim tests O'Brien $([Guid]::NewGuid().ToString('N'))"
$variables = @('SCOOP', 'SCOOP_GLOBAL', 'SCOOP_CACHE', 'XDG_CONFIG_HOME',
    'SCOOP_RESILIENT_SCOOP_COMMAND', 'SCOOP_UPGRADE_SCOOP_COMMAND', 'SCOOP_RESILIENT_TEST_LOG',
    'SCOOP_RESILIENT_TEST_APPS', 'SCOOP_RESILIENT_TEST_GLOBAL_APPS', 'SCOOP_RESILIENT_TEST_NATIVE_SCOOP',
    'SCOOP_RESILIENT_TEST_CORE', 'SCOOP_RESILIENT_TEST_FAIL_APP', 'SCOOP_RESILIENT_TEST_EXPORT_FAILURE',
    'SCOOP_RESILIENT_TEST_SYNC_FAILURE', 'SCOOP_RESILIENT_TEST_FRESH', 'SCOOP_RESILIENT_TEST_IS_ADMINISTRATOR')
$previous = @{}
foreach ($name in $variables) { $previous[$name] = [Environment]::GetEnvironmentVariable($name) }
function Quote-TestLiteral($Value) { return "'" + $Value.Replace("'", "''") + "'" }
function Assert-Shim($Condition, $Message) { if (!$Condition) { throw $Message } }
function Invoke-TestShim {
    param([string[]] $CommandArguments, [string] $Command = 'scoop')
    $ErrorActionPreference = 'Continue'
    $PSNativeCommandUseErrorActionPreference = $false
    $output = @(& $hostExecutable -NoProfile -File (Join-Path $env:SCOOP "shims/$Command.ps1") @CommandArguments 2>&1)
    return [PSCustomObject]@{ Code = $LASTEXITCODE; Output = $output -join "`n" }
}
New-Item -ItemType Directory -Path $temp | Out-Null
try {
    $env:SCOOP = Join-Path $temp 'local'
    $env:SCOOP_GLOBAL = Join-Path $temp 'global'
    $env:SCOOP_CACHE = Join-Path $temp 'cache'
    $env:XDG_CONFIG_HOME = Join-Path $temp 'config'
    $shims = Join-Path $env:SCOOP 'shims'
    New-Item -ItemType Directory -Path $shims, $env:SCOOP_CACHE -Force | Out-Null
    $package = Join-Path $env:SCOOP 'apps/scoop-resilient/current'
    New-Item -ItemType Directory -Path $package -Force | Out-Null
    Get-ChildItem -LiteralPath $InstallDirectory | Copy-Item -Destination $package -Recurse
    $fixture = Join-Path $PSScriptRoot 'fixtures/fake-scoop.ps1'
    if ($env:OS -eq 'Windows_NT') {
        $backend = Join-Path $temp 'backend.cmd'
        @('@echo off', "`"$hostExecutable`" -NoProfile -File `"$fixture`" %*", 'exit /b %ERRORLEVEL%') | Set-Content -LiteralPath $backend -Encoding ASCII
    } else {
        $backend = Join-Path $temp 'backend'
        # The executable and fixture paths are outside the apostrophe test tree.
        @('#!/bin/sh', "exec '$hostExecutable' -NoProfile -File '$fixture' `"`$@`"") | Set-Content -LiteralPath $backend -Encoding ASCII
        & chmod +x $backend
    }
    $env:SCOOP_RESILIENT_SCOOP_COMMAND = $backend
    $env:SCOOP_RESILIENT_TEST_LOG = Join-Path $temp 'calls.log'
    $env:SCOOP_RESILIENT_TEST_APPS = 'broken,healthy'
    $env:SCOOP_RESILIENT_TEST_FAIL_APP = 'broken'
    $env:SCOOP_RESILIENT_TEST_CORE = $core
    $env:SCOOP_RESILIENT_TEST_GLOBAL_APPS = ''
    $env:SCOOP_RESILIENT_TEST_NATIVE_SCOOP = ''
    $env:SCOOP_RESILIENT_TEST_EXPORT_FAILURE = 'false'
    $env:SCOOP_RESILIENT_TEST_SYNC_FAILURE = 'false'
    $env:SCOOP_RESILIENT_TEST_FRESH = 'true'
    $env:SCOOP_RESILIENT_TEST_IS_ADMINISTRATOR = 'false'
    foreach ($name in @('broken', 'healthy')) {
        $app = Join-Path $env:SCOOP "apps/$name"
        $active = Join-Path $app '2.0'
        $old = Join-Path $app '1.0'
        New-Item -ItemType Directory -Path $active, $old -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $active 'scoop-manifest.json'), '{"version":"2.0"}')
        [IO.File]::WriteAllText((Join-Path $active 'scoop-install.json'), '{"architecture":"64bit"}')
        [IO.File]::WriteAllText((Join-Path $old 'old.txt'), 'obsolete')
        $linkType = if ($env:OS -eq 'Windows_NT') { 'Junction' } else { 'SymbolicLink' }
        New-Item -ItemType $linkType -Path (Join-Path $app 'current') -Target $active | Out-Null
    }
    # Invoke Scoop's real shim generator, with PATH persistence disabled so tests
    # never change the user's registry or profile. Use its actual post_install hook.
    $setup = Join-Path $temp 'setup.ps1'
    $coreLiteral = Quote-TestLiteral $core
    $packageLiteral = Quote-TestLiteral $package
    $manifestLiteral = Quote-TestLiteral $ManifestPath
    @(
        '$ErrorActionPreference = ''Stop''',
        "`$core = $coreLiteral",
        '. "$core/lib/core.ps1"',
        '. "$core/lib/manifest.ps1"',
        '. "$core/lib/install.ps1"',
        'function Add-Path { }',
        # The upstream generator uses Windows separators with .NET file writes.
        # Normalize only the write destination on Unix, preserving shim content.
        'if ($env:OS -ne ''Windows_NT'') {',
        'function Out-UTF8File { param($FilePath, [switch]$Append, [switch]$NoNewLine, [Parameter(ValueFromPipeline=$true)]$InputObject)',
        'process { $destination = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($FilePath);',
        'if ($Append) { [IO.File]::AppendAllText($destination, [string]$InputObject) }',
        'elseif ($NoNewLine) { [IO.File]::WriteAllText($destination, [string]$InputObject) }',
        'else { [IO.File]::WriteAllLines($destination, [string[]]$InputObject) } } }',
        '}',
        'shim "$core/bin/scoop.ps1" $false ''scoop''',
        "`$dir = $packageLiteral",
        '$global = $false',
        'foreach ($name in @(''scoop-upgrade'', ''scoop-tidy'')) { shim (Join-Path $dir "$name.ps1") $false $name }',
        "`$manifest = Get-Content -LiteralPath $manifestLiteral -Raw | ConvertFrom-Json",
        'Invoke-HookScript -HookType post_install -Manifest $manifest -ProcessorArchitecture ''64bit'''
    ) | Set-Content -LiteralPath $setup -Encoding UTF8
    & $hostExecutable -NoProfile -File $setup | Out-Host
    Assert-Shim ($LASTEXITCODE -eq 0) 'Generating and registering real Scoop shims failed.'
    # The caller shim retains Scoop's own $path. A bad relative extension target
    # would reuse that inherited value and redispatch -a as a Scoop command.
    $upgrade = Invoke-TestShim -CommandArguments @('upgrade', '-a')
    Assert-Shim ($upgrade.Code -eq 1) $upgrade.Output
    Assert-Shim ($upgrade.Output.Contains('broken [Download]')) $upgrade.Output
    Assert-Shim ($upgrade.Output.Contains('healthy [Success]')) $upgrade.Output
    Assert-Shim (!$upgrade.Output.Contains("isn't a scoop command")) $upgrade.Output
    $tidy = Invoke-TestShim -CommandArguments @('tidy', '-ak')
    Assert-Shim ($tidy.Code -eq 0) $tidy.Output
    foreach ($name in @('broken', 'healthy')) {
        Assert-Shim (!(Test-Path (Join-Path $env:SCOOP "apps/$name/1.0"))) "Registered tidy did not remove $name's old version."
        Assert-Shim (Test-Path (Join-Path $env:SCOOP "apps/$name/current/scoop-manifest.json")) 'Registered tidy damaged the current version.'
    }
    $direct = Invoke-TestShim -Command 'scoop-upgrade' -CommandArguments @('--help')
    Assert-Shim ($direct.Code -eq 0 -and $direct.Output.Contains('Usage: scoop upgrade')) $direct.Output
    Write-Host 'Real Scoop shim dispatch tests passed.' -ForegroundColor Green
} finally {
    . (Join-Path $project 'lib/tidy.ps1')
    if (Test-Path -LiteralPath $temp) { Remove-TidyTree -Path $temp }
    foreach ($name in $variables) { [Environment]::SetEnvironmentVariable($name, $previous[$name]) }
}
