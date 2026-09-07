# Atera-Import-Matrix

| Datei | Typ | Reihenfolge | Zweck |
|---|---|---:|---|
| `SecureBoot.Common.ps1` | PowerShell-Abhängigkeit | 0 | Gemeinsame Statuslogik |
| `Invoke-SecureBootInventory.ps1` | PowerShell | 1 | Read-only Inventur |
| `Invoke-SecureBootCertificateUpdate.ps1` | PowerShell | 2 | WhatIf/Handoff |
| `Get-SecureBootUpdateVerification.ps1` | PowerShell | 3 | Nachprüfung nach Neustart |
| `Export-SecureBootFleetReport.ps1` | PowerShell lokal | 4 | CSV/HTML-Abschlussreport |

Alle Geräte-Skripte als SYSTEM ausführen. `Export-SecureBootFleetReport.ps1` wird auf dem Administrationsrechner ausgeführt.
