<#
  Setup-UpdateTask.ps1  -  einmalig als Administrator ausfuehren.

  Beispiel:
    powershell -ExecutionPolicy Bypass -File .\Setup-UpdateTask.ps1 -Users 'maxmustermann'

  Legt den Arbeitsordner (nur SYSTEM/Administratoren), die geplante Aufgabe (SYSTEM) und
  die Desktop-Verknuepfung an. Die angegebenen Benutzer duerfen die Aufgabe nur STARTEN.
  Nur ASCII, damit Windows PowerShell 5.1 sie ohne BOM korrekt liest.
#>
#Requires -RunAsAdministrator
param(
    [Parameter(Mandatory)][string[]]$Users
)

$ErrorActionPreference = 'Stop'
$WorkDir   = 'C:\ProgramData\BankingManagerUpdate'
$PublicDir = Join-Path $WorkDir 'public'
$TaskName  = 'BankingManager Update'
$here      = Split-Path -Parent $MyInvocation.MyCommand.Path

# Arbeitsordner: nur SYSTEM (S-1-5-18) und Administratoren (S-1-5-32-544); SIDs sind sprachunabhaengig
New-Item -ItemType Directory -Force -Path $WorkDir, $PublicDir | Out-Null
& icacls.exe $WorkDir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'icacls auf Arbeitsordner fehlgeschlagen.' }
# public: Benutzer duerfen lesen (Status, Start-Skript), nicht schreiben
& icacls.exe $PublicDir /grant '*S-1-5-11:(OI)(CI)RX' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'icacls auf public fehlgeschlagen.' }

Copy-Item (Join-Path $here 'Update-BankingManager.ps1') $WorkDir -Force
Copy-Item (Join-Path $here 'Start-Update.ps1') $PublicDir -Force

$hashFile = Join-Path $WorkDir 'allowed_hashes.txt'
if (-not (Test-Path $hashFile)) {
    Set-Content -Path $hashFile -Value '# Erlaubte SHA256-Hashes der Update-Installer, ein Hash pro Zeile (falls keine Herausgeber-Signatur geprueft wird)'
}

# Geplante Aufgabe unter SYSTEM, ohne Trigger
$action    = New-ScheduledTaskAction -Execute 'powershell.exe' `
             -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$WorkDir\Update-BankingManager.ps1`""
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 1) `
             -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName $TaskName -Action $action -Principal $principal -Settings $settings -Force | Out-Null

# Benutzer duerfen die Aufgabe lesen und ausfuehren (FRFX), nicht aendern
$svc = New-Object -ComObject 'Schedule.Service'
$svc.Connect()
$task = $svc.GetFolder('\').GetTask($TaskName)
$sddl = $task.GetSecurityDescriptor(4)    # 4 = DACL
foreach ($u in $Users) {
    $name = if ($u -like '*\*') { $u } else { "$env:COMPUTERNAME\$u" }
    $sid  = ([Security.Principal.NTAccount]$name).Translate([Security.Principal.SecurityIdentifier]).Value
    $sddl += "(A;;FRFX;;;$sid)"
    Write-Host "Startrecht fuer $name ($sid)"
}
$task.SetSecurityDescriptor($sddl, 0)

# Desktop-Verknuepfung fuer alle Benutzer
$ws = New-Object -ComObject WScript.Shell
$lnk = $ws.CreateShortcut('C:\Users\Public\Desktop\BankingManager aktualisieren.lnk')
$lnk.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PublicDir\Start-Update.ps1`""
$lnk.IconLocation = 'C:\Program Files\BankingManager\bin\BMIcon.ico'
$lnk.Save()

Write-Host ''
Write-Host 'Fertig. Noch zu tun:'
Write-Host '  VM-Snapshot anlegen, dann Testlauf: schtasks /run /tn "BankingManager Update"  und  update.log lesen.'
