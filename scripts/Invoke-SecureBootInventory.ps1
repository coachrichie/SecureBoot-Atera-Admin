[CmdletBinding()]
param(
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
    [Nullable[bool]]$BitLockerEscrowVerified = $null,

    [Parameter(Mandatory = $false)]
    [string]$RebootMarkerPath
)

$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$commonPath = Join-Path $scriptDirectory 'SecureBoot.Common.ps1'

if (Test-Path $commonPath) {
    . $commonPath
}

function ConvertTo-UtcTimestampString {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return $null
    }

    try {
        return ([datetime]$Value).ToUniversalTime().ToString('o')
    }
    catch {
        return $null
    }
}

function Get-SecureBootEventSummary {
    [CmdletBinding()]
    param()

    $events = @()
    $eventIds = 1795, 1800, 1801, 1803, 1808, 1799

    try {
        $events += @(Get-WinEvent -FilterHashtable @{
                LogName   = 'System'
                Id        = $eventIds
                StartTime = (Get-Date).AddYears(-2)
            } -ErrorAction Stop)
    }
    catch {
    }

    $filteredEvents = @($events | Where-Object { $_.Id -in $eventIds } | Sort-Object TimeCreated -Descending)
    $latestErrorEvent = $filteredEvents | Where-Object { $_.Id -eq 1795 } | Select-Object -First 1
    $latestSuccessEvent = $filteredEvents | Where-Object { $_.Id -in 1808, 1799 } | Select-Object -First 1

    return @{
        Events = $filteredEvents
        Summary = [ordered]@{
            Event1795Count = @($filteredEvents | Where-Object { $_.Id -eq 1795 }).Count
            Event1799Count = @($filteredEvents | Where-Object { $_.Id -eq 1799 }).Count
            Event1800Count = @($filteredEvents | Where-Object { $_.Id -eq 1800 }).Count
            Event1801Count = @($filteredEvents | Where-Object { $_.Id -eq 1801 }).Count
            Event1803Count = @($filteredEvents | Where-Object { $_.Id -eq 1803 }).Count
            Event1808Count = @($filteredEvents | Where-Object { $_.Id -eq 1808 }).Count
            LatestErrorEventUtc = if ($latestErrorEvent) { ConvertTo-UtcTimestampString $latestErrorEvent.TimeCreated } else { $null }
            LatestSuccessEventUtc = if ($latestSuccessEvent) { ConvertTo-UtcTimestampString $latestSuccessEvent.TimeCreated } else { $null }
            LatestEventId = if ($filteredEvents.Count -gt 0) { $filteredEvents[0].Id } else { $null }
            LatestEventUtc = if ($filteredEvents.Count -gt 0) { ConvertTo-UtcTimestampString $filteredEvents[0].TimeCreated } else { $null }
            RelevantEvents = @(
                foreach ($event in $filteredEvents) {
                    [ordered]@{
                        Id = $event.Id
                        TimeCreatedUtc = ConvertTo-UtcTimestampString $event.TimeCreated
                        ProviderName = $event.ProviderName
                        LogName = $event.LogName
                        Message = $event.Message
                    }
                }
            )
        }
    }
}

function Get-BitLockerInventoryFacts {
    [CmdletBinding()]
    param()

    $cmdlet = Get-Command -Name 'Get-BitLockerVolume' -ErrorAction SilentlyContinue

    if (-not $cmdlet) {
        return @{
            CmdletAvailable = $false
            ProtectionStatus = $null
            RecoveryAvailable = $null
        }
    }

    try {
        $volumes = @(Get-BitLockerVolume -ErrorAction Stop)
    }
    catch {
        return @{
            CmdletAvailable = $true
            ProtectionStatus = $null
            RecoveryAvailable = $null
        }
    }

    $osVolume = $volumes | Where-Object { $_.VolumeType -eq 'OperatingSystem' } | Select-Object -First 1
    if (-not $osVolume) {
        $osVolume = $volumes | Where-Object { $_.MountPoint -eq 'C:' } | Select-Object -First 1
    }

    $recoveryAvailable = $false
    if ($osVolume -and $osVolume.KeyProtector) {
        $recoveryAvailable = @($osVolume.KeyProtector | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' }).Count -gt 0
    }

    return @{
        CmdletAvailable = $true
        ProtectionStatus = if ($osVolume) { $osVolume.ProtectionStatus } else { $null }
        RecoveryAvailable = $recoveryAvailable
    }
}

function Get-InventoryCimInstance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ClassName
    )

    try {
        return Get-CimInstance -ClassName $ClassName -ErrorAction Stop
    }
    catch {
        return [pscustomobject]@{}
    }
}

function Invoke-SecureBootInventory {
    [CmdletBinding()]
    param(
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
        [Nullable[bool]]$BitLockerEscrowVerified = $null,

        [Parameter(Mandatory = $false)]
        [string]$RebootMarkerPath
    )

    $computerSystem = Get-InventoryCimInstance -ClassName 'Win32_ComputerSystem'
    $bios = Get-InventoryCimInstance -ClassName 'Win32_BIOS'
    $operatingSystem = Get-InventoryCimInstance -ClassName 'Win32_OperatingSystem'

    $registryState = $null
    try {
        $registryState = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' -ErrorAction Stop
    }
    catch {
    }

    $registrySecureBoot = $null
    try {
        $registrySecureBoot = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot' -ErrorAction Stop
    }
    catch {
    }

    $registryServicing = $null
    try {
        $registryServicing = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\Servicing' -ErrorAction Stop
    }
    catch {
    }

    $secureBootCmdlet = Get-Command -Name 'Confirm-SecureBootUEFI' -ErrorAction SilentlyContinue
    $confirmSecureBootAvailable = $null -ne $secureBootCmdlet
    $secureBootEnabled = $null
    $exitCode = 0
    $statusOverride = $null
    $reasonOverride = $null
    $recommendationOverride = $null

    if (-not $confirmSecureBootAvailable) {
        $exitCode = 2
        $statusOverride = 'FAILED'
        $reasonOverride = 'SECURE_BOOT_CMDLET_MISSING'
        $recommendationOverride = 'Run the inventory on a Windows build that exposes Confirm-SecureBootUEFI.'
    }
    else {
        try {
            $secureBootEnabled = [bool](Confirm-SecureBootUEFI -ErrorAction Stop)
        }
        catch {
            $statusOverride = 'UNSUPPORTED'
            $reasonOverride = 'SECURE_BOOT_UNSUPPORTED'
            $recommendationOverride = 'This device does not expose Secure Boot state through the UEFI cmdlet.'
        }
    }

    if ($null -eq $secureBootEnabled -and $registryState -and $null -ne $registryState.UEFISecureBootEnabled) {
        $secureBootEnabled = [bool]$registryState.UEFISecureBootEnabled
    }

    $secureBootCapable = $null
    if ($registryState -and $null -ne $registryState.SecureBootCapable) {
        $secureBootCapable = [bool]$registryState.SecureBootCapable
    }

    $bitLockerFacts = Get-BitLockerInventoryFacts
    $eventLogFacts = Get-SecureBootEventSummary
    $effectiveDeviceName = if (-not [string]::IsNullOrWhiteSpace($DeviceName)) { $DeviceName } else { $computerSystem.Name }
    $availableUpdates = if ($registrySecureBoot) { $registrySecureBoot.AvailableUpdates } else { $null }
    $uefi2023Status = if ($registryServicing) { $registryServicing.UEFICA2023Status } else { $null }
    $uefi2023Error = if ($registryServicing) { $registryServicing.UEFICA2023Error } else { $null }
    $latestSuccessEvent = $eventLogFacts.Events | Where-Object { $_.Id -in 1808, 1799 } | Select-Object -First 1
    $latestErrorEvent = $eventLogFacts.Events | Where-Object { $_.Id -eq 1795 } | Select-Object -First 1
    $latestPendingRebootEvent = $eventLogFacts.Events | Where-Object { $_.Id -eq 1801 } | Select-Object -First 1
    $activeUpdateError = ($null -ne $latestErrorEvent) -and (($null -eq $latestSuccessEvent) -or ($latestErrorEvent.TimeCreated -gt $latestSuccessEvent.TimeCreated))
    $effectiveRebootMarkerPath = $RebootMarkerPath
    if ([string]::IsNullOrWhiteSpace($effectiveRebootMarkerPath) -and $OutputPath) {
        $inventoryDirectory = Split-Path -Parent $OutputPath
        if ($inventoryDirectory) {
            $candidateMarkerPath = Join-Path $inventoryDirectory 'secureboot-update-reboot-required.marker'
            if (Test-Path -LiteralPath $candidateMarkerPath) {
                $effectiveRebootMarkerPath = $candidateMarkerPath
            }
        }
    }
    $rebootMarkerPresent = (-not [string]::IsNullOrWhiteSpace($effectiveRebootMarkerPath)) -and (Test-Path -LiteralPath $effectiveRebootMarkerPath)
    $updatePendingReboot = $rebootMarkerPresent -or ($availableUpdates -in 0x5944, 0x4100) -or (($null -ne $latestPendingRebootEvent) -and (($null -eq $latestSuccessEvent) -or ($latestPendingRebootEvent.TimeCreated -gt $latestSuccessEvent.TimeCreated)))
    $bitLockerReady = ($true -eq $bitLockerFacts.CmdletAvailable) -and ($true -eq $bitLockerFacts.RecoveryAvailable) -and ($true -eq $BitLockerEscrowVerified)
    $uefiErrorPresent = $null -ne $uefi2023Error -and -not ([string]::IsNullOrWhiteSpace([string]$uefi2023Error)) -and ([string]$uefi2023Error -notin @('0', '0x0', '0X0'))
    $strictlyUpdated = ([string]$uefi2023Status -ceq 'Updated') -and -not $uefiErrorPresent -and ($availableUpdates -eq 0x4000) -and ($null -ne $latestSuccessEvent)

    $factsForClassification = @{
        SecureBootEnabled = if ($null -ne $secureBootEnabled) { $secureBootEnabled } else { $false }
        FirmwareReady = if ($null -ne $secureBootCapable) { $secureBootCapable } else { $false }
        BitLockerRecoveryAvailable = $bitLockerReady
        UpdatePendingReboot = $updatePendingReboot
        Updated = $strictlyUpdated
    }

    $classification = Get-SecureBootClassification -Facts $factsForClassification

    if ((($null -eq $bitLockerFacts.RecoveryAvailable) -or (-not $BitLockerEscrowVerified)) -and $classification.Status -eq 'BITLOCKER_BLOCKED') {
        $classification = @{
            Status = 'BITLOCKER_BLOCKED'
            ReasonCode = if (-not $BitLockerEscrowVerified) { 'BITLOCKER_ESCROW_NOT_VERIFIED' } else { 'BITLOCKER_RECOVERY_UNKNOWN' }
            Recommendation = 'Verify BitLocker status and escrow the recovery key before rollout.'
        }
    }

    if ($activeUpdateError -and $classification.Status -in @('READY_FOR_PILOT', 'UPDATED', 'UPDATE_PENDING_REBOOT')) {
        $classification = @{
            Status = 'FAILED'
            ReasonCode = 'UEFI_CA_2023_UPDATE_ERROR'
            Recommendation = 'Review System event 1795 and HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\Servicing\UEFICA2023Error before rollout.'
        }
    }

    if ($statusOverride) {
        $classification = @{
            Status = $statusOverride
            ReasonCode = $reasonOverride
            Recommendation = $recommendationOverride
        }
    }

    $record = [ordered]@{
        TenantName = $TenantName
        CustomerName = $CustomerName
        DeviceName = $effectiveDeviceName
        TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
        ComputerName = $computerSystem.Name
        Manufacturer = $computerSystem.Manufacturer
        Model = $computerSystem.Model
        SerialNumber = $bios.SerialNumber
        BiosVersion = $bios.SMBIOSBIOSVersion
        BiosReleaseDateUtc = ConvertTo-UtcTimestampString $bios.ReleaseDate
        OsCaption = $operatingSystem.Caption
        OsVersion = $operatingSystem.Version
        OsBuildNumber = $operatingSystem.BuildNumber
        OsArchitecture = $operatingSystem.OSArchitecture
        IsServer = $operatingSystem.ProductType -ne 1
        SecureBootCapable = $secureBootCapable
        SecureBootEnabled = $secureBootEnabled
        ConfirmSecureBootAvailable = $confirmSecureBootAvailable
        BitLockerCmdletAvailable = $bitLockerFacts.CmdletAvailable
        BitLockerProtectionStatus = $bitLockerFacts.ProtectionStatus
        BitLockerRecoveryAvailable = $bitLockerFacts.RecoveryAvailable
        BitLockerEscrowVerified = $BitLockerEscrowVerified
        RebootMarkerPath = if ($rebootMarkerPresent) { $effectiveRebootMarkerPath } else { $null }
        SecureBootRegistry = [ordered]@{
            StatePath = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State'
            AvailableUpdatesPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot'
            ServicingPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\Servicing'
            SecureBootCapable = if ($registryState) { $registryState.SecureBootCapable } else { $null }
            UEFISecureBootEnabled = if ($registryState) { $registryState.UEFISecureBootEnabled } else { $null }
            UEFICA2023Status = $uefi2023Status
            UEFICA2023Error = $uefi2023Error
            AvailableUpdates = $availableUpdates
        }
        EventLog = $eventLogFacts.Summary
        Status = $classification.Status
        ReasonCode = $classification.ReasonCode
        Recommendation = $classification.Recommendation
    }

    $json = $record | ConvertTo-Json -Depth 6 -Compress
    $summary = "Atera Secure Boot Inventory | Tenant=$TenantName | Customer=$CustomerName | Device=$effectiveDeviceName | Status=$($classification.Status) | Reason=$($classification.ReasonCode)"

    if ($OutputPath) {
        Set-Content -LiteralPath $OutputPath -Value $json -Encoding UTF8
    }

    return @{
        ExitCode = $exitCode
        Record = [pscustomobject]$record
        Json = $json
        Summary = $summary
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $result = Invoke-SecureBootInventory -OutputPath $OutputPath -TenantName $TenantName -CustomerName $CustomerName -DeviceName $DeviceName -BitLockerEscrowVerified $BitLockerEscrowVerified -RebootMarkerPath $RebootMarkerPath
    Write-Output $result.Json
    Write-Output $result.Summary
    exit $result.ExitCode
}
