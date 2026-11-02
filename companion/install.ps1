#requires -Version 5.1
<#
    DSH Elevated Companion - one-time installer (must run as Administrator).

    What it does:
      1. creates the spool directories and hardens their ACLs / integrity labels
      2. registers scheduled task "DSH_ElevCompanion" (RunLevel=Highest,
         logon trigger, runs only in the interactive session) - no UAC prompt
         is needed for subsequent starts
      3. starts the worker and runs an end-to-end self-test
      4. writes the result to companion\install.log

    Run: right-click companion\install.cmd -> "Run as administrator",
         or just double-click install.cmd and accept the UAC prompt.
#>

$Root    = $PSScriptRoot
$Worker  = Join-Path $Root 'worker.ps1'
$Client  = Join-Path $Root 'client.ps1'
$Inbox   = Join-Path $Root 'spool\inbox'
$Outbox  = Join-Path $Root 'spool\outbox'
$Done    = Join-Path $Root 'spool\processed'
$Status  = Join-Path $Root 'status.json'
$Log     = Join-Path $Root 'install.log'
$TaskName = 'DSH_ElevCompanion'
$User    = "$env:USERDOMAIN\$env:USERNAME"

function Log([string]$m) {
    $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' ' + $m
    Write-Host $line
    Add-Content -Path $Log -Value $line -Encoding UTF8
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    Write-Host 'Elevation required - requesting UAC consent...' -ForegroundColor Yellow
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', "`"$PSCommandPath`""
    ) | Out-Null
    exit 0
}

Remove-Item $Log -Force -ErrorAction SilentlyContinue
Log "=== install start user=$User admin=True"

if (-not (Test-Path $Worker)) { Log "ERROR: worker.ps1 not found at $Worker"; exit 1 }

# ---------------------------------------------------------------- directories
foreach ($d in @($Inbox, $Outbox, $Done)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
}
# Supervisor mode: the task keeps a supervisor alive which restarts the worker
# after crashes and reloads (no more "worker died, find a UAC prompt").
Set-Content -Path (Join-Path $Root 'supervise.flag') -Value '1' -Encoding ASCII -ErrorAction SilentlyContinue

try {
    # inbox: the agent (Low/Medium integrity) must be able to drop requests,
    # so this directory is labelled Low; the worker validates every request.
    & icacls.exe $Inbox /grant "${User}:(OI)(CI)M" | Out-Null
    & icacls.exe $Inbox /setintegritylevel '(OI)(CI)L' | Out-Null
    Log 'acl: inbox -> user modify, integrity Low'

    # outbox: only the elevated worker writes results; the agent may read them
    # but cannot modify or forge them.
    & icacls.exe $Outbox /grant "${User}:(OI)(CI)RX" | Out-Null
    & icacls.exe $Outbox /setintegritylevel '(OI)(CI)M' | Out-Null
    Log 'acl: outbox -> user read, integrity Medium'

    # processed: worker only
    & icacls.exe $Done /grant "${User}:(OI)(CI)RX" | Out-Null
    & icacls.exe $Done /setintegritylevel '(OI)(CI)M' | Out-Null
    Log 'acl: processed -> user read, integrity Medium'
} catch {
    Log ('ERROR applying ACLs: ' + $_.Exception.Message)
    exit 1
}

# ---------------------------------------------------------------- stop old worker
$stopFlag = Join-Path $Root 'stop.flag'
Set-Content -Path $stopFlag -Value 'stop' -Encoding ASCII -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
Remove-Item $stopFlag -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------- scheduled task
try {
    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existing) { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue }

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument (
        '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $Worker + '" -Supervise')
    $principal = New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel Highest
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $User
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew `
        -RestartCount 5 -RestartInterval (New-TimeSpan -Minutes 1)

    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Force | Out-Null
    Log "task registered: $TaskName (RunLevel=Highest, AtLogOn, Interactive)"

    Start-ScheduledTask -TaskName $TaskName
    Log 'task started'
} catch {
    Log ('ERROR registering task: ' + $_.Exception.Message)
    exit 1
}

# ---------------------------------------------------------------- wait for worker
$deadline = (Get-Date).AddSeconds(40)
$alive = $false
while ((Get-Date) -lt $deadline) {
    if (Test-Path $Status) {
        try {
            $st = Get-Content $Status -Raw -Encoding UTF8 | ConvertFrom-Json
            $beat = [datetime]::Parse($st.lastBeat, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
            if ($st.elevated -and ((Get-Date) - $beat).TotalSeconds -lt 10) { $alive = $true; break }
        } catch { }
    }
    Start-Sleep -Milliseconds 500
}

if (-not $alive) {
    Log 'ERROR: worker did not come up (no elevated heartbeat within 40s).'
    Log '  inspect: Get-ScheduledTaskInfo -TaskName DSH_ElevCompanion; companion\audit.log'
    exit 1
}
Log "worker alive pid=$($st.pid) integrity=$($st.integrity)"

# ---------------------------------------------------------------- self test
. $Client
$ok = $true
try {
    $ping = Invoke-Companion -Action ping -TimeoutSec 20
    Log ("selftest ping: integrity=$($ping.data.integrity) elevated=$($ping.data.elevated) canWriteProgramFiles=$($ping.data.programFilesWritable) ps=$($ping.data.powershell)")

    $wl = Invoke-Companion -Action 'window.list' -Params @{ maxItems = 20 } -TimeoutSec 20
    Log ("selftest window.list: count=$($wl.data.count)")

    $shot = Join-Path $Root 'selftest.png'
    $sc = Invoke-Companion -Action screenshot -Params @{ outFile = $shot } -TimeoutSec 20
    Log ("selftest screenshot: ok=$($sc.data.ok) path=$($sc.data.path)")

    if (-not $ping.data.elevated) { Log 'SELFTEST FAIL: worker is not elevated'; $ok = $false }
    if (-not $ping.data.programFilesWritable) { Log 'SELFTEST WARN: Program Files not writable from worker'; }
} catch {
    Log ('SELFTEST ERROR: ' + $_.Exception.Message)
    $ok = $false
}

if ($ok) {
    Log '=== install OK - companion is ready'
    Write-Host ''
    Write-Host 'Companion is ready. DSH can now call companion\client.ps1 -> Invoke-Companion.' -ForegroundColor Green
} else {
    Log '=== install FAILED'
}
