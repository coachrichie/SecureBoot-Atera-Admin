[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$InputDirectory,

    [Parameter(Mandatory = $false)]
    [ValidateSet('inventory','pilot','10','25','rest','verification')]
    [string]$Phase = 'inventory',

    [Parameter(Mandatory = $false)]
    [string]$CustomerFilter,

    [Parameter(Mandatory = $false)]
    [switch]$PilotOnly,

    [Parameter(Mandatory = $false)]
    [int]$ThrottleLimit = 10,

    [Parameter(Mandatory = $false)]
    [string]$ManifestPath = (Join-Path (Get-Location) 'secureboot-manual-rollout-manifest.json')
)

function Get-ManualSecureBootRecords {
    param([string]$Directory)

    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        throw "InputDirectory does not exist: $Directory"
    }

    $records = foreach ($file in Get-ChildItem -LiteralPath $Directory -Filter '*.json' -File | Sort-Object Name) {
        try {
            $record = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            [pscustomobject]@{ SourceFile = $file.Name; Record = $record }
        }
        catch {
            [pscustomobject]@{
                SourceFile = $file.Name
                Record = [pscustomobject]@{
                    TenantName = $null; CustomerName = $null; DeviceName = $file.BaseName
                    IsServer = $false; Status = 'INVALID_INPUT'; ReasonCode = 'INVALID_INPUT'
                    Recommendation = 'Repair or replace the JSON result before rollout.'
                }
            }
        }
    }

    return @($records)
}

function Select-ManualSecureBootPhaseTargets {
    param(
        [object[]]$Clients,
        [string]$SelectedPhase,
        [switch]$OnlyPilot
    )

    $ordered = @($Clients | Sort-Object CustomerName, DeviceName, SourceFile)
    if ($OnlyPilot -or $SelectedPhase -eq 'pilot') {
        return @($ordered | Where-Object { $_.Record.Pilot -eq $true -or $_.Record.PilotOnly -eq $true })
    }

    $nonPilot = @($ordered | Where-Object { $_.Record.Pilot -ne $true -and $_.Record.PilotOnly -ne $true })
    $ten = [Math]::Ceiling($nonPilot.Count * 0.10)
    $twentyFive = [Math]::Ceiling($nonPilot.Count * 0.25)
    if ($SelectedPhase -eq '10') { return @($nonPilot | Select-Object -First $ten) }
    if ($SelectedPhase -eq '25') { return @($nonPilot | Select-Object -Skip $ten -First $twentyFive) }
    return @($nonPilot | Select-Object -Skip ($ten + $twentyFive))
}

function Invoke-ManualSecureBootRollout {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InputDirectory,
        [ValidateSet('inventory','pilot','10','25','rest','verification')][string]$Phase = 'inventory',
        [string]$CustomerFilter,
        [switch]$PilotOnly,
        [int]$ThrottleLimit = 10,
        [string]$ManifestPath = (Join-Path (Get-Location) 'secureboot-manual-rollout-manifest.json')
    )

    $loaded = @(Get-ManualSecureBootRecords -Directory $InputDirectory)
    $records = @($loaded | Where-Object { -not $CustomerFilter -or $_.Record.CustomerName -like $CustomerFilter })
    $windows = @($records | Where-Object { $_.Record.OsCaption -match 'Windows' -or $_.Record.OperatingSystem -match 'Windows' })
    $servers = @($windows | Where-Object { $_.Record.IsServer -eq $true -or $_.Record.OsCaption -match 'Windows Server' })
    $clients = @($windows | Where-Object { $_ -notin $servers })
    $eligible = @($clients | Where-Object { $_.Record.Status -in @('READY_FOR_PILOT','UPDATE_PENDING_REBOOT') })
    $selected = if ($Phase -in @('pilot','10','25','rest')) { @(Select-ManualSecureBootPhaseTargets -Clients $eligible -SelectedPhase $Phase -OnlyPilot:$PilotOnly) } else { @() }

    $actions = @($selected | ForEach-Object {
        $action = if ($_.Record.Status -eq 'UPDATE_PENDING_REBOOT') { 'RUN_VERIFICATION_OR_REBOOT' } else { 'RUN_UPDATE_SCRIPT_MANUALLY_IN_ATERA' }
        [pscustomobject][ordered]@{
            SourceFile = $_.SourceFile; TenantName = $_.Record.TenantName; CustomerName = $_.Record.CustomerName
            DeviceName = $_.Record.DeviceName; Phase = $Phase; Action = $action
            Note = 'In Atera manuell die ausgewählte Geräte-/Kundengruppe markieren und das passende Skript starten.'
        }
    })

    $manifest = [ordered]@{
        TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
        Mode = 'MANUAL_ATERA_TRIGGER_NO_API'
        InputDirectory = (Resolve-Path -LiteralPath $InputDirectory).Path
        Phase = $Phase; CustomerFilter = $CustomerFilter; PilotOnly = [bool]$PilotOnly
        ThrottleLimit = $ThrottleLimit; ApiUsed = $false
        RecordCount = @($records).Count; EligibleClientCount = @($eligible).Count
        ServerDeferred = @($servers | ForEach-Object { $_.Record })
        BlockedOrUnusable = @($records | Where-Object { $_ -notin $selected -and $_.Record.Status -notin @('READY_FOR_PILOT','UPDATE_PENDING_REBOOT','UPDATED') } | ForEach-Object { $_.Record })
        SelectedTargets = @($selected | ForEach-Object { $_.Record })
        PlannedActions = $actions
        NextStep = 'Use Atera UI to start the appropriate PowerShell script on the listed devices.'
    }

    $dir = Split-Path -Parent $ManifestPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
    $manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $ManifestPath -Encoding UTF8

    [pscustomobject][ordered]@{
        ApiUsed = $false; Mode = 'MANUAL_ATERA_TRIGGER_NO_API'; Phase = $Phase
        RecordCount = @($records).Count; SelectedCount = @($selected).Count; ServerDeferredCount = @($servers).Count
        ManifestPath = $ManifestPath; SelectedTargets = $selected; PlannedActions = $actions
    }
}

if (-not [string]::IsNullOrWhiteSpace($InputDirectory)) {
    $result = Invoke-ManualSecureBootRollout -InputDirectory $InputDirectory -Phase $Phase -CustomerFilter $CustomerFilter -PilotOnly:$PilotOnly -ThrottleLimit $ThrottleLimit -ManifestPath $ManifestPath
    Write-Output ($result | ConvertTo-Json -Depth 10)
}
