# Shared command execution, diagnostics, summaries and elevation.

function Resolve-ScoopCommand {
    $override = $env:SCOOP_RESILIENT_SCOOP_COMMAND
    if (!$override) { $override = $env:SCOOP_UPGRADE_SCOOP_COMMAND }
    if ($override) {
        if (Test-Path -LiteralPath $override -PathType Leaf) {
            return (Resolve-Path -LiteralPath $override).Path
        }

        throw "SCOOP_UPGRADE_SCOOP_COMMAND does not point to a file: $override"
    }

    $command = Get-Command 'scoop.cmd' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $command) {
        throw "Could not find 'scoop.cmd' on PATH. Install Scoop or repair its shim first."
    }

    return $command.Source
}

function Invoke-ScoopCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string[]] $ArgumentList,
        [switch] $SuppressOutput
    )

    $output = [System.Collections.Generic.List[string]]::new()
    try {
        # Windows PowerShell turns native stderr into ErrorRecords. Do not stop
        # draining the process output merely because an app writes to stderr.
        $ErrorActionPreference = 'Continue'
        $PSNativeCommandUseErrorActionPreference = $false
        $global:LASTEXITCODE = $null
        & $script:ScoopCommand @ArgumentList 2>&1 | ForEach-Object {
            $line = $_.ToString()
            [void] $output.Add($line)
            if (!$SuppressOutput) {
                Write-Host $line
            }
        }
        $pipelineSucceeded = $?
        $nativeExitCode = $global:LASTEXITCODE
        $exitCode = if ($null -eq $nativeExitCode) {
            if ($pipelineSucceeded) { 0 } else { 1 }
        } else {
            [int] $nativeExitCode
        }
    } catch {
        $line = $_.Exception.Message
        [void] $output.Add($line)
        if (!$SuppressOutput) {
            Write-Host $line
        }
        $exitCode = 1
    }

    return [PSCustomObject]@{
        ExitCode = $exitCode
        Output = [string[]] $output.ToArray()
        Arguments = [string[]] $ArgumentList
    }
}

function Get-ScoopExport {
    $result = Invoke-ScoopCommand -ArgumentList @('export') -SuppressOutput
    if ($result.ExitCode -ne 0) {
        $reason = Get-DiagnosticReason -Output $result.Output -Fallback "Scoop exited with code $($result.ExitCode)."
        throw "'scoop export' failed with exit code $($result.ExitCode): $reason"
    }

    $json = $result.Output -join [Environment]::NewLine
    if ([string]::IsNullOrWhiteSpace($json)) {
        throw "'scoop export' returned no data."
    }

    try {
        return $json | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "Could not parse 'scoop export' output: $($_.Exception.Message)"
    }
}

function Test-AppInfoFlag {
    param(
        [AllowEmptyString()]
        [string] $Info,
        [Parameter(Mandatory = $true)]
        [string] $Flag
    )

    if ([string]::IsNullOrWhiteSpace($Info)) {
        return $false
    }

    return @($Info -split ', ') -contains $Flag
}

function Test-IsAdministrator {
    if ($env:SCOOP_RESILIENT_TEST_IS_ADMINISTRATOR -in @('true', 'false')) {
        return [Convert]::ToBoolean($env:SCOOP_RESILIENT_TEST_IS_ADMINISTRATOR)
    }

    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        return ([Security.Principal.WindowsPrincipal]($identity)).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator
        )
    } catch {
        return $false
    }
}

function Get-CleanOutputLines {
    param(
        [AllowEmptyCollection()]
        [string[]] $Output
    )

    $cleaned = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in @($Output)) {
        foreach ($line in @($entry -split '\r?\n')) {
            $text = ($line -replace '\x1B\[[0-?]*[ -/]*[@-~]', '').Trim()
            if (![string]::IsNullOrWhiteSpace($text)) {
                [void] $cleaned.Add($text)
            }
        }
    }
    return [string[]] $cleaned.ToArray()
}

function Get-DiagnosticReason {
    param(
        [AllowEmptyCollection()]
        [string[]] $Output,
        [string] $Pattern,
        [Parameter(Mandatory = $true)]
        [string] $Fallback
    )

    $lines = @(Get-CleanOutputLines -Output $Output)
    if ($Pattern) {
        $match = $lines | Where-Object { $_ -match $Pattern } | Select-Object -First 1
        if ($match) {
            if ($match.Length -gt 240) {
                return "$($match.Substring(0, 237))..."
            }
            return $match
        }
    }

    $diagnostic = $lines | Where-Object {
        $_ -notmatch '^(At .+\.ps1:\d+ char:|\+ |CategoryInfo\s*:|FullyQualifiedErrorId\s*:|Checking |Updating |Downloading new version$)'
    } | Select-Object -Last 1
    if (!$diagnostic) {
        return $Fallback
    }
    if ($diagnostic.Length -gt 240) {
        return "$($diagnostic.Substring(0, 237))..."
    }
    return $diagnostic
}

function New-Outcome {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,
        [Parameter(Mandatory = $true)]
        [ValidateSet('Completed', 'Current', 'Failed', 'Skipped')]
        [string] $Status,
        [Parameter(Mandatory = $true)]
        [string] $Category,
        [Parameter(Mandatory = $true)]
        [string] $Reason,
        [int] $ExitCode = 0,
        [bool] $Global = $false,
        [AllowEmptyCollection()]
        [string[]] $Details = @()
    )

    return [PSCustomObject]@{
        Name = $Name
        Label = if ($Global) { "$Name (global)" } else { $Name }
        Status = $Status
        Category = $Category
        Reason = $Reason
        ExitCode = $ExitCode
        Global = $Global
        Details = [string[]] $Details
    }
}

function ConvertTo-AppOutcome {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,
        [bool] $Global,
        [Parameter(Mandatory = $true)]
        [PSCustomObject] $CommandResult
    )

    $text = @(Get-CleanOutputLines -Output $CommandResult.Output) -join [Environment]::NewLine
    $definitions = @(
        @{
            Category = 'Running'; Pattern = '(?i)Running process detected|still running\. Close them and try again'
            Reason = 'The application is running. Close it and retry.'
        },
        @{
            Category = 'Elevation'; Pattern = '(?i)need admin rights|administrator rights|requested operation requires elevation|elevation required'
            Reason = 'Administrator rights are required.'
        },
        @{
            Category = 'Permission'; Pattern = '(?i)access (?:is )?denied|UnauthorizedAccessException|permission denied'
            Reason = 'Access was denied.'
        },
        @{
            Category = 'Hash'; Pattern = '(?i)hash check failed|hash.*(?:does not match|mismatch)|expected.*hash'
            Reason = 'The downloaded file failed hash validation.'
        },
        @{
            Category = 'Download'; Pattern = '(?i)URL .+ is not valid|Download failed|remote server returned an error|response status code does not indicate success|\b(?:403|404)\b|timed out|unable to connect|name resolution'
            Reason = 'The package could not be downloaded.'
        },
        @{
            Category = 'Manifest'; Pattern = '(?i)No manifest available|Error parsing JSON|Error in manifest|manifest.*(?:missing|invalid|unsupported)'
            Reason = 'The package manifest is unavailable or invalid.'
        },
        @{
            Category = 'InUse'; Pattern = '(?i)Folder in use|may be in use|being used by another process|file.*in use|sharing violation'
            Reason = 'A required file or directory is in use.'
        },
        @{
            Category = 'Extraction'; Pattern = '(?i)Failed to extract|decompress|7-Zip.*(?:error|failed)|Unzip failed'
            Reason = 'The downloaded package could not be extracted.'
        },
        @{
            Category = 'Installer'; Pattern = '(?i)Installation aborted|Uninstallation aborted|Exit code was'
            Reason = 'The package installer or uninstaller failed.'
        }
    )

    if ($CommandResult.ExitCode -eq 0 -and $text -match '(?im)^ERROR\s|^fatal:|^error:|^Couldn.t find manifest|^Update failed\.') {
        # Preserve explicit errors even when Scoop subsequently prints 'latest version'.
        $diagnostic = Get-DiagnosticReason -Output $CommandResult.Output -Pattern '(?im)^ERROR\s|^fatal:|^error:|^Couldn.t find manifest|^Update failed\.' -Fallback 'Scoop reported an error.'
        if ($text -notmatch '(?i)still running\. Close them and try again') {
            $category = if ($text -match '(?i)manifest') { 'Manifest' } elseif ($text -match "(?i)doesn't support current architecture") { 'Architecture' } else { 'Unknown' }
            return New-Outcome -Name $Name -Global:$Global -Status Failed -Category $category -Reason $diagnostic -Details $CommandResult.Output
        }
    }
    if ($CommandResult.ExitCode -eq 0) {
        if ($text -match '(?i)Running process detected|still running\. Close them and try again') {
            $reason = Get-DiagnosticReason -Output $CommandResult.Output -Pattern '(?i)Running process detected|still running\. Close them and try again' -Fallback 'The application is running. Close it and retry.'
            return New-Outcome -Name $Name -Global:$Global -Status Skipped -Category Running -Reason $reason -Details $CommandResult.Output
        }
        if ($text -match "(?im)(?:latest version of '.+' \(.+\) is already installed|^[A-Za-z0-9_.-]+:\s+.+\s+\(latest version\)\s*$)") {
            $reason = Get-DiagnosticReason -Output $CommandResult.Output -Pattern "(?i)latest version.*already installed|^[A-Za-z0-9_.-]+:\s+.+\s+\(latest version\)\s*$" -Fallback 'The latest version is already installed.'
            return New-Outcome -Name $Name -Global:$Global -Status Current -Category Current -Reason $reason -Details $CommandResult.Output
        }
        if ($text -match '(?i)No manifest available') {
            $reason = Get-DiagnosticReason -Output $CommandResult.Output -Pattern '(?i)No manifest available' -Fallback 'The package manifest is unavailable.'
            return New-Outcome -Name $Name -Global:$Global -Status Failed -Category Manifest -Reason $reason -Details $CommandResult.Output
        }
        if ($text -match "(?i)doesn't support current architecture") {
            $reason = Get-DiagnosticReason -Output $CommandResult.Output -Pattern "(?i)doesn't support current architecture" -Fallback 'The package does not support the current architecture.'
            return New-Outcome -Name $Name -Global:$Global -Status Failed -Category Architecture -Reason $reason -Details $CommandResult.Output
        }

        return New-Outcome -Name $Name -Global:$Global -Status Completed -Category Success -Reason 'Scoop completed the update command.' -Details $CommandResult.Output
    }

    $classification = $null
    foreach ($definition in $definitions) {
        if ($text -match $definition.Pattern) {
            $classification = $definition
            break
        }
    }

    if ($classification) {
        $category = $classification.Category
        $fallback = $classification.Reason
        $pattern = $classification.Pattern
    } else {
        $category = 'Unknown'
        $fallback = "Scoop exited with code $($CommandResult.ExitCode)."
        $pattern = '(?i)error|failed|exception|aborted|denied|invalid'
    }
    $reason = Get-DiagnosticReason -Output $CommandResult.Output -Pattern $pattern -Fallback $fallback
    return New-Outcome -Name $Name -Global:$Global -Status Failed -Category $category -Reason $reason -ExitCode $CommandResult.ExitCode -Details $CommandResult.Output
}

function Write-ResultSection {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Status,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]] $Results,
        [ConsoleColor] $Color = [ConsoleColor]::Gray
    )

    $items = @($Results | Where-Object { $_.Status -eq $Status })
    $displayStatus = if ($script:Operation -eq 'tidy' -and $Status -eq 'Completed') { 'Removed' } else { $Status }
    Write-Host ("  {0}: {1}" -f $displayStatus, $items.Count) -ForegroundColor $Color
    foreach ($item in $items) {
        $exitText = if ($item.ExitCode -ne 0) { " (exit $($item.ExitCode))" } else { '' }
        Write-Host "    - $($item.Label) [$($item.Category)]$exitText" -ForegroundColor $Color
        if ($item.Reason) {
            Write-Host "      $($item.Reason)" -ForegroundColor $Color
        }
    }
}

function Write-Summary {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]] $Results
    )

    Write-Host ''
    Write-Host ("{0} summary" -f (Get-Culture).TextInfo.ToTitleCase($script:Operation)) -ForegroundColor Cyan
    Write-ResultSection -Status Completed -Results $Results -Color Green
    Write-ResultSection -Status Current -Results $Results -Color DarkGreen
    Write-ResultSection -Status Failed -Results $Results -Color Red
    Write-ResultSection -Status Skipped -Results $Results -Color Yellow
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,
        [Parameter(Mandatory = $true)]
        [object] $Value
    )

    $directory = Split-Path -Parent $Path
    if (!(Test-Path -LiteralPath $directory -PathType Container)) {
        throw "Result directory does not exist: $directory"
    }

    $json = $Value | ConvertTo-Json -Depth 8
    $temporaryPath = "$Path.$PID.tmp"
    $utf8NoBom = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($temporaryPath, "$json`n", $utf8NoBom)
    Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
}

function Get-CurrentPowerShellExecutable {
    if ($env:OS -eq 'Windows_NT') {
        $executableName = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
        $command = Get-Command $executableName -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($command) {
            return $command.Source
        }
    }

    return (Get-Process -Id $PID).Path
}

function ConvertTo-QuotedProcessArgument {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Value
    )

    if ($Value.Contains('"')) {
        throw 'An internal process argument contains an unsupported quote character.'
    }
    return '"' + $Value + '"'
}

function Invoke-ElevatedWorkerMode {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Payload,
        [Parameter(Mandatory = $true)]
        [string] $OutputPath
    )

    $workerResults = [System.Collections.Generic.List[object]]::new()
    try {
        if ([string]::IsNullOrWhiteSpace($Payload)) {
            throw 'The elevated worker request is empty.'
        }
        $requestJson = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Payload))
        $request = $requestJson | ConvertFrom-Json -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace([string] $request.ScoopCommand) -or
            !(Test-Path -LiteralPath $request.ScoopCommand -PathType Leaf)) {
            throw 'The elevated worker received an invalid Scoop command path.'
        }

        $script:ScoopCommand = (Resolve-Path -LiteralPath $request.ScoopCommand).Path
        $script:Operation = [string] $request.Operation
        if ($script:Operation -notin @('upgrade', 'tidy')) { throw 'Invalid worker operation.' }
        $script:ForwardOptions = @($request.Options)
        $script:CoreDirectory = [string] $request.CoreDirectory
        foreach ($nameValue in @($request.Apps)) {
            $name = [string] $nameValue
            if ($name -notmatch '^[A-Za-z0-9_.-]+$') {
                [void] $workerResults.Add((New-Outcome -Name $name -Global:$true -Status Failed -Category Discovery -Reason 'The app name is not valid for an elevated request.'))
                continue
            }

            Write-Host ''
            Write-Host "Checking $name (global)..." -ForegroundColor Cyan
            foreach ($outcome in @(Invoke-AppOperation -Name $name -Global $true)) {
                [void] $workerResults.Add($outcome)
            }
        }

        Write-JsonFile -Path $OutputPath -Value @{
            Success = $true
            Results = [object[]] $workerResults.ToArray()
        }
        if (@($workerResults | Where-Object { $_.Status -eq 'Failed' }).Count -gt 0) {
            return 1
        }
        return 0
    } catch {
        try {
            Write-JsonFile -Path $OutputPath -Value @{
                Success = $false
                Error = $_.Exception.Message
                Results = [object[]] $workerResults.ToArray()
            }
        } catch {
            Write-Error $_.Exception.Message
        }
        return 2
    }
}

function Test-CanPromptForElevation {
    if ($script:Options.NoElevationPrompt) {
        return $false
    }
    if ($env:SCOOP_RESILIENT_TEST_ELEVATION_RESPONSE) {
        return $true
    }
    if (![Environment]::UserInteractive -or $Host.Name -eq 'ServerRemoteHost') {
        return $false
    }
    try {
        return ![Console]::IsInputRedirected
    } catch {
        return $true
    }
}

function Confirm-ElevationRetry {
    param([int] $Count)

    $answer = $env:SCOOP_RESILIENT_TEST_ELEVATION_RESPONSE
    if (!$answer) {
        $answer = Read-Host "$Count global app(s) require administrator rights. Retry them with one UAC prompt? [y/N]"
    }
    return $answer -match '^(?i:y|yes)$'
}

function Invoke-ElevatedBatch {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]] $Apps
    )

    switch ($env:SCOOP_RESILIENT_TEST_ELEVATION_STATE) {
        'Canceled' {
            return [PSCustomObject]@{ State = 'Canceled'; Error = 'The UAC request was canceled.'; Results = @() }
        }
        'Failed' {
            return [PSCustomObject]@{ State = 'Failed'; Error = 'The elevated worker could not be started.'; Results = @() }
        }
    }

    $tempDirectory = Join-Path ([IO.Path]::GetTempPath()) "scoop-resilient-elevated-$PID-$([Guid]::NewGuid().ToString('N'))"
    $resultFile = Join-Path $tempDirectory 'result.json'
    try {
        New-Item -ItemType Directory -Path $tempDirectory -ErrorAction Stop | Out-Null
        $request = @{
            ScoopCommand = $script:ScoopCommand
            Apps = [string[]] $Apps
            Operation = $script:Operation
            Options = [string[]] $script:ForwardOptions
            CoreDirectory = $script:CoreDirectory
        } | ConvertTo-Json -Depth 3 -Compress
        $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($request))
        $hostExecutable = Get-CurrentPowerShellExecutable
        $processArguments = @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', (ConvertTo-QuotedProcessArgument -Value $script:EntryPoint),
            '--internal-elevated-worker',
            (ConvertTo-QuotedProcessArgument -Value $payload),
            (ConvertTo-QuotedProcessArgument -Value $resultFile)
        ) -join ' '

        try {
            if ($env:SCOOP_RESILIENT_TEST_ELEVATION_BYPASS -eq 'true') {
                $previousAdministrator = $env:SCOOP_RESILIENT_TEST_IS_ADMINISTRATOR
                try {
                    $env:SCOOP_RESILIENT_TEST_IS_ADMINISTRATOR = 'true'
                    & $hostExecutable -NoProfile -ExecutionPolicy Bypass -File $script:EntryPoint --internal-elevated-worker $payload $resultFile 2>&1 | Out-Host
                    $workerExitCode = $LASTEXITCODE
                } finally { $env:SCOOP_RESILIENT_TEST_IS_ADMINISTRATOR = $previousAdministrator }
            } else {
                if ($env:OS -ne 'Windows_NT') {
                    throw 'UAC elevation is only available on Windows.'
                }
                $startInfo = New-Object Diagnostics.ProcessStartInfo
                $startInfo.FileName = $hostExecutable
                $startInfo.Arguments = $processArguments
                $startInfo.UseShellExecute = $true
                $startInfo.Verb = 'RunAs'
                $process = [Diagnostics.Process]::Start($startInfo)
                $process.WaitForExit()
                $workerExitCode = $process.ExitCode
            }
        } catch {
            $nativeCode = if ($_.Exception.PSObject.Properties.Name -contains 'NativeErrorCode') {
                $_.Exception.NativeErrorCode
            } else {
                $null
            }
            if ($nativeCode -eq 1223 -or $_.Exception.Message -match '(?i)canceled by the user|operation was canceled') {
                return [PSCustomObject]@{ State = 'Canceled'; Error = 'The UAC request was canceled.'; Results = @() }
            }
            return [PSCustomObject]@{ State = 'Failed'; Error = $_.Exception.Message; Results = @() }
        }

        if (!(Test-Path -LiteralPath $resultFile -PathType Leaf)) {
            return [PSCustomObject]@{
                State = 'Failed'
                Error = "The elevated worker exited with code $workerExitCode without returning results."
                Results = @()
            }
        }

        try {
            $response = Get-Content -LiteralPath $resultFile -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        } catch {
            return [PSCustomObject]@{ State = 'Failed'; Error = "Could not read elevated results: $($_.Exception.Message)"; Results = @() }
        }
        if (!$response.Success) {
            return [PSCustomObject]@{ State = 'Failed'; Error = [string] $response.Error; Results = @($response.Results) }
        }
        return [PSCustomObject]@{ State = 'Completed'; Error = ''; Results = @($response.Results) }
    } catch {
        return [PSCustomObject]@{ State = 'Failed'; Error = $_.Exception.Message; Results = @() }
    } finally {
        Remove-Item -LiteralPath $tempDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}
