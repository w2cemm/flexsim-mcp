#requires -Version 5.1
<#
    Start (or restart) the elevated companion.

    If a worker is already running it is stopped first, so this is also the
    update path after worker.ps1 changes.

    Only if that fails does the script fall back to a UAC prompt.
#>
param([switch]$Elevated)

$Root = $PSScriptRoot
$Status = Join-Path $Root 'status.json'
$TaskName = 'DSH_ElevCompanion'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-FreshStatus([int]$MaxAgeSec = 10) {
    if (-not (Test-Path $Status)) { return $null }
    try {
        $st = Get-Content $Status -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $st.elevated) { return $null }
        if ($st.state -eq 'stopped') { return $null }
        $beat = [datetime]::Parse($st.lastBeat, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
        if (((Get-Date) - $beat).TotalSeconds -gt $MaxAgeSec) { return $null }
        return $st
    } catch { return $null }
}

$st = Get-FreshStatus
if ($st) {
    # Restart instead of "already running": this is also the update path after
    # worker.ps1 changed (the supervisor keeps the old code until it is replaced).
    Write-Host "Restarting companion (current pid=$($st.pid))..." -ForegroundColor Yellow
    $stopFile = Join-Path $Root 'stop.flag'
    $mutexName = 'Local\DSH_ElevCompanionSuper'
    $stopBy = (Get-Date).AddSeconds(25)
    while ((Get-Date) -lt $stopBy) {
        # keep rewriting: the worker may consume the flag before the supervisor sees it
        Set-Content -Path $stopFile -Value 'stop' -Encoding ASCII -ErrorAction SilentlyContinue
        $m = $null
        $exists = $false
        try { $exists = [System.Threading.Mutex]::TryOpenExisting($mutexName, [ref]$m) } catch { $exists = $false }
        if ($m) { try { $m.Dispose() } catch { } }
        if (-not $exists) { break }
        Start-Sleep -Milliseconds 150
    }
    Remove-Item $stopFile -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 600
}

if ($Elevated -or (Test-Admin)) {
    # elevated path: use the ScheduledTasks module directly
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $task) {
        Write-Host "Task '$TaskName' is not registered. Run companion\install.cmd as administrator first." -ForegroundColor Red
        exit 1
    }
    Write-Host "Starting task '$TaskName' (elevated)..."
    Start-ScheduledTask -TaskName $TaskName
} else {
    Write-Host "Triggering scheduled task '$TaskName'..."
    & schtasks.exe /run /tn $TaskName 2>&1 | Out-Null
}

$deadline = (Get-Date).AddSeconds(25)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500
    $st = Get-FreshStatus
    if ($st) {
        Write-Host "Started: pid=$($st.pid) integrity=$($st.integrity) user=$($st.user)" -ForegroundColor Green
        exit 0
    }
}

if (-not $Elevated) {
    Write-Host 'Non-elevated trigger did not work; retrying with UAC...' -ForegroundColor Yellow
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', "`"$PSCommandPath`"", '-Elevated'
    ) | Out-Null
    exit 0
}

Write-Host 'Worker did not report an elevated heartbeat. Check companion\audit.log.' -ForegroundColor Red
exit 1
