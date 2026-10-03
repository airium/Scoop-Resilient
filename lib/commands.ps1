# Argument parsing and orchestration shared by the two public entry points.

function Read-CommandOptions {
    param([string] $Operation, [AllowEmptyCollection()][string[]] $Arguments)
    $options = @{
        All = $false; Global = $false; Help = $false; NoElevationPrompt = $false
        Apps = @(); Forward = @()
    }
    $long = @{ all = 'All'; global = 'Global'; help = 'Help'; 'no-elevation-prompt' = 'NoElevationPrompt' }
    $short = @{ a = 'All'; g = 'Global'; h = 'Help' }
    $forward = if ($Operation -eq 'upgrade') {
        @{ f = 'force'; i = 'independent'; k = 'no-cache'; s = 'skip-hash-check'; q = 'quiet' }
    } else { @{ k = 'cache' } }
    $literal = $false
    foreach ($argument in $Arguments) {
        if (!$literal -and $argument -in @('--', '--%')) { $literal = $true; continue }
        if (!$literal -and $argument -in @('-NoElevationPrompt', '-Help', '/?')) {
            $key = if ($argument -eq '-NoElevationPrompt') { 'NoElevationPrompt' } else { 'Help' }
            $options[$key] = $true
        } elseif (!$literal -and $argument.StartsWith('--')) {
            $key = $argument.Substring(2)
            if ($long.ContainsKey($key)) { $options[$long[$key]] = $true }
            elseif ($key -in $forward.Values) { $options.Forward += "--$key" }
            else { throw "Unknown option: $argument" }
        } elseif (!$literal -and $argument.StartsWith('-') -and $argument.Length -gt 1) {
            foreach ($character in $argument.Substring(1).ToCharArray()) {
                $key = [string] $character
                if ($short.ContainsKey($key)) { $options[$short[$key]] = $true }
                elseif ($forward.ContainsKey($key)) { $options.Forward += "--$($forward[$key])" }
                else { throw "Unknown option: -$key" }
            }
        } else { $options.Apps += $argument }
    }
    $options.All = $options.All -or ('*' -in $options.Apps)
    $options.Forward = @($options.Forward | Select-Object -Unique)
    return [PSCustomObject] $options
}

function Show-CommandUsage {
    param([string] $Operation)
    Write-Host "Usage: scoop $Operation <app> [options]"
    if ($Operation -eq 'upgrade') {
        Write-Host 'With no app, synchronize Scoop and buckets. Use * or -a to update all local apps.'
        Write-Host 'Options: -a/--all, -g/--global, -f/--force, -i/--independent,'
        Write-Host '         -k/--no-cache, -s/--skip-hash-check, -q/--quiet'
    } else {
        Write-Host 'Remove old versions. Use * or -a for all local apps; -k also removes obsolete cache.'
        Write-Host 'Options: -a/--all, -g/--global, -k/--cache'
    }
    Write-Host '         --no-elevation-prompt, -h/--help'
}

function Get-OptionalProperty {
    param($Object, [string] $Name, $Default = $null)
    if ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $Default
}

function Get-AppTargets {
    param($Export, $Options, [System.Collections.Generic.List[object]] $Results)
    if ($null -eq $Export.PSObject.Properties['apps']) { throw "'scoop export' is missing the apps array." }
    $installed = @($Export.apps)
    $selected = @()
    if ($Options.All) {
        $selected = @($installed | Where-Object { !(Test-AppInfoFlag -Info ([string](Get-OptionalProperty $_ 'Info' '')) -Flag 'Global install') })
        if ($Options.Global) {
            $selected += @($installed | Where-Object { Test-AppInfoFlag -Info ([string](Get-OptionalProperty $_ 'Info' '')) -Flag 'Global install' })
        }
    } else {
        foreach ($specification in $Options.Apps) {
            if ($specification -eq 'scoop') { continue }
            # update/cleanup normalize bucket and version-qualified installed-app names.
            $parsed = [regex]::Match($specification, '^(?:[A-Za-z0-9_.-]+/)?(?<app>[A-Za-z0-9_.-]+)(?:@.*)?$')
            $name = $parsed.Groups['app'].Value
            if (!$parsed.Success -or $name -in @('.', '..')) {
                [void]$Results.Add((New-Outcome -Name $specification -Status Failed -Category Discovery -Reason 'Invalid installed app name.'))
                continue
            }
            $matchingApps = @($installed | Where-Object {
                (Get-OptionalProperty $_ 'Name' '') -eq $name -and
                (Test-AppInfoFlag -Info ([string](Get-OptionalProperty $_ 'Info' '')) -Flag 'Global install') -eq $Options.Global
            })
            if (!$matchingApps.Count) {
                $scope = if ($Options.Global) { 'globally' } else { 'locally' }
                [void]$Results.Add((New-Outcome -Name $name -Global:$Options.Global -Status Failed -Category Discovery -Reason "The app is not installed $scope."))
            } else { $selected += $matchingApps }
        }
    }
    $seen = @{}
    foreach ($app in $selected) {
        $name = [string](Get-OptionalProperty $app 'Name' '')
        $info = [string](Get-OptionalProperty $app 'Info' '')
        $global = Test-AppInfoFlag -Info $info -Flag 'Global install'
        if ($name -notmatch '^[A-Za-z0-9_.-]+$' -or $name -in @('.', '..', 'scoop')) {
            if ($name -ne 'scoop') { [void]$Results.Add((New-Outcome -Name 'Invalid app' -Status Failed -Category Discovery -Reason 'Scoop export contains an invalid app name.')) }
            continue
        }
        $key = "$global/$name"
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        [PSCustomObject]@{ Name = $name; Info = $info; Global = $global }
    }
}

function Test-ScoopSyncNeeded {
    # Match update's three-hour freshness check without loading Scoop into the
    # parent process. Child update commands retain their native freshness logic.
    $result = Invoke-ScoopCommand -ArgumentList @('config', 'last_update') -SuppressOutput
    if ($result.ExitCode -ne 0) { return $true }
    $lastUpdate = New-Object DateTime
    if (![DateTime]::TryParse(($result.Output -join '').Trim(), [ref]$lastUpdate)) { return $true }
    return ([DateTime]::Now - $lastUpdate).TotalHours -ge 3
}

function Get-ScoopCoreDirectory {
    $result = Invoke-ScoopCommand -ArgumentList @('prefix', 'scoop') -SuppressOutput
    if ($result.ExitCode -ne 0) { throw 'Could not locate the installed Scoop core.' }
    $path = ($result.Output -join '').Trim()
    if (!(Test-Path -LiteralPath (Join-Path $path 'lib/core.ps1') -PathType Leaf)) {
        throw "Scoop core.ps1 was not found in: $path"
    }
    return (Resolve-Path -LiteralPath $path).Path
}

function Invoke-AppOperation {
    param([string] $Name, [bool] $Global)
    if ($script:Operation -eq 'upgrade') {
        if ($Name.StartsWith('-')) {
            $arguments = @('update') + $script:ForwardOptions
            if ($Global) { $arguments += '--global' }
            $arguments += @('--', $Name)
        } else {
            $arguments = @('update', $Name) + $script:ForwardOptions
            if ($Global) { $arguments += '--global' }
        }
        $commandResult = Invoke-ScoopCommand -ArgumentList $arguments
        return ConvertTo-AppOutcome -Name $Name -Global:$Global -CommandResult $commandResult
    }
    return Invoke-TidyProcess -Name $Name -Global:$Global
}

function Invoke-TidyProcess {
    param([string] $Name, [bool] $Global, [switch] $PartialDownloads)
    $directory = Join-Path ([IO.Path]::GetTempPath()) "scoop-tidy-$PID-$([Guid]::NewGuid().ToString('N'))"
    $resultPath = Join-Path $directory 'result.json'
    try {
        New-Item -ItemType Directory -Path $directory -ErrorAction Stop | Out-Null
        $request = @{
            Name = $Name; Global = $Global; CoreDirectory = $script:CoreDirectory
            Cache = ('--cache' -in $script:ForwardOptions); PartialDownloads = [bool]$PartialDownloads
        } | ConvertTo-Json -Compress
        $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($request))
        $hostExecutable = Get-CurrentPowerShellExecutable
        $ErrorActionPreference = 'Continue'
        $PSNativeCommandUseErrorActionPreference = $false
        & $hostExecutable -NoProfile -ExecutionPolicy Bypass -File $script:EntryPoint --internal-tidy-worker $payload $resultPath 2>&1 | Out-Host
        $code = $LASTEXITCODE
        if (!(Test-Path -LiteralPath $resultPath -PathType Leaf)) { throw "Cleanup worker exited with code $code without returning results." }
        $response = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json -ErrorAction Stop
        if (!$response.Success) { throw [string]$response.Error }
        return @($response.Results)
    } catch {
        return New-Outcome -Name $Name -Global:$Global -Status Failed -Category Worker -Reason $_.Exception.Message -ExitCode 1
    } finally {
        Remove-Item -LiteralPath $directory -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Complete-GlobalBatch {
    param([string[]] $Names, [System.Collections.Generic.List[object]] $Results)
    if (!$Names.Count) { return }
    if (!(Test-CanPromptForElevation)) {
        $reason = if ($script:Options.NoElevationPrompt) { 'Administrator rights are required; the elevation prompt was disabled.' } else { 'Administrator rights are required; no interactive prompt is available.' }
        foreach ($name in $Names) { [void]$Results.Add((New-Outcome -Name $name -Global:$true -Status Skipped -Category Elevation -Reason $reason)) }
        return
    }
    if (!(Confirm-ElevationRetry -Count $Names.Count)) {
        foreach ($name in $Names) { [void]$Results.Add((New-Outcome -Name $name -Global:$true -Status Skipped -Category Elevation -Reason 'Administrator retry was declined.')) }
        return
    }
    $response = Invoke-ElevatedBatch -Apps $Names
    $returned = @{}
    foreach ($outcome in @($response.Results)) {
        [void]$Results.Add($outcome)
        # Tidy returns multiple item-level results, so reconcile the parent app.
        $returned[([string]$outcome.Name -split '/')[0]] = $true
    }
    if ($response.State -ne 'Completed') {
        $status = if ($response.State -eq 'Canceled') { 'Skipped' } else { 'Failed' }
        $category = if ($response.State -eq 'Canceled') { 'ElevationCanceled' } else { 'ElevationFailed' }
        foreach ($name in $Names) {
            if (!$returned.ContainsKey($name)) { [void]$Results.Add((New-Outcome -Name $name -Global:$true -Status $status -Category $category -Reason $response.Error)) }
        }
    }
}

function Invoke-MaintenanceCommand {
    param([string] $Operation, [AllowEmptyCollection()][string[]] $CommandArguments)
    $script:Operation = $Operation
    $script:CoreDirectory = ''
    try { $script:Options = Read-CommandOptions -Operation $Operation -Arguments $CommandArguments }
    catch { Write-Error $_.Exception.Message; Show-CommandUsage $Operation; return 1 }
    if ($script:Options.Help) { Show-CommandUsage $Operation; return 0 }
    $script:ForwardOptions = @($script:Options.Forward)
    $syncOnly = $Operation -eq 'upgrade' -and !$script:Options.All -and !$script:Options.Apps.Count
    if ($Operation -eq 'tidy' -and !$script:Options.All -and !$script:Options.Apps.Count) {
        Write-Error '<app> missing'; Show-CommandUsage $Operation; return 1
    }
    if ($syncOnly -and ($script:Options.Global -or '--no-cache' -in $script:ForwardOptions)) {
        Write-Error '--global and --no-cache require an app or --all.'; return 1
    }
    try { $script:ScoopCommand = Resolve-ScoopCommand }
    catch { Write-Error $_.Exception.Message; return 2 }
    if ($syncOnly) {
        $result = Invoke-ScoopCommand -ArgumentList @('update')
        $outcome = ConvertTo-AppOutcome -Name 'Scoop and buckets' -CommandResult $result
        if ($outcome.Status -eq 'Failed') { return 1 }; return 0
    }
    $results = [System.Collections.Generic.List[object]]::new()
    if ($Operation -eq 'upgrade' -and ('scoop' -in $script:Options.Apps -or (Test-ScoopSyncNeeded))) {
        $syncResult = Invoke-ScoopCommand -ArgumentList @('update')
        $outcome = ConvertTo-AppOutcome -Name 'Scoop and buckets' -CommandResult $syncResult
        if ($outcome.Status -eq 'Failed') { [void]$results.Add($outcome); Write-Warning 'Synchronization failed. Continuing with available manifests.' }
    }
    if ($Operation -eq 'upgrade' -and !$script:Options.All -and @($script:Options.Apps | Where-Object { $_ -ne 'scoop' }).Count -eq 0) {
        Write-Summary -Results $results
        return [int](@($results | Where-Object { $_.Status -eq 'Failed' }).Count -gt 0)
    }
    try {
        $export = Get-ScoopExport
        $targets = @(Get-AppTargets -Export $export -Options $script:Options -Results $results)
        if ($Operation -eq 'tidy') { $script:CoreDirectory = Get-ScoopCoreDirectory }
    } catch {
        [void]$results.Add((New-Outcome -Name 'Installed app discovery' -Status Failed -Category Discovery -Reason $_.Exception.Message -ExitCode 2))
        Write-Summary -Results $results; return 2
    }
    $isAdministrator = Test-IsAdministrator
    $globalNames = [System.Collections.Generic.List[string]]::new()
    foreach ($app in $targets) {
        if ($Operation -eq 'upgrade' -and (Test-AppInfoFlag -Info $app.Info -Flag 'Held package')) {
            [void]$results.Add((New-Outcome -Name $app.Name -Global:$app.Global -Status Skipped -Category Held -Reason 'The package is held.')); continue
        }
        if ($app.Global -and !$isAdministrator) { [void]$globalNames.Add($app.Name); continue }
        Write-Host "Checking $($app.Name)..." -ForegroundColor Cyan
        foreach ($outcome in @(Invoke-AppOperation -Name $app.Name -Global:$app.Global)) { [void]$results.Add($outcome) }
    }
    Complete-GlobalBatch -Names $globalNames.ToArray() -Results $results
    if ($Operation -eq 'tidy' -and '--cache' -in $script:ForwardOptions) {
        foreach ($outcome in @(Invoke-TidyProcess -Name 'Partial downloads' -PartialDownloads)) { [void]$results.Add($outcome) }
    }
    Write-Summary -Results $results
    return [int](@($results | Where-Object { $_.Status -eq 'Failed' }).Count -gt 0)
}
