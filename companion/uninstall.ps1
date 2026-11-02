#requires -Version 5.1
<#
    Remove the companion: stop the worker, unregister the scheduled task.
    Logs and the spool directory are kept for inspection.
#>

$Root = $PSScriptRoot
$TaskName = 'DSH_ElevCompanion'
$WorkerPath = Join-Path $Root 'worker.ps1'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', "`"$PSCommandPath`""
    ) | Out-Null
    exit 0
}

Write-Host 'Stopping worker...'
Set-Content -Path (Join-Path $Root 'stop.flag') -Value 'stop' -Encoding ASCII -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3
Remove-Item (Join-Path $Root 'stop.flag') -Force -ErrorAction SilentlyContinue

try {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*$WorkerPath*" } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
} catch { }

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($task) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "Task '$TaskName' removed."
} else {
    Write-Host "Task '$TaskName' was not registered."
}

Write-Host 'Companion uninstalled. spool/ and logs were left in place.'
