# CLAUDE.md

Hinweise für alle, die an diesem Repo arbeiten (Menschen und Claude). Die Nutzer-Doku
steht in [README.md](README.md) und wird bewusst kurz gehalten. Alles Technische gehört hierher.

## Zweck

Ein normaler Windows-Benutzer soll ein BankingManager-Update (Qt Installer Framework,
Installer verlangt Admin) einspielen können, ohne Admin-Passwort. Dafür eine geplante
Aufgabe unter `SYSTEM`, die der Benutzer nur starten darf.

## Dateien

| Datei | Läuft als | Zweck |
|---|---|---|
| `Setup-UpdateTask.ps1` | Admin, einmalig | Arbeitsordner + ACLs, Aufgabe registrieren, Startrecht (SDDL `FRFX`), Desktop-Verknüpfung |
| `Update-BankingManager.ps1` | `SYSTEM` (Aufgabe) | Update-Logik, **ohne Parameter** (bewusst) |
| `Start-Update.ps1` | Benutzer | Rückfrage, Aufgabe per COM starten, `status.txt` anzeigen |

## Ablauf in `Update-BankingManager.ps1`

1. Neuesten `banking_manager_update_<a.b.c.d>.exe` im Download-Ordner finden (strikter Regex, Sortierung als `[version]`).
2. Installierte Version aus `maintenancetool_bankingmanager.exe --default-answer list` (XML) lesen. Nur Upgrade, nie gleich oder älter.
3. Läuft BankingManager (Prozess-Pfad unter `$InstallDir`)? Abbruch, **nicht** beenden.
4. Installer in `staging\` kopieren, dort Signatur (`Valid` + Subject enthält `$ExpectedPublisher`) oder SHA256 aus `allowed_hashes.txt` prüfen.
5. Sicherung nach `backup\<Zeit>\`: `ProgramFiles`, `ProgramData`, `uninstall.reg`, `extra\`.
6. `maintenancetool_bankingmanager.exe -d --default-answer --confirm-command purge`. Danach bis zu 120 s warten, bis das Wartungstool verschwunden ist (löscht sich verzögert), Rest des Ordners entfernen.
7. `ProgramData`-Sicherung zurückspielen, damit der Installer die Konfiguration findet.
8. `installer.exe -d --accept-licenses --default-answer --confirm-command --root "<InstallDir>" install AllUsers=true addToStartMenu=true addToDesktop=true shortcutName=BankingManager`.
9. Prozesse unter `$InstallDir` beenden (Installer startet das Programm am Ende), Version prüfen, ggf. `BankingManager.cfg` wiederherstellen, `start_admin.bat` zurückkopieren, alte Sicherungen löschen (`$KeepBackups`).

Bei Fehler nach Schritt 6 Rollback aus der Sicherung (`robocopy /MIR`, `reg import`, Extras). Ergebnis immer in `public\status.txt` (Zeitstempel, dann `OK:` oder `FEHLER:`; `Start-Update.ps1` wertet das Präfix aus).

## Laufzeitorte (Windows)

Alles unter `C:\ProgramData\BankingManagerUpdate`, nur `SYSTEM` + Administratoren (ACL per SID, sprachunabhängig), außer `public\` (Authenticated Users: Lesen/Ausführen).

`update.log`, `<Zeit>-list|purge|install.out.txt` und `.err.txt`, `backup\<Zeit>\{ProgramFiles,ProgramData,extra,uninstall.reg}`, `staging\`, `allowed_hashes.txt`, `public\{Start-Update.ps1,status.txt}`.

## Wichtige Entscheidungen

- **Keine Parameter** an die Aufgabe, kein Passwort gespeichert. Der Benutzer darf nur lesen/starten.
- **Erst kopieren, dann prüfen**: Der Download-Ordner ist für alle beschreibbar, geprüft wird die Kopie im Admin-Ordner.
- **Kein Downgrade**, sonst ließe sich eine alte, signierte Version mit Lücken einspielen.
- **Laufende Instanz = Abbruch**, kein Kill, wegen ungespeicherter Arbeit.
- **`purge` + `install`**, weil der Installer in einen Ordner mit bestehender Installation nicht installiert (`TargetDirectoryInUse`, harter Fehler ohne auto-answer). Die Hersteller-GUI deinstalliert ebenfalls erst (Aufruf dort: `maintenancetool … -c --am --sm -d --verbose`, hier bewusst `purge`, weil `--sm` ein Fenster öffnen könnte).
- **Datenverlust-Schutz**: `purge` kann `C:\ProgramData\BankingManager` löschen (`clearUserData.bat`), darum Sicherung und Zurückspielen.

## Stolperstellen (alle real aufgetreten)

- **Nur ASCII in `.ps1`.** Windows PowerShell 5.1 liest UTF-8 ohne BOM als ANSI, Umlaute werden kaputt. Prüfen: `grep -nP '[^\x00-\x7F]' *.ps1`.
- **`Set-StrictMode -Version 2`**: `.Count` auf `$null` wirft. Funktionen, die nichts ausgeben, liefern `$null` (nicht `@()`). Immer `@(...)` um Funktionsaufrufe legen, bevor `.Count` benutzt wird.
- **`reg.exe` mit `2>&1` unter `$ErrorActionPreference='Stop'`**: Die Erfolgsmeldung geht auf stderr und wird als Fehler gewertet ("Der Vorgang wurde erfolgreich beendet"). Immer über `Invoke-Reg` aufrufen.
- **`--accept-messages` und `--default-answer` schließen sich aus.** Nur `--default-answer` verwenden.
- **Qt-IFW-Installer in Windows `Start-Process`**: Argumente als **ein String** mit eingebetteten Anführungszeichen übergeben, nicht als Array (Leerzeichen im Pfad).
- **`$args` ist eine automatische Variable.** Eigene Namen verwenden (`$installArgs`).
- **`list` und `check-updates` am Installer** geben nur `Cannot list/check … with installer` aus. Sie gehören zum Wartungstool.
- **Wartungstool löscht sich nach `purge` verzögert**, deshalb die Wartezeit-Schleife in Schritt 6.
- **Startrecht auf die Aufgabe**: SDDL-ACE `(A;;FRFX;;;<SID>)` an die DACL anhängen und mit `SetSecurityDescriptor($sddl, 0)` setzen. Normale Benutzer starten per COM (`Schedule.Service` → `GetTask().Run()`), nicht über `Start-ScheduledTask` (CIM).

## Bekannter Teststand

Erfolgsfall auf einem echten Server geprüft: Windows Server 2025 (de), BankingManager 1.15.0.65 → 1.15.1.1, Qt IFW 4.11.0. Der Rollback lief bisher nur in einem Fall, in dem noch nichts deinstalliert war. Ein Rollback nach Abbruch mitten in Installation oder Purge ist **nicht erprobt**.

## Zum Ändern

- Hier gibt es **kein Windows und keine PowerShell**. Änderungen können nur gelesen, nicht ausgeführt werden. Vorsichtig sein und vom Nutzer `update.log` und die `*.out.txt` des betroffenen Laufs anfordern.
- Nach Änderungen die Dateien auf den Server kopieren und `Setup-UpdateTask.ps1` erneut ausführen (kopiert `Update-BankingManager.ps1` nach `$WorkDir`, `Start-Update.ps1` nach `public\`). Ein bloßes Ändern der Datei im Repo wirkt nicht.
- Konfiguration (Pfade, `$ExpectedPublisher`, `$UninstallKey`) steht am Anfang von `Update-BankingManager.ps1`. Änderungen am Herausgeber nach Zertifikatswechsel (Test-Zertifikat lief bis 28.04.2027): Subject steht im `update.log` bei `Installer nicht freigegeben`.
- Die Produkt-UUID (`$UninstallKey`) steht im Installer-Log als `ProductUUID`.

## Fehlersuche (für Support)

| Symptom | Ursache / Abhilfe |
|---|---|
| `Installer nicht freigegeben` | Signatur nicht `Valid`, anderer Herausgeber oder Hash fehlt. Subject und SHA256 stehen im Log. |
| `BankingManager läuft noch` | Instanz läuft, auch in anderer Sitzung. Alle schließen. |
| `bereits aktuell` | Kein Installer mit höherer Version im Download-Ordner. |
| `Kein Update-Installer … gefunden` | Dateiname passt nicht zu `banking_manager_update_<a.b.c.d>.exe` oder falscher `$DownloadDir`. |
| `Das Update konnte nicht gestartet werden` | Dem Benutzer fehlt das Startrecht. Setup mit passendem `-Users` wiederholen. Test: `schtasks /run /tn "BankingManager Update"` als dieser Benutzer. |
| `TargetDirectoryInUse` im Install-Log | `purge` lief nicht oder der Ordner enthielt noch Reste. |
| `�` im Log | Nur Darstellung. `update.log` ist ANSI, nicht UTF-8. |

## Rollback von Hand

Als Administrator, BankingManager geschlossen:

```powershell
$b = 'C:\ProgramData\BankingManagerUpdate\backup\<Zeit>'
robocopy "$b\ProgramFiles" 'C:\Program Files\BankingManager' /MIR /COPYALL /R:1 /W:1
robocopy "$b\ProgramData"  'C:\ProgramData\BankingManager'   /MIR /COPYALL /R:1 /W:1
reg import "$b\uninstall.reg"
# Verknüpfungen aus "$b\extra" zurückkopieren (Desktop: C:\Users\Public\Desktop)
```

## Konventionen

- Kommentare und Meldungen auf Deutsch, Code-Bezeichner englisch/deutsch gemischt wie im Bestand.
- Keine personenbezogenen Daten, keine Kundennamen, Pfade oder Benutzernamen in Repo-Dateien. Beispiele neutral halten (`maxmustermann`).
- Das README kurz halten (Installation und Benutzung zuerst, Rest darunter). Detail gehört in diese Datei.
