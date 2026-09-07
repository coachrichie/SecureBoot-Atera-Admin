[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [switch]$WhatIf,

    [Parameter(Mandatory = $false)]
    [switch]$Force,

    [Parameter(Mandatory = $false)]
    [switch]$RebootAfterUpdate,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath,

    [Parameter(Mandatory = $false)]
    [string]$TenantName,

    [Parameter(Mandatory = $false)]
    [string]$CustomerName,

    [Parameter(Mandatory = $false)]
    [string]$DeviceName,

    [Parameter(Mandatory = $false)]
    [AllowNull()]
    [Nullable[bool]]$BitLockerEscrowVerified = $null
)

$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$commonPath = Join-Path $scriptDirectory 'SecureBoot.Common.ps1'
$inventoryPath = Join-Path $scriptDirectory 'Invoke-SecureBootInventory.ps1'

if (Test-Path $commonPath) {
    . $commonPath
}

if (Test-Path $inventoryPath) {
    . $inventoryPath
}

$script:SecureBootItManagedAvailableUpdatesValue = 0x5944
$script:SecureBootUpdateTaskPath = '\Microsoft\Windows\PI\'
$script:SecureBootUpdateTaskName = 'Secure-Boot-Update'

function Test-SecureBootSupportedOs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$Record
    )

    $build = 0
    if ($Record -and $Record.OsBuildNumber) {
        [void][int]::TryParse([string]$Record.OsBuildNumber, [ref]$build)
    }

    return $build -ge 19041
}

function Test-SecureBootServerOs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$Record
    )

    if ($Record -and $null -ne $Record.IsServer) {
        return [bool]$Record.IsServer
    }

    if ($Record -and $Record.OsCaption) {
        return ([string]$Record.OsCaption) -match 'Windows Server'
    }

    return $false
}

function Get-SecureBootRecordValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$Record,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($null -eq $Record) {
        return $null
    }

    $property = $Record.PSObject.Properties[$Name]
    if (-not $property) {
        return $null
    }

    return $property.Value
}

function Test-SecureBootKnownFact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return $false
    }

    if ($Value -is [string]) {
        return -not [string]::IsNullOrWhiteSpace($Value)
    }

    return $true
}

function Test-SecureBootKnownOsBuildFact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$Record
    )

    $buildValue = Get-SecureBootRecordValue -Record $Record -Name 'OsBuildNumber'
    if (-not (Test-SecureBootKnownFact -Value $buildValue)) {
        return $false
    }

    $build = 0
    return [int]::TryParse([string]$buildValue, [ref]$build)
}

function Test-SecureBootKnownServerOsFact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$Record
    )

    $isServer = Get-SecureBootRecordValue -Record $Record -Name 'IsServer'
    if (Test-SecureBootKnownFact -Value $isServer) {
        return $true
    }

    $osCaption = Get-SecureBootRecordValue -Record $Record -Name 'OsCaption'
    return (Test-SecureBootKnownFact -Value $osCaption)
}

function Test-SecureBootExplicitTrue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$Value
    )

    if ($Value -is [bool]) {
        return $Value
    }

    if ($Value -is [string]) {
        return $Value.Trim() -ceq 'true'
    }

    return $false
}

function Get-SecureBootBitLockerEscrowVerifiedFact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$Record,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [Nullable[bool]]$ExplicitValue
    )

    if ($null -ne $ExplicitValue) {
        return $ExplicitValue
    }

    return Get-SecureBootRecordValue -Record $Record -Name 'BitLockerEscrowVerified'
}

function New-SecureBootForcePreflightBlock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$UnknownFacts
    )

    $facts = ($UnknownFacts | Sort-Object -Unique) -join ', '

    return @{
        Status = 'BLOCKED'
        ReasonCode = 'PREFLIGHT_FACTS_UNKNOWN'
        Recommendation = "Resolve missing or unknown preflight facts before using -Force: $facts."
        ExitCode = 20
    }
}

function Get-SecureBootForcePreflightBlock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [hashtable]$Preflight,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [Nullable[bool]]$BitLockerEscrowVerified
    )

    $unknownFacts = @()
    $record = if ($Preflight) { $Preflight.Record } else { $null }

    if (-not $Preflight -or -not (Test-SecureBootKnownFact -Value $Preflight.Status)) {
        $unknownFacts += 'PreflightStatus'
    }

    if (-not $Preflight -or -not (Test-SecureBootKnownFact -Value $Preflight.ReasonCode)) {
        $unknownFacts += 'PreflightReasonCode'
    }

    foreach ($factName in @('SecureBootCapable', 'SecureBootEnabled')) {
        if (-not (Test-SecureBootKnownFact -Value (Get-SecureBootRecordValue -Record $record -Name $factName))) {
            $unknownFacts += $factName
        }
    }

    $escrowVerified = Get-SecureBootBitLockerEscrowVerifiedFact -Record $record -ExplicitValue $BitLockerEscrowVerified
    if (-not (Test-SecureBootKnownFact -Value $escrowVerified)) {
        $unknownFacts += 'BitLockerEscrowVerified'
    }

    if ($unknownFacts.Count -gt 0) {
        return New-SecureBootForcePreflightBlock -UnknownFacts $unknownFacts
    }

    if (-not (Test-SecureBootExplicitTrue -Value $escrowVerified)) {
        return @{
            Status = 'BLOCKED'
            ReasonCode = 'BITLOCKER_ESCROW_NOT_VERIFIED'
            Recommendation = 'Set BitLockerEscrowVerified=true only after external escrow verification. A local recovery protector is not proof of escrow.'
            ExitCode = 20
        }
    }

    return $null
}

function Invoke-SecureBootUpdatePreflight {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$TenantName,

        [Parameter(Mandatory = $false)]
        [string]$CustomerName,

        [Parameter(Mandatory = $false)]
        [string]$DeviceName,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [Nullable[bool]]$BitLockerEscrowVerified
    )

    if (Get-Command -Name Invoke-SecureBootInventory -ErrorAction SilentlyContinue) {
        $inventoryParameters = @{}

        if ($TenantName) {
            $inventoryParameters.TenantName = $TenantName
        }

        if ($CustomerName) {
            $inventoryParameters.CustomerName = $CustomerName
        }

        if ($DeviceName) {
            $inventoryParameters.DeviceName = $DeviceName
        }

        if ($null -ne $BitLockerEscrowVerified) {
            $inventoryParameters.BitLockerEscrowVerified = $BitLockerEscrowVerified
        }

        $inventory = Invoke-SecureBootInventory @inventoryParameters
        $record = $inventory.Record

        return @{
            Status = $record.Status
            ReasonCode = $record.ReasonCode
            Recommendation = $record.Recommendation
            Record = $record
        }
    }

    return @{
        Status = 'FAILED'
        ReasonCode = 'INVENTORY_UNAVAILABLE'
        Recommendation = 'Run from the scripts directory with Invoke-SecureBootInventory.ps1 present.'
        Record = [pscustomobject]@{}
    }
}

function Invoke-SecureBootUpdateHandoff {
    [CmdletBinding()]
    param()

    $registryPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot'
    $registryName = 'AvailableUpdates'
    $registryValue = $script:SecureBootItManagedAvailableUpdatesValue
    $registrySignaled = $false

    if (-not (Test-Path -LiteralPath $registryPath)) {
        throw "Supported Secure Boot update registry path is not present: $registryPath"
    }

    $currentValue = $null
    try {
        $state = Get-ItemProperty -LiteralPath $registryPath -Name $registryName -ErrorAction SilentlyContinue
        if ($state) {
            $currentValue = $state.$registryName
        }
    }
    catch {
        $currentValue = $null
    }

    if ($currentValue -eq 0x4000) {
        return @{
            Stage = 'FINAL_STATE_REACHED'
            RegistrySignaled = $false
            RegistryPath = $registryPath
            RegistryName = $registryName
            RegistryValue = 0x4000
            PreviousRegistryValue = $currentValue
            ExpectedNextRegistryValue = $null
            RebootRequired = $false
            RebootMarkerRequired = $false
            ScheduledTaskPresent = $null
            ScheduledTaskStarted = $false
            ScheduledTaskName = "$($script:SecureBootUpdateTaskPath)$($script:SecureBootUpdateTaskName)"
        }
    }

    try {
        $task = Get-ScheduledTask -TaskPath $script:SecureBootUpdateTaskPath -TaskName $script:SecureBootUpdateTaskName -ErrorAction Stop
    }
    catch {
        throw "Required Secure Boot update scheduled task is missing: $($script:SecureBootUpdateTaskPath)$($script:SecureBootUpdateTaskName)"
    }

    if (-not $task) {
        throw "Required Secure Boot update scheduled task is missing: $($script:SecureBootUpdateTaskPath)$($script:SecureBootUpdateTaskName)"
    }

    $stage = 'INITIAL_TASK_STARTED'
    $rebootRequired = $true
    $expectedNextRegistryValue = 0x4100

    if ($currentValue -eq 0x4100) {
        $stage = 'POST_REBOOT_TASK_STARTED'
        $rebootRequired = $false
        $expectedNextRegistryValue = 0x4000
        $registryValue = 0x4100
    }
    elseif ($null -eq $currentValue) {
        New-ItemProperty -LiteralPath $registryPath -Name $registryName -PropertyType DWord -Value $registryValue -Force -ErrorAction Stop | Out-Null
        $registrySignaled = $true
    }
    elseif ($currentValue -ne $registryValue) {
        Set-ItemProperty -LiteralPath $registryPath -Name $registryName -Value $registryValue -ErrorAction Stop
        $registrySignaled = $true
    }

    try {
        Start-ScheduledTask -TaskPath $script:SecureBootUpdateTaskPath -TaskName $script:SecureBootUpdateTaskName -ErrorAction Stop
    }
    catch {
        throw "Required Secure Boot update scheduled task failed to start: $($script:SecureBootUpdateTaskPath)$($script:SecureBootUpdateTaskName)"
    }

    return @{
        Stage = $stage
        RegistrySignaled = $registrySignaled
        RegistryPath = $registryPath
        RegistryName = $registryName
        RegistryValue = $registryValue
        PreviousRegistryValue = $currentValue
        ExpectedNextRegistryValue = $expectedNextRegistryValue
        RebootRequired = $rebootRequired
        RebootMarkerRequired = $true
        ScheduledTaskPresent = $true
        ScheduledTaskStarted = $true
        ScheduledTaskName = "$($script:SecureBootUpdateTaskPath)$($script:SecureBootUpdateTaskName)"
    }
}

function Invoke-SecureBootCertificateUpdate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf,

        [Parameter(Mandatory = $false)]
        [switch]$Force,

        [Parameter(Mandatory = $false)]
        [switch]$RebootAfterUpdate,

        [Parameter(Mandatory = $false)]
        [string]$OutputPath,

        [Parameter(Mandatory = $false)]
        [string]$TenantName,

        [Parameter(Mandatory = $false)]
        [string]$CustomerName,

        [Parameter(Mandatory = $false)]
        [string]$DeviceName,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [Nullable[bool]]$BitLockerEscrowVerified = $null
    )

    $outputDirectory = if ($OutputPath) {
        Split-Path -Parent $OutputPath
    }
    else {
        Join-Path $env:TEMP 'SecureBootCertificateUpdate'
    }

    if (-not $outputDirectory) {
        $outputDirectory = (Get-Location).Path
    }

    if (-not (Test-Path -LiteralPath $outputDirectory)) {
        New-Item -Path $outputDirectory -ItemType Directory -Force | Out-Null
    }

    if (-not $OutputPath) {
        $OutputPath = Join-Path $outputDirectory 'secureboot-update-result.json'
    }

    $transcriptPath = Join-Path $outputDirectory 'secureboot-update-transcript.log'
    $markerPath = Join-Path $outputDirectory 'secureboot-update-reboot-required.marker'
    $transcriptStarted = $false

    try {
        Start-Transcript -LiteralPath $transcriptPath -Append -ErrorAction Stop | Out-Null
        $transcriptStarted = $true
    }
    catch {
    }

    $exitCode = 0
    $handoff = $null
    $mutationAttempted = $false
    $preflight = Invoke-SecureBootUpdatePreflight -TenantName $TenantName -CustomerName $CustomerName -DeviceName $DeviceName -BitLockerEscrowVerified $BitLockerEscrowVerified
    $preflightRecord = $preflight.Record
    $bitLockerEscrowVerifiedFact = Get-SecureBootBitLockerEscrowVerifiedFact -Record $preflightRecord -ExplicitValue $BitLockerEscrowVerified
    $status = $preflight.Status
    $reasonCode = $preflight.ReasonCode
    $recommendation = $preflight.Recommendation

    try {
        if ($Force -and -not (Test-SecureBootKnownOsBuildFact -Record $preflightRecord)) {
            $block = New-SecureBootForcePreflightBlock -UnknownFacts @('OsBuildNumber')
            $status = $block.Status
            $reasonCode = $block.ReasonCode
            $recommendation = $block.Recommendation
            $exitCode = $block.ExitCode
        }
        elseif (-not (Test-SecureBootSupportedOs -Record $preflightRecord)) {
            $status = 'UNSUPPORTED'
            $reasonCode = 'UNSUPPORTED_OS_BUILD'
            $recommendation = 'Run only on supported Windows builds for the Secure Boot certificate update.'
            $exitCode = 30
        }
        elseif (Test-SecureBootServerOs -Record $preflightRecord) {
            $status = 'UNSUPPORTED'
            $reasonCode = 'SERVER_SEPARATE_ROLLOUT'
            $recommendation = 'Windows Server requires an explicit server-supported rollout mode; client handoff was not applied.'
            $exitCode = 30
        }
        elseif ($Force -and -not (Test-SecureBootKnownServerOsFact -Record $preflightRecord)) {
            $block = New-SecureBootForcePreflightBlock -UnknownFacts @('IsServer')
            $status = $block.Status
            $reasonCode = $block.ReasonCode
            $recommendation = $block.Recommendation
            $exitCode = $block.ExitCode
        }
        elseif (-not $Force) {
            $status = 'ASSESSMENT_ONLY'
            $reasonCode = 'FORCE_REQUIRED_FOR_UPDATE'
            $recommendation = 'Re-run with -Force only after confirming READY_FOR_PILOT preflight status and BitLockerEscrowVerified=true.'
            $exitCode = 0
        }
        else {
            $forcePreflightBlock = Get-SecureBootForcePreflightBlock -Preflight $preflight -BitLockerEscrowVerified $BitLockerEscrowVerified

            if ($forcePreflightBlock) {
                $status = $forcePreflightBlock.Status
                $reasonCode = $forcePreflightBlock.ReasonCode
                $recommendation = $forcePreflightBlock.Recommendation
                $exitCode = $forcePreflightBlock.ExitCode
            }
            elseif ($preflight.Status -eq 'UPDATED') {
                $status = 'UPDATED'
                $reasonCode = 'UPDATE_CONFIRMED'
                $recommendation = 'No action required.'
                $exitCode = 0
            }
            elseif ($preflight.Status -notin @('READY_FOR_PILOT', 'UPDATE_PENDING_REBOOT')) {
                $status = 'BLOCKED'
                $reasonCode = $preflight.ReasonCode
                $recommendation = $preflight.Recommendation
                $exitCode = 20
            }
            elseif ($WhatIf) {
                $status = 'WHATIF'
                $reasonCode = 'WHATIF_NO_MUTATION'
                $recommendation = 'No update handoff was staged because -WhatIf was supplied.'
                $exitCode = 0
            }
            else {
                $preflightRegistry = Get-SecureBootRecordValue -Record $preflightRecord -Name 'SecureBootRegistry'
                $preflightAvailableUpdates = Get-SecureBootRecordValue -Record $preflightRegistry -Name 'AvailableUpdates'
                if ($preflight.Status -eq 'UPDATE_PENDING_REBOOT' -and $preflightAvailableUpdates -ne 0x4100) {
                    $status = 'UPDATE_PENDING_REBOOT'
                    $reasonCode = 'REBOOT_REQUIRED'
                    $recommendation = 'Wait for AvailableUpdates=0x4100, reboot the device, then run this task again.'
                    $exitCode = 10
                }
                else {
                    $mutationAttempted = $true
                    $handoff = Invoke-SecureBootUpdateHandoff
                    if ($handoff.RebootMarkerRequired) {
                        New-Item -Path $markerPath -ItemType File -Force | Out-Null
                    }

                    if ($handoff.Stage -eq 'POST_REBOOT_TASK_STARTED') {
                        $status = 'UPDATE_PENDING_REBOOT'
                        $reasonCode = 'FINALIZATION_TASK_STARTED'
                        $recommendation = 'Wait for AvailableUpdates=0x4000, then run inventory and verification again.'
                        $exitCode = 10
                    }
                    elseif ($handoff.Stage -eq 'FINAL_STATE_REACHED') {
                        $status = 'FAILED'
                        $reasonCode = 'UPDATE_NOT_CONFIRMED'
                        $recommendation = 'AvailableUpdates is final; run inventory and verification to confirm servicing status and success events.'
                        $exitCode = 20
                    }
                    else {
                        $status = 'UPDATE_PENDING_REBOOT'
                        $reasonCode = 'REBOOT_REQUIRED'
                        $recommendation = 'Wait for AvailableUpdates=0x4100, reboot the device, then run this task again.'
                        $exitCode = 10
                    }

                    if ($RebootAfterUpdate -and $handoff.RebootRequired) {
                        Restart-Computer -Force
                    }
                }
            }
        }
    }
    catch {
        $status = 'FAILED'
        $reasonCode = 'HANDOFF_FAILED'
        $recommendation = $_.Exception.Message
        $exitCode = 40
    }

    $record = [ordered]@{
        TenantName = if ($TenantName) { $TenantName } else { Get-SecureBootRecordValue -Record $preflightRecord -Name 'TenantName' }
        CustomerName = if ($CustomerName) { $CustomerName } else { Get-SecureBootRecordValue -Record $preflightRecord -Name 'CustomerName' }
        DeviceName = if ($DeviceName) { $DeviceName } else { Get-SecureBootRecordValue -Record $preflightRecord -Name 'DeviceName' }
        TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
        Status = $status
        ReasonCode = $reasonCode
        Recommendation = $recommendation
        PreflightStatus = $preflight.Status
        PreflightReasonCode = $preflight.ReasonCode
        BitLockerEscrowVerified = $bitLockerEscrowVerifiedFact
        MutationAttempted = $mutationAttempted
        Force = [bool]$Force
        WhatIf = [bool]$WhatIf
        RebootAfterUpdate = [bool]$RebootAfterUpdate
        ResultPath = $OutputPath
        TranscriptPath = $transcriptPath
        RebootMarkerPath = if (Test-Path -LiteralPath $markerPath) { $markerPath } else { $null }
        Handoff = if ($handoff) { [pscustomobject]$handoff } else { $null }
    }

    $json = $record | ConvertTo-Json -Depth 6 -Compress
    Set-Content -LiteralPath $OutputPath -Value $json -Encoding UTF8

    if ($transcriptStarted) {
        try {
            Stop-Transcript | Out-Null
        }
        catch {
        }
    }

    return @{
        ExitCode = $exitCode
        Record = [pscustomobject]$record
        Json = $json
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $invokeParameters = @{
        WhatIf = $WhatIf
        Force = $Force
        RebootAfterUpdate = $RebootAfterUpdate
        OutputPath = $OutputPath
        TenantName = $TenantName
        CustomerName = $CustomerName
        DeviceName = $DeviceName
    }

    if ($null -ne $BitLockerEscrowVerified) {
        $invokeParameters.BitLockerEscrowVerified = $BitLockerEscrowVerified
    }

    $result = Invoke-SecureBootCertificateUpdate @invokeParameters
    Write-Output $result.Json
    exit $result.ExitCode
}
