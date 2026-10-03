# Minimal configured path provider, used only in temporary test installations.
$scoopdir = Join-Path $env:SCOOP_RESILIENT_TEST_ROOT 'local'
$globaldir = Join-Path $env:SCOOP_RESILIENT_TEST_ROOT 'global'
$cachedir = Join-Path $env:SCOOP_RESILIENT_TEST_ROOT 'cache'
function get_config($Name) { return $Name -eq 'NO_JUNCTION' -and $env:SCOOP_RESILIENT_TEST_NO_JUNCTION -eq 'true' }
function appdir($Name, $Global) {
    $root = if ($Global) { $globaldir } else { $scoopdir }
    return Join-Path (Join-Path $root 'apps') $Name
}
function Remove-Item {
    [CmdletBinding()]
    param([string] $LiteralPath, [switch] $Force)
    if ($env:SCOOP_RESILIENT_TEST_DELETE_FAILURE -and $LiteralPath.Replace('\', '/') -match $env:SCOOP_RESILIENT_TEST_DELETE_FAILURE) {
        $PSCmdlet.WriteError([Management.Automation.ErrorRecord]::new(
            [IO.IOException]::new('Injected sharing violation'), 'TestLock',
            [Management.Automation.ErrorCategory]::WriteError, $LiteralPath))
        return
    }
    Microsoft.PowerShell.Management\Remove-Item -LiteralPath $LiteralPath -Force:$Force -ErrorAction Stop
}
