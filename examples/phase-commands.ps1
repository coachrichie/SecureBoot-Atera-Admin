# Beispielbefehle für die lokale Admin-Konsole.
# Dieses Beispiel liest keine Atera-API und startet keine Atera-Prozesse.

$root = Split-Path -Parent $PSScriptRoot
$inventory = Join-Path $root 'output\inventory'
$verification = Join-Path $root 'output\verification'

& (Join-Path $root 'orchestrator\Invoke-ManualSecureBootRollout.ps1') `
    -InputDirectory $inventory -Phase 'pilot' -PilotOnly `
    -ManifestPath (Join-Path $root 'output\pilot-manifest.json')

& (Join-Path $root 'scripts\Export-SecureBootFleetReport.ps1') `
    -InputDirectory $verification `
    -CsvPath (Join-Path $root 'output\secureboot-final.csv') `
    -HtmlPath (Join-Path $root 'output\secureboot-final.html')
