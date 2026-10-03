# Read-only app status fixture. Mutation commands still run in fake-scoop.ps1.
function Select-CurrentVersion { param($AppName, $Global); return '1.0' }
function install_info { return [PSCustomObject]@{ url = $null } }
function app_status {
    param($App, $Global)
    if ($env:SCOOP_RESILIENT_TEST_STATUS_ERROR -eq $App) { throw 'Injected inconclusive status.' }
    $current = $App -match '^(current(?:-|$)|global-current(?:-|$))'
    return @{
        installed = $true; failed = $false; removed = $false; hold = $false
        version = '1.0'; latest_version = $(if ($current) { '1.0' } else { '2.0' }); outdated = !$current
    }
}
