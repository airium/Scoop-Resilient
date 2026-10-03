param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $CommandArguments
)

Set-StrictMode -Version 2.0

Add-Content -LiteralPath $env:SCOOP_RESILIENT_TEST_LOG -Value ($CommandArguments -join ' ')

if ($CommandArguments.Count -eq 0) {
    exit 64
}

if ($env:SCOOP_RESILIENT_TEST_NATIVE_SCOOP) {
    & $env:SCOOP_RESILIENT_TEST_NATIVE_SCOOP @CommandArguments
    exit $LASTEXITCODE
}

switch ($CommandArguments[0]) {
    'config' {
        if ($env:SCOOP_RESILIENT_TEST_FRESH -eq 'true') { [DateTime]::Now.ToString('o') }
        else { [DateTime]::Now.AddHours(-4).ToString('o') }
        exit 0
    }
    'prefix' { Write-Output $env:SCOOP_RESILIENT_TEST_CORE; exit 0 }

    'export' {
        if ($env:SCOOP_RESILIENT_TEST_EXPORT_FAILURE -eq 'true') {
            exit 19
        }

        $appNames = if ([string]::IsNullOrWhiteSpace($env:SCOOP_RESILIENT_TEST_APPS)) {
            @('broken', 'healthy', 'held', 'damaged')
        } else {
            @($env:SCOOP_RESILIENT_TEST_APPS -split ',')
        }
        $apps = foreach ($name in $appNames) {
            $info = switch ($name) {
                'held' { 'Held package' }
                'damaged' { 'Install failed' }
                { $_ -like 'global-*' } { 'Global install' }
                default { '' }
            }
            @{ Name = $name; Version = '1.0'; Source = 'main'; Info = $info }
        }
        if ($env:SCOOP_RESILIENT_TEST_GLOBAL_APPS) {
            $apps = @($apps) + @($env:SCOOP_RESILIENT_TEST_GLOBAL_APPS -split ',' | ForEach-Object {
                @{ Name = $_; Version = '1.0'; Source = 'main'; Info = 'Global install' }
            })
        }
        @{
            apps = @($apps)
            buckets = @()
        } | ConvertTo-Json -Depth 4 -Compress
        exit 0
    }
    'update' {
        if ($CommandArguments.Count -eq 1) {
            if ($env:SCOOP_RESILIENT_TEST_SYNC_FAILURE -eq 'true') {
                exit 17
            }
            exit 0
        }

        $app = $CommandArguments[1]
        Write-Output "Fake update: $app"
        if ($app -eq $env:SCOOP_RESILIENT_TEST_FAIL_APP) {
            [Console]::Error.WriteLine('The remote server returned an error: (404) Not Found.')
            exit 23
        }
        switch ($app) {
            'clash-verge-rev' { Write-Output 'Checking hash... OK.'; Write-Output 'Running pre_uninstall script... ERROR clash-verge-rev requires admin rights to update'; exit 0 }
            'copyq' { Write-Output 'ERROR The following instances of "copyq" are still running. Close them and try again.'; Write-Output 'Running process detected, skip updating.'; exit 0 }
            'stderr-success' { [Console]::Error.WriteLine('Harmless native diagnostic'); Write-Output 'Finished after stderr.'; exit 0 }
            'missing-current' { Write-Output "ERROR No manifest available for 'missing-current'."; Write-Output 'missing-current: 1.0 (latest version)'; exit 0 }
            'fatal-current' { Write-Output 'fatal: injected repository error'; Write-Output 'fatal-current: 1.0 (latest version)'; exit 0 }

            'running' {
                Write-Output 'ERROR The following instances of "running" are still running. Close them and try again.'
                Write-Output 'Running process detected, skip updating.'
                exit 0
            }
            'current' {
                Write-Output 'current: 1.0 (latest version)'
                exit 0
            }
            'missing' {
                Write-Output "ERROR No manifest available for 'missing'."
                exit 0
            }
            'unsupported' {
                Write-Output "ERROR 'unsupported' doesn't support current architecture!"
                exit 0
            }
            'admin-warning' {
                Write-Output "WARN Installer added a directory to the system path (requires admin permission)."
                Write-Output "'admin-warning' (1.1) was installed successfully!"
                exit 0
            }
            'hash-fail' {
                Write-Output 'Hash check failed!'
                exit 24
            }
            'locked' {
                Write-Output "Couldn't remove 'locked'; it may be in use."
                exit 25
            }
            'installer-fail' {
                Write-Output 'Installation aborted. You might need to uninstall the app before trying again.'
                exit 26
            }
            'permission-fail' {
                Write-Output 'Access denied: permission-fail.'
                exit 27
            }
            'unknown-fail' {
                Write-Output 'Something unusual happened.'
                exit 28
            }
        }
        exit 0
    }
    default {
        exit 64
    }
}
