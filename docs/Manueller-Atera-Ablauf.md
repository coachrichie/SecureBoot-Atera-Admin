# Manueller Atera-Ablauf

## Inventur

```powershell
.\Invoke-SecureBootInventory.ps1 `
  -OutputPath 'C:\ProgramData\SecureBoot\inventory.json' `
  -TenantName '<Tenant>' -CustomerName '<Kunde>' -DeviceName '<Gerät>' `
  -BitLockerEscrowVerified $true
```

JSON-Ergebnisse nach `output\inventory` übernehmen.

## Lokale Auswahl

```powershell
.\orchestrator\Invoke-ManualSecureBootRollout.ps1 `
  -InputDirectory '.\output\inventory' `
  -Phase 'pilot' -PilotOnly `
  -ManifestPath '.\output\pilot-manifest.json'
```

In Atera nur die im Manifest genannten Geräte auswählen.

## Update

```powershell
.\Invoke-SecureBootCertificateUpdate.ps1 -WhatIf -Force `
  -BitLockerEscrowVerified $true `
  -OutputPath 'C:\ProgramData\SecureBoot\update-result.json'
```

Nach Freigabe:

```powershell
.\Invoke-SecureBootCertificateUpdate.ps1 -Force `
  -BitLockerEscrowVerified $true `
  -OutputPath 'C:\ProgramData\SecureBoot\update-result.json'
```

Nach dem Neustart Inventur und Verifikation erneut manuell starten. Bei `UPDATED` darf die nächste Welle freigegeben werden.
