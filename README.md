# BankingManager Self-Service-Update

Mit diesen PowerShell-Skripten kann ein **normaler Windows-Benutzer** ein Update von
BankingManager (Atruvia) selbst einspielen, **ohne ein Administrator-Passwort zu kennen
oder zu speichern**. Das Update läuft als geplante Aufgabe unter `SYSTEM`, der Benutzer
darf sie nur starten.

> Inoffiziell, nicht von Atruvia, ohne Gewähr ([MIT](LICENSE)). Das Skript deinstalliert
> und installiert eine Banking-Software. Bitte zuerst in einer Testumgebung ausprobieren.
> Getestet nur mit Windows Server 2025 (deutsch) und BankingManager 1.15.0.65 → 1.15.1.1.

## Installation

Einmalig, als Administrator auf dem Rechner, auf dem BankingManager installiert ist:

1. Die drei `.ps1`-Dateien auf den Rechner kopieren.
2. In `Update-BankingManager.ps1` prüfen, ob die Pfade und `$ExpectedPublisher` stimmen
   (Standard: `C:\Program Files\BankingManager`, Herausgeber Atruvia AG).
3. Setup ausführen. `-Users` sind die Benutzer, die das Update starten dürfen:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\Setup-UpdateTask.ps1 -Users 'maxmustermann'
   ```

Das legt die geplante Aufgabe **BankingManager Update** und die Desktop-Verknüpfung
**BankingManager aktualisieren** an.

Voraussetzung: Der Installer des Herstellers lässt den Headless-Modus zu. Prüfen:
`& "C:\Program Files\BankingManager\maintenancetool_bankingmanager.exe" --default-answer list`
muss eine XML-Liste der Pakete ausgeben.

## Benutzung

1. In BankingManager das Update herunterladen, aber **nicht** "Update installieren"
   klicken.
2. BankingManager **überall schließen** (auch in anderen Sitzungen).
3. Die Verknüpfung **BankingManager aktualisieren** (auf Desktop) starten und bestätigen.
4. Ein bis zwei Minuten warten. Ein Fenster meldet das Ergebnis, etwa
   `OK: BankingManager ist jetzt Version 1.15.1.1.`

Der Administrator kann das Update auch mit `schtasks /run /tn "BankingManager Update"`
starten und das Protokoll in `C:\ProgramData\BankingManagerUpdate\update.log` lesen.

---

## Für Interessierte

### Warum nicht einfach `runas /savecred`?

Die gespeicherten Anmeldedaten gelten für das ganze Benutzerprofil. Jedes Programm darin
könnte damit Administrator-Prozesse starten. Den Installer direkt als Benutzer zu starten
geht nicht: Er verlangt ein Admin-Passwort, und sein "Fallback" (`--start-server …`) benutzt
Sitzungsschlüssel, die bei jedem Lauf neu entstehen.

### Was das Skript tut

1. Sucht den neuesten `banking_manager_update_<Version>.exe` im Download-Ordner.
2. Installiert nur eine **höhere** Version als die installierte.
3. Bricht ab, wenn BankingManager noch läuft (beendet nichts).
4. Kopiert den Installer in einen Admin-Ordner und prüft dort die **Signatur des
   Herstellers** (oder einen SHA256 aus `allowed_hashes.txt`).
5. Sichert Programmordner, Konfiguration (`ProgramData`), Registry und Verknüpfungen.
6. Deinstalliert (`purge`) und installiert dann still neu. Der Installer akzeptiert keinen
   Zielordner mit bestehender Installation, die Hersteller-GUI geht genauso vor.
7. Prüft die neue Version und stellt bei einem Fehler den alten Stand aus der Sicherung
   wieder her.

### Sicherheit

- Die Aufgabe nimmt **keine Parameter** an und liegt in einem Ordner, den nur `SYSTEM`
  und Administratoren ändern dürfen.
- Es wird nur ein signierter Hersteller-Installer ausgeführt, und nur, wenn er neuer ist.
  Das verhindert auch das Einspielen einer alten, verwundbaren Version.
- Benutzer dürfen die Aufgabe nur starten, nicht ändern. Es werden keine Passwörter
  gespeichert.

### Konfiguration

Am Anfang von `Update-BankingManager.ps1`: Installations- und Datenordner,
Download-Ordner, erwarteter Herausgeber (`$ExpectedPublisher`), Registry-Schlüssel der
Deinstallation, Anzahl der Sicherungen, Zeitlimit. Nach jeder Änderung `Setup-UpdateTask.ps1`
erneut ausführen. Herausgeber und Hash einer Datei:

```powershell
Get-AuthenticodeSignature .\banking_manager_update_<Version>.exe | Format-List Status, SignerCertificate
Get-FileHash .\banking_manager_update_<Version>.exe -Algorithm SHA256
```

### Grenzen

- Der Rollback nach einem Fehler **mitten** in der Installation ist nicht erprobt.
- Das Skript ist nicht signiert, sein Schutz sind die Dateirechte des Arbeitsordners.
- Es wird nur Software unter `Program Files` und `ProgramData` gesichert. Daten im
  Benutzerprofil bleiben unberührt, werden aber auch nicht gesichert.
- Das Code-Signing-Zertifikat des Herstellers im Test läuft am 28.04.2027 ab. Ändert sich
  der Herausgeber, muss `$ExpectedPublisher` angepasst werden.
- Ein Programm, ein Installationsordner. Mehrere Instanzen sind nicht vorgesehen.

### Entfernen

```powershell
Unregister-ScheduledTask -TaskName 'BankingManager Update' -Confirm:$false
Remove-Item 'C:\Users\Public\Desktop\BankingManager aktualisieren.lnk'
Remove-Item 'C:\ProgramData\BankingManagerUpdate' -Recurse -Force   # inkl. Sicherungen
```

Technische Details und Hinweise zum Ändern der Skripte stehen in [CLAUDE.md](CLAUDE.md).
