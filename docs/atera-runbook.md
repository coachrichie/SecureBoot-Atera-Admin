# Secure Boot über Atera – automatisierte Ausführung, manuell gestartet

Dieses Runbook verwendet Atera nur als manuell bediente Ausführungsplattform. Die Skripte automatisieren Prüfung, Update-Handoff, Neustartstatus, Verifikation und Reporting auf dem Endgerät. Der lokale Phasenplaner verarbeitet die Ergebnisdateien und benötigt keine Atera-API, keinen API-Token und keine Netzwerkverbindung zu Atera.

## 1. Dateien

- `scripts\SecureBoot.Common.ps1`
- `scripts\Invoke-SecureBootInventory.ps1`
- `scripts\Invoke-SecureBootCertificateUpdate.ps1`
- `scripts\Get-SecureBootUpdateVerification.ps1`
- `scripts\Export-SecureBootFleetReport.ps1`
- `orchestrator\Invoke-ManualSecureBootRollout.ps1`

Die fünf Skripte im Ordner `scripts` werden in Atera hochgeladen. `SecureBoot.Common.ps1` muss im selben Atera-Paket beziehungsweise am selben Ausführungsort verfügbar sein.

## 2. Manuelle Atera-Ausführung

1. In Atera die gewünschte Customer-, Site- oder Geräteauswahl öffnen.
2. Die Inventur als PowerShell-Skript auf der Auswahl starten.
3. Das Skript als SYSTEM ausführen und für Offline-Geräte eine Queue-Dauer setzen.
4. Die JSON-Ergebnisdateien aus den Atera-Prozessen in den lokalen Ordner `out\inventory` übernehmen.
5. Den lokalen Phasenplaner ausführen.
6. Nur die im Manifest genannten Geräte in Atera markieren und das nächste Skript manuell starten.
7. Nach dem Wartungsfenster die Ergebnisdateien erneut lokal sammeln und die nächste Phase berechnen.

Atera kann PowerShell-Skripte auf mehreren Geräten beziehungsweise über Customer- und Site-Ansichten starten; die Ausführungsergebnisse stehen im Recent Processes Report und im Activity Log.

## 3. Inventur

```powershell
.\Invoke-SecureBootInventory.ps1 `
  -OutputPath 'C:\ProgramData\SecureBoot\inventory.json' `
  -TenantName '<Tenant>' -CustomerName '<Kunde>' -DeviceName '<Gerät>' `
  -BitLockerEscrowVerified $true
```

`-BitLockerEscrowVerified $true` darf nur verwendet werden, wenn das externe Escrow tatsächlich geprüft wurde. Die lokale Existenz eines Recovery-Protectors ist kein Nachweis für Escrow.

## 4. Lokalen Phasenplan erzeugen

```powershell
.\orchestrator\Invoke-ManualSecureBootRollout.ps1 `
  -InputDirectory '.\out\inventory' `
  -Phase 'pilot' -PilotOnly -ThrottleLimit 5 `
  -ManifestPath '.\out\pilot-manifest.json'
```

Das Manifest muss `Mode=MANUAL_ATERA_TRIGGER_NO_API` und `ApiUsed=false` enthalten. `PlannedActions` ist die konkrete nächste Atera-Auswahl. Server, Blocker und ungültige Dateien werden separat ausgewiesen.

Phasen:

- `pilot`: nur Geräte mit `Pilot=true` oder `PilotOnly=true`
- `10`: erste 10 Prozent der übrigen berechtigten Clients
- `25`: nächste 25 Prozent
- `rest`: verbleibende berechtigte Clients
- `verification`: Dokumentationsphase für Nachprüfungen

## 5. Update in Atera

Zuerst als kontrollierten Test starten:

```powershell
.\Invoke-SecureBootCertificateUpdate.ps1 -WhatIf -Force `
  -BitLockerEscrowVerified $true `
  -TenantName '<Tenant>' -CustomerName '<Kunde>' -DeviceName '<Gerät>' `
  -OutputPath 'C:\ProgramData\SecureBoot\update-result.json'
```

Nach der manuellen Freigabe ohne `-WhatIf` starten:

```powershell
.\Invoke-SecureBootCertificateUpdate.ps1 -Force `
  -BitLockerEscrowVerified $true `
  -TenantName '<Tenant>' -CustomerName '<Kunde>' -DeviceName '<Gerät>' `
  -OutputPath 'C:\ProgramData\SecureBoot\update-result.json'
```

Kein `-Force` für Geräte mit `BITLOCKER_BLOCKED`, `NEEDS_FIRMWARE`, `SECURE_BOOT_DISABLED`, `SERVER_SEPARATE_ROLLOUT`, `UNSUPPORTED` oder `FAILED`.

## 6. Neustart und Verifikation

Nach dem freigegebenen Neustart erneut manuell in Atera starten:

```powershell
.\Invoke-SecureBootInventory.ps1 `
  -OutputPath 'C:\ProgramData\SecureBoot\inventory-postreboot.json' `
  -TenantName '<Tenant>' -CustomerName '<Kunde>' -DeviceName '<Gerät>' `
  -BitLockerEscrowVerified $true

.\Get-SecureBootUpdateVerification.ps1 `
  -InputPath 'C:\ProgramData\SecureBoot\inventory-postreboot.json' `
  -OutputPath 'C:\ProgramData\SecureBoot\verification.json'
```

`UPDATED` ist erst zulässig, wenn `UEFICA2023Status=Updated`, kein aktiver `UEFICA2023Error`, `AvailableUpdates=0x4000` und ein Erfolgsevent 1808 oder 1799 vorliegen. Bei `UPDATE_PENDING_REBOOT` ist der Neustart-/Folgeschritt noch offen.

## 7. Abschlussreport

```powershell
.\scripts\Export-SecureBootFleetReport.ps1 `
  -InputDirectory '.\out\verification' `
  -CsvPath '.\out\secureboot-final.csv' `
  -HtmlPath '.\out\secureboot-final.html'
```

Der Abschluss ist erst vollständig, wenn alle Clients `UPDATED` melden, keine ungeklärten Fehler oder Pending-Reboot-Status verbleiben und Server separat behandelt oder dokumentiert ausgenommen wurden.

## 8. Stop-Kriterien

- Event 1795 oder ein nicht leerer `UEFICA2023Error`
- wiederholte `HANDOFF_FAILED`-Ergebnisse
- fehlendes BitLocker-Escrow
- unerwarteter Neustart- oder Bootfehler
- unklare Abweichung zwischen Atera-Prozessstatus und JSON-Ergebnis

Bei einem Stop-Kriterium die aktuelle Welle anhalten, Ergebnisdateien sichern und keine weitere `-Force`-Ausführung starten.
