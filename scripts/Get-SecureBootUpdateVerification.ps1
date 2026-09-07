[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$InputPath,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath
)

$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$commonPath = Join-Path $scriptDirectory 'SecureBoot.Common.ps1'

if (Test-Path $commonPath) {
    . $commonPath
}

function Get-SecureBootPropertyValue {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$Object,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($property) {
        return $property.Value
    }

    return $null
}

function Test-SecureBootTruth {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$Value
    )

    if (Get-Command -Name ConvertTo-SecureBootBoolean -ErrorAction SilentlyContinue) {
        return ConvertTo-SecureBootBoolean $Value
    }

    if ($null -eq $Value) {
        return $false
    }

    if ($Value -is [bool]) {
        return $Value
    }

    if ($Value -is [string]) {
        return $Value.Trim() -match '^(?i:true|yes|1)$'
    }

    return [bool]$Value
}

function Test-SecureBoot2023StatusComplete {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return $false
    }

    return ([string]$Value) -ceq 'Updated'
}

function Get-SecureBootEventCount {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$EventLog,

        [Parameter(Mandatory = $true)]
        [int]$EventId
    )

    return [int](Get-SecureBootPropertyValue -Object $EventLog -Name "Event$($EventId)Count")
}

function ConvertTo-SecureBootAvailableUpdatesValue {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$Value
    )

    $updatesValue = 0
    if ($null -eq $Value) {
        return $null
    }

    if ([int]::TryParse([string]$Value, [ref]$updatesValue)) {
        return $updatesValue
    }

    return $null
}

function Test-SecureBootErrorPresent {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $false
    }

    return ([string]$Value -notin @('0', '0x0', '0X0'))
}

function New-SecureBootVerificationRecord {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Inventory,

        [Parameter(Mandatory = $true)]
        [string]$Status,

        [Parameter(Mandatory = $true)]
        [string]$ReasonCode,

        [Parameter(Mandatory = $true)]
        [string]$Recommendation
    )

    return [ordered]@{
        TenantName = Get-SecureBootPropertyValue -Object $Inventory -Name 'TenantName'
        CustomerName = Get-SecureBootPropertyValue -Object $Inventory -Name 'CustomerName'
        DeviceName = Get-SecureBootPropertyValue -Object $Inventory -Name 'DeviceName'
        TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
        Status = $Status
        ReasonCode = $ReasonCode
        Recommendation = $Recommendation
        SourceStatus = Get-SecureBootPropertyValue -Object $Inventory -Name 'Status'
        SourceReasonCode = Get-SecureBootPropertyValue -Object $Inventory -Name 'ReasonCode'
        RebootMarkerPath = Get-SecureBootPropertyValue -Object $Inventory -Name 'RebootMarkerPath'
    }
}

function Get-SecureBootUpdateVerification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputPath,

        [Parameter(Mandatory = $false)]
        [string]$OutputPath
    )

    try {
        $inventory = Get-Content -LiteralPath $InputPath -Raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        $record = [ordered]@{
            TenantName = $null
            CustomerName = $null
            DeviceName = $null
            TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
            Status = 'FAILED'
            ReasonCode = 'INVALID_INPUT'
            Recommendation = 'Provide a valid inventory JSON file before running verification.'
            SourceStatus = $null
            SourceReasonCode = $null
        }
        $json = $record | ConvertTo-Json -Depth 6 -Compress

        if ($OutputPath) {
            Set-Content -LiteralPath $OutputPath -Value $json -Encoding UTF8
        }

        return @{
            ExitCode = 20
            Record = [pscustomobject]$record
            Json = $json
        }
    }

    $registry = Get-SecureBootPropertyValue -Object $inventory -Name 'SecureBootRegistry'
    $eventLog = Get-SecureBootPropertyValue -Object $inventory -Name 'EventLog'
    $updateResult = Get-SecureBootPropertyValue -Object $inventory -Name 'UpdateResult'

    $updateStatus = Get-SecureBootPropertyValue -Object $updateResult -Name 'Status'
    $updateReasonCode = Get-SecureBootPropertyValue -Object $updateResult -Name 'ReasonCode'

    $secureBootEnabled = Test-SecureBootTruth (Get-SecureBootPropertyValue -Object $inventory -Name 'SecureBootEnabled')
    $bitLockerReady = Test-SecureBootTruth (Get-SecureBootPropertyValue -Object $inventory -Name 'BitLockerRecoveryAvailable')
    $escrowVerified = Test-SecureBootTruth (Get-SecureBootPropertyValue -Object $inventory -Name 'BitLockerEscrowVerified')
    $uefi2023Status = Get-SecureBootPropertyValue -Object $registry -Name 'UEFICA2023Status'
    $uefi2023Error = Get-SecureBootPropertyValue -Object $registry -Name 'UEFICA2023Error'
    $uefi2023Ready = Test-SecureBoot2023StatusComplete $uefi2023Status
    $availableUpdates = ConvertTo-SecureBootAvailableUpdatesValue (Get-SecureBootPropertyValue -Object $registry -Name 'AvailableUpdates')
    $event1795Count = Get-SecureBootEventCount -EventLog $eventLog -EventId 1795
    $event1799Count = Get-SecureBootEventCount -EventLog $eventLog -EventId 1799
    $event1800Count = Get-SecureBootEventCount -EventLog $eventLog -EventId 1800
    $event1801Count = Get-SecureBootEventCount -EventLog $eventLog -EventId 1801
    $event1803Count = Get-SecureBootEventCount -EventLog $eventLog -EventId 1803
    $event1808Count = Get-SecureBootEventCount -EventLog $eventLog -EventId 1808
    $successEventCount = $event1799Count + $event1808Count
    $blockingEventCount = $event1795Count + $event1800Count + $event1801Count + $event1803Count
    $rebootMarkerPath = Get-SecureBootPropertyValue -Object $inventory -Name 'RebootMarkerPath'
    $rebootMarkerPresent = $false

    if ($rebootMarkerPath) {
        $rebootMarkerPresent = Test-Path -LiteralPath $rebootMarkerPath
    }

    $status = 'FAILED'
    $reasonCode = 'VERIFICATION_FAILED'
    $recommendation = 'Investigate Secure Boot update state before continuing rollout.'
    $exitCode = 20

    if ($updateStatus -eq 'FAILED') {
        $reasonCode = if ($updateReasonCode) { $updateReasonCode } else { 'UPDATE_FAILED' }
        $recommendation = 'Investigate the update result before continuing rollout.'
    }
    elseif (Test-SecureBootErrorPresent $uefi2023Error) {
        $reasonCode = 'UEFICA2023_ERROR'
        $recommendation = 'Resolve the UEFICA2023Error reported by servicing data before continuing rollout.'
    }
    elseif (-not $secureBootEnabled) {
        $reasonCode = 'SECURE_BOOT_DISABLED'
        $recommendation = 'Enable Secure Boot in firmware before rollout.'
    }
    elseif (-not $bitLockerReady -or -not $escrowVerified) {
        $reasonCode = 'BITLOCKER_RECOVERY_NOT_AVAILABLE'
        $recommendation = 'Verify BitLocker recovery before continuing rollout.'
    }
    elseif ($uefi2023Ready -and -not (Test-SecureBootErrorPresent $uefi2023Error) -and $availableUpdates -eq 0x4000 -and $successEventCount -gt 0 -and $blockingEventCount -eq 0) {
        $status = 'UPDATED'
        $reasonCode = 'UPDATE_CONFIRMED'
        $recommendation = 'No action required.'
        $exitCode = 0

        if ($rebootMarkerPresent) {
            Remove-Item -LiteralPath $rebootMarkerPath -Force
        }
    }
    elseif ($blockingEventCount -gt 0) {
        $reasonCode = 'UPDATE_NOT_CONFIRMED'
        $recommendation = 'Investigate Microsoft Secure Boot servicing event signals before continuing rollout.'
    }
    elseif ($rebootMarkerPresent -or ($availableUpdates -in 0x5944, 0x4100)) {
        $status = 'UPDATE_PENDING_REBOOT'
        $reasonCode = 'REBOOT_REQUIRED'
        $recommendation = 'Restart the device and re-run verification.'
        $exitCode = 10
    }

    $record = New-SecureBootVerificationRecord -Inventory $inventory -Status $status -ReasonCode $reasonCode -Recommendation $recommendation
    $json = $record | ConvertTo-Json -Depth 6 -Compress

    if ($OutputPath) {
        Set-Content -LiteralPath $OutputPath -Value $json -Encoding UTF8
    }

    return @{
        ExitCode = $exitCode
        Record = [pscustomobject]$record
        Json = $json
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $result = Get-SecureBootUpdateVerification -InputPath $InputPath -OutputPath $OutputPath
    Write-Output $result.Json
    exit $result.ExitCode
}
