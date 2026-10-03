#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $InstallDirectory,
    [string] $ShimDirectory
)
$ErrorActionPreference = 'Stop'
if (!$ShimDirectory) {
    $scoopCommand = Get-Command scoop.cmd -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $ShimDirectory = Split-Path -Parent $scoopCommand.Source
}
if (!(Test-Path -LiteralPath $ShimDirectory -PathType Container)) { throw "Shim directory does not exist: $ShimDirectory" }
foreach ($name in @('scoop-upgrade', 'scoop-tidy')) {
    $target = (Resolve-Path -LiteralPath (Join-Path $InstallDirectory "$name.ps1") -ErrorAction Stop).Path
    $literalTarget = $target.Replace("'", "''")
    # Scoop 0.6 evaluates this assignment through a dynamically created
    # scriptblock. $PSScriptRoot is empty there, so the target must be absolute.
    $lines = @(
        "# $target",
        "`$path = '$literalTarget'",
        'if ($MyInvocation.ExpectingInput) { $input | & $path @args } else { & $path @args }',
        'exit $LASTEXITCODE'
    )
    $shimPath = Join-Path $ShimDirectory "$name.ps1"
    [IO.File]::WriteAllText($shimPath, (($lines -join "`r`n") + "`r`n"), (New-Object Text.UTF8Encoding($false)))
}
