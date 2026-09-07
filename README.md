# Secure-Boot-Atera-Admin-Paket

Dieses Paket ist für einen Atera-Administrator zur manuellen Ausführung bestimmt. Es enthält die produktiven Skripte, die Word-Dokumentation, das Runbook, Checklisten und eine Beispielablage.

## Grundprinzip

Atera wird manuell angestoßen. Die Skripte führen die Prüfungen und den Update-Handoff automatisiert auf dem Gerät aus. Der lokale Phasenplaner arbeitet ausschließlich mit bereits exportierten JSON-Ergebnissen und benötigt keine Atera-Schnittstelle.

## Reihenfolge

1. `checklists\01-vorbereitung.md`
2. Atera: `Invoke-SecureBootInventory.ps1`
3. JSON-Ergebnisse nach `output\inventory` übernehmen
4. `orchestrator\Invoke-ManualSecureBootRollout.ps1 -Phase pilot`
5. Atera: WhatIf, danach Update mit `-Force`
6. Neustart im Wartungsfenster
7. Atera: Inventur und `Get-SecureBootUpdateVerification.ps1`
8. Phasen `10`, `25`, `rest` wiederholen
9. `checklists\03-abschluss.md` und Abschlussreport ausführen

Server werden separat behandelt.
