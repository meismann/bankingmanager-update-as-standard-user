<#
  Start-Update.ps1  -  vom normalen Benutzer per Desktop-Verknuepfung gestartet.
  Startet nur die geplante Aufgabe "BankingManager Update" und zeigt das Ergebnis an.
  Nur ASCII, damit Windows PowerShell 5.1 sie ohne BOM korrekt liest.
#>

$TaskName = 'BankingManager Update'
$Status   = 'C:\ProgramData\BankingManagerUpdate\public\status.txt'

Add-Type -AssemblyName System.Windows.Forms
function Show([string]$Text, [string]$Buttons = 'OK', [string]$Icon = 'Information') {
    [System.Windows.Forms.MessageBox]::Show($Text, 'BankingManager Update', $Buttons, $Icon)
}

if ((Show 'Das Update wird jetzt installiert. BankingManager muss dafuer auf allen Sitzungen geschlossen sein. Fortfahren?' 'OKCancel' 'Question') -ne 'OK') { exit 0 }

try {
    $svc = New-Object -ComObject 'Schedule.Service'
    $svc.Connect()
    $task = $svc.GetFolder('\').GetTask($TaskName)
    $null = $task.Run($null)
}
catch {
    Show "Das Update konnte nicht gestartet werden: $($_.Exception.Message)" 'OK' 'Error' | Out-Null
    exit 1
}

# 4 = Running, 2 = Queued
Start-Sleep -Seconds 5
$deadline = (Get-Date).AddMinutes(30)
while ((Get-Date) -lt $deadline) {
    $task = $svc.GetFolder('\').GetTask($TaskName)
    if ($task.State -ne 4 -and $task.State -ne 2) { break }
    Start-Sleep -Seconds 3
}

$text = if (Test-Path $Status) { Get-Content -Path $Status -Raw } else { 'Kein Ergebnis gefunden.' }
$icon = if ($text -match '^\S+ \S+ OK') { 'Information' } else { 'Warning' }
Show $text 'OK' $icon | Out-Null
