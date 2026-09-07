function ConvertTo-SecureBootBoolean {
    param(
        [Parameter(Mandatory = $false)]
        [object]$Value
    )

    if ($null -eq $Value) {
        return $false
    }

    if ($Value -is [bool]) {
        return $Value
    }

    if ($Value -is [string]) {
        $normalized = $Value.Trim()
        switch -Regex ($normalized) {
            '^(?i:true|yes|1)$' { return $true }
            '^(?i:false|no|0)$' { return $false }
        }

        return [bool]$normalized
    }

    return [bool]$Value
}

function Get-SecureBootClassification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Facts
    )

    $status = 'READY_FOR_PILOT'
    $reasonCode = 'READY_FOR_PILOT'
    $recommendation = 'Proceed with the next rollout gate.'

    if ($Facts.ContainsKey('SecureBootEnabled') -and -not (ConvertTo-SecureBootBoolean $Facts['SecureBootEnabled'])) {
        $status = 'SECURE_BOOT_DISABLED'
        $reasonCode = 'SECURE_BOOT_DISABLED'
        $recommendation = 'Enable Secure Boot in firmware before rollout.'
    }
    elseif ($Facts.ContainsKey('FirmwareReady') -and -not (ConvertTo-SecureBootBoolean $Facts['FirmwareReady'])) {
        $status = 'NEEDS_FIRMWARE'
        $reasonCode = 'FIRMWARE_NOT_READY'
        $recommendation = 'Update firmware before continuing.'
    }
    elseif ($Facts.ContainsKey('BitLockerRecoveryAvailable') -and -not (ConvertTo-SecureBootBoolean $Facts['BitLockerRecoveryAvailable'])) {
        $status = 'BITLOCKER_BLOCKED'
        $reasonCode = 'BITLOCKER_RECOVERY_NOT_ESCROWED'
        $recommendation = 'Escrow or verify the BitLocker recovery key before rollout.'
    }
    # Reboot-pending takes precedence over Updated so post-reboot verification can
    # distinguish "update landed but needs restart" from the final completed state.
    elseif ($Facts.ContainsKey('UpdatePendingReboot') -and (ConvertTo-SecureBootBoolean $Facts['UpdatePendingReboot'])) {
        $status = 'UPDATE_PENDING_REBOOT'
        $reasonCode = 'REBOOT_REQUIRED'
        $recommendation = 'Restart the device and re-run verification.'
    }
    elseif ($Facts.ContainsKey('Updated') -and (ConvertTo-SecureBootBoolean $Facts['Updated'])) {
        $status = 'UPDATED'
        $reasonCode = 'UPDATE_CONFIRMED'
        $recommendation = 'No action required.'
    }

    return @{
        Status = $status
        ReasonCode = $reasonCode
        Recommendation = $recommendation
    }
}
