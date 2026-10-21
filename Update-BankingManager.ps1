<#
  Update-BankingManager.ps1

  Laeuft als geplante Aufgabe unter SYSTEM und nimmt bewusst KEINE Parameter entgegen.
  Ablauf: neuesten Update-Installer finden -> in Admin-Ordner kopieren -> Signatur/Hash pruefen
          -> sichern -> deinstallieren (purge) -> installieren -> pruefen, sonst Rollback.

  Nur ASCII in dieser Datei, damit Windows PowerShell 5.1 sie ohne BOM korrekt liest.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

# ---- Konfiguration ----------------------------------------------------------
$InstallDir        = 'C:\Program Files\BankingManager'
$DataDir           = 'C:\ProgramData\BankingManager'
$DownloadDir       = 'C:\Users\Public\Downloads'
$WorkDir           = 'C:\ProgramData\BankingManagerUpdate'
$ExpectedPublisher = 'CN=Atruvia AG, O=Atruvia AG, L=Karlsruhe, C=DE, SERIALNUMBER=HRB 102381'   # Teil des Zertifikat-Subjects (leer = nur Hash-Liste)
$UninstallKey      = 'HKLM\Software\Microsoft\Windows\CurrentVersion\Uninstall\389afcbe-dcbc-402a-b389-4c552478ea94'
$ExtraBackupPaths  = @(                                   # werden bei Rollback wiederhergestellt
    'C:\Users\Public\Desktop\BankingManager.lnk',
    'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\BankingManager'
)
$KeepBackups       = 3
$StepTimeoutSec    = 1200
# -----------------------------------------------------------------------------

$Maintenance = Join-Path $InstallDir 'maintenancetool_bankingmanager.exe'
$LogFile     = Join-Path $WorkDir 'update.log'
$StatusFile  = Join-Path $WorkDir 'public\status.txt'
$HashFile    = Join-Path $WorkDir 'allowed_hashes.txt'
$Staging     = Join-Path $WorkDir 'staging'
$Stamp       = Get-Date -Format 'yyyyMMdd_HHmmss'
$BackupDir   = Join-Path $WorkDir "backup\$Stamp"

New-Item -ItemType Directory -Force -Path $WorkDir, (Join-Path $WorkDir 'public'), $Staging | Out-Null

function Log([string]$Msg) {
    Add-Content -Path $LogFile -Value ('{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $Msg)
}

function Set-Status([string]$Text) {
    Set-Content -Path $StatusFile -Value ('{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $Text)
}

function Copy-Tree([string]$Src, [string]$Dst, [switch]$Mirror) {
    $mode = if ($Mirror) { '/MIR' } else { '/E' }
    & robocopy.exe $Src $Dst $mode /COPYALL /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy $Src -> $Dst fehlgeschlagen (Exitcode $LASTEXITCODE)" }
}

# Startet ein Programm mit Zeitlimit, schreibt stdout/stderr in Dateien, liefert Exitcode und Ausgabe.
function Invoke-Tool([string]$Exe, [string]$ArgString, [string]$Name) {
    $out = Join-Path $WorkDir "$Stamp-$Name.out.txt"
    $err = Join-Path $WorkDir "$Stamp-$Name.err.txt"
    Log "$Name`: $Exe $ArgString"
    $p = Start-Process -FilePath $Exe -ArgumentList $ArgString -PassThru -WindowStyle Hidden `
         -RedirectStandardOutput $out -RedirectStandardError $err
    $null = $p.Handle
    if (-not $p.WaitForExit($StepTimeoutSec * 1000)) {
        $p.Kill()
        throw "$Name`: Zeitueberschreitung nach $StepTimeoutSec s"
    }
    $text = ''
    foreach ($f in $out, $err) { if (Test-Path $f) { $text += (Get-Content -Path $f -Raw) } }
    Log "$Name`: Exitcode $($p.ExitCode)"
    [pscustomobject]@{ ExitCode = $p.ExitCode; Text = $text }
}

# reg.exe schreibt auch Erfolgsmeldungen auf stderr; mit 'Stop' wuerde 2>&1 daraus einen Abbruch machen.
function Invoke-Reg([string[]]$RegArgs) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & reg.exe @RegArgs 2>&1 | Out-Null; $code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $old }
    Log "reg $($RegArgs -join ' '): Exitcode $code"
}

function Get-RunningFromInstallDir {
    @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path -like "$InstallDir\*" })
}

function Get-InstalledVersion {
    $r = Invoke-Tool $Maintenance '--default-answer list' 'list'
    if ($r.Text -match 'name="BankingManager"[^>]*version="([\d\.]+)"') { return [version]$Matches[1] }
    throw 'Installierte Version konnte nicht ermittelt werden.'
}

$rollbackNeeded = $false
$exitCode = 0

try {
    Log '==== Update gestartet ===='
    Set-Status 'Update gestartet ...'

    # 1. Neuesten Installer finden (Dateiname strikt gepraegt)
    $cands = @(Get-ChildItem -Path $DownloadDir -Filter 'banking_manager_update_*.exe' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^banking_manager_update_\d+\.\d+\.\d+\.\d+\.exe$' } |
        ForEach-Object {
            $null = $_.Name -match '^banking_manager_update_(\d+\.\d+\.\d+\.\d+)\.exe$'
            [pscustomobject]@{ File = $_; Version = [version]$Matches[1] }
        } | Sort-Object Version -Descending)
    if ($cands.Count -eq 0) { throw "Kein Update-Installer in $DownloadDir gefunden." }
    $new = $cands[0]
    Log "Kandidat: $($new.File.FullName) (Version $($new.Version))"

    # 2. Nur Upgrades, kein Downgrade
    $installed = Get-InstalledVersion
    Log "Installiert: $installed"
    if ($new.Version -le $installed) {
        Log 'Nichts zu tun.'
        Set-Status "OK: bereits aktuell ($installed), kein neueres Update vorhanden."
        exit 0
    }

    # 3. Laufende Instanz? Nicht abschiessen (ungespeicherte Arbeit), sondern abbrechen.
    if (@(Get-RunningFromInstallDir).Count -gt 0) {
        Log 'BankingManager laeuft noch - Abbruch.'
        Set-Status 'FEHLER: BankingManager laeuft noch. Bitte schliessen (auch auf anderen Sitzungen) und erneut starten.'
        exit 2
    }

    # 4. In Admin-Ordner kopieren, dort pruefen (verhindert Austausch nach der Pruefung)
    Get-ChildItem -Path $Staging -Force | Remove-Item -Recurse -Force
    $staged = Join-Path $Staging $new.File.Name
    Copy-Item -Path $new.File.FullName -Destination $staged
    $hash = (Get-FileHash -Path $staged -Algorithm SHA256).Hash.ToUpper()
    $sig  = Get-AuthenticodeSignature -FilePath $staged
    $allowed = @()
    if (Test-Path $HashFile) {
        $allowed = @(Get-Content $HashFile | Where-Object { $_ -and -not $_.StartsWith('#') } |
                     ForEach-Object { ($_ -split '\s+')[0].Trim().ToUpper() })
    }
    $sigOk = ($ExpectedPublisher -ne '') -and ($sig.Status -eq 'Valid') -and
             ($sig.SignerCertificate.Subject -like "*$ExpectedPublisher*")
    Log "SHA256 $hash; Signatur $($sig.Status); Signer $(if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject })"
    if (-not ($sigOk -or ($allowed -contains $hash))) {
        throw 'Installer nicht freigegeben (weder gueltige Herausgeber-Signatur noch Hash in allowed_hashes.txt).'
    }

    # 5. Sicherung
    New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
    Copy-Tree $InstallDir (Join-Path $BackupDir 'ProgramFiles')
    if (Test-Path $DataDir) { Copy-Tree $DataDir (Join-Path $BackupDir 'ProgramData') }
    Invoke-Reg @('export', $UninstallKey, (Join-Path $BackupDir 'uninstall.reg'), '/y')
    $i = 0
    foreach ($p in $ExtraBackupPaths) {
        $i++
        if (Test-Path $p) {
            $dst = Join-Path $BackupDir "extra\$i"
            New-Item -ItemType Directory -Force -Path $dst | Out-Null
            Copy-Item -Path $p -Destination $dst -Recurse -Force
        }
    }
    Log "Sicherung in $BackupDir"

    # 6. Deinstallieren (ab hier ist ein Rollback noetig, wenn etwas scheitert)
    $rollbackNeeded = $true
    Set-Status 'Deinstalliere alte Version ...'
    $r = Invoke-Tool $Maintenance '-d --default-answer --confirm-command purge' 'purge'
    if ($r.ExitCode -ne 0) {
        # Wenn die Installation unberuehrt ist, braucht es keinen Rollback.
        if ((Test-Path $Maintenance) -and (Test-Path (Join-Path $InstallDir 'bin\BankingManager.exe'))) { $rollbackNeeded = $false }
        throw "Deinstallation fehlgeschlagen (Exitcode $($r.ExitCode))."
    }
    for ($n = 0; $n -lt 60 -and (Test-Path $Maintenance); $n++) { Start-Sleep -Seconds 2 }   # Wartungstool loescht sich verzoegert
    if (Test-Path $Maintenance) { throw 'Wartungstool nach purge noch vorhanden.' }
    if (Test-Path $InstallDir) { Remove-Item -Path $InstallDir -Recurse -Force }

    # 7. Benutzer-/Konfigurationsdaten zurueck, damit der Installer sie vorfindet
    if (Test-Path (Join-Path $BackupDir 'ProgramData')) { Copy-Tree (Join-Path $BackupDir 'ProgramData') $DataDir }

    # 8. Installieren
    Set-Status 'Installiere neue Version ...'
    $installArgs = '-d --accept-licenses --default-answer --confirm-command ' +
                   "--root `"$InstallDir`" install AllUsers=true addToStartMenu=true addToDesktop=true shortcutName=BankingManager"
    $r = Invoke-Tool $staged $installArgs 'install'
    if ($r.ExitCode -ne 0) { throw "Installation fehlgeschlagen (Exitcode $($r.ExitCode))." }

    # Der Installer startet am Ende ggf. das Programm; unter SYSTEM unerwuenscht.
    Get-RunningFromInstallDir | ForEach-Object { Log "Beende $($_.Name) ($($_.Id))"; $_.Kill() }

    # 9. Pruefen
    if (-not (Test-Path (Join-Path $InstallDir 'bin\BankingManager.exe'))) { throw 'bin\BankingManager.exe fehlt nach der Installation.' }
    $now = Get-InstalledVersion
    if ($now -ne $new.Version) { throw "Version nach Installation ist $now, erwartet $($new.Version)." }
    if ((Test-Path (Join-Path $BackupDir 'ProgramData\BankingManager.cfg')) -and -not (Test-Path (Join-Path $DataDir 'BankingManager.cfg'))) {
        Copy-Item (Join-Path $BackupDir 'ProgramData\BankingManager.cfg') $DataDir
        Log 'BankingManager.cfg war weg und wurde wiederhergestellt.'
    }
    $rollbackNeeded = $false

    # 10. Aufraeumen
    $oldBat = Join-Path $BackupDir 'ProgramFiles\start_admin.bat'
    if (Test-Path $oldBat) { Copy-Item $oldBat $InstallDir -Force; Log 'start_admin.bat wiederhergestellt.' }
    Get-ChildItem -Path $Staging -Force | Remove-Item -Recurse -Force
    Get-ChildItem -Path (Join-Path $WorkDir 'backup') -Directory | Sort-Object Name -Descending |
        Select-Object -Skip $KeepBackups | Remove-Item -Recurse -Force
    Log "Update auf $now erfolgreich."
    Set-Status "OK: BankingManager ist jetzt Version $now."
}
catch {
    $exitCode = 1
    Log "FEHLER: $($_.Exception.Message)"
    if ($rollbackNeeded) {
        try {
            Log 'Rollback ...'
            Get-RunningFromInstallDir | ForEach-Object { $_.Kill() }
            Copy-Tree (Join-Path $BackupDir 'ProgramFiles') $InstallDir -Mirror
            if (Test-Path (Join-Path $BackupDir 'ProgramData')) { Copy-Tree (Join-Path $BackupDir 'ProgramData') $DataDir -Mirror }
            if (Test-Path (Join-Path $BackupDir 'uninstall.reg')) { Invoke-Reg @('import', (Join-Path $BackupDir 'uninstall.reg')) }
            $i = 0
            foreach ($p in $ExtraBackupPaths) {
                $i++
                $src = Join-Path $BackupDir "extra\$i"
                if (Test-Path $src) { Copy-Item -Path (Join-Path $src '*') -Destination (Split-Path -Parent $p) -Recurse -Force }
            }
            Log 'Rollback abgeschlossen.'
            Set-Status "FEHLER: $($_.Exception.Message) - alte Version wurde wiederhergestellt."
        }
        catch {
            Log "ROLLBACK FEHLGESCHLAGEN: $($_.Exception.Message) - Sicherung liegt in $BackupDir"
            Set-Status "FEHLER: Update und Rollback fehlgeschlagen. Administrator informieren (Sicherung: $BackupDir)."
        }
    }
    else {
        Set-Status "FEHLER: $($_.Exception.Message)"
    }
}
exit $exitCode
