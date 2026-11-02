#requires -Version 5.1
<#
    DSH Elevated Companion - client.

    Runs in the ordinary (possibly Low-integrity) agent context and talks to the
    elevated worker through files only, because UIPI blocks window messages in
    both directions across integrity levels.

    Usage:
        . .\companion\client.ps1
        Invoke-Companion -Action ping
        Invoke-Companion -Action window.find -Params @{ processName = 'flexsim' }
#>

$script:CompanionRoot   = $PSScriptRoot
$script:CompanionSpool  = Join-Path $script:CompanionRoot 'spool'
$script:CompanionInbox  = Join-Path $script:CompanionSpool 'inbox'
$script:CompanionOutbox = Join-Path $script:CompanionSpool 'outbox'
$script:CompanionStatus = Join-Path $script:CompanionRoot 'status.json'

function Get-CompanionStatus {
    [CmdletBinding()]
    param([int]$MaxAgeSec = 30)

    if (-not (Test-Path $script:CompanionStatus)) {
        throw "companion is not running: status.json missing. Run companion\start.cmd as administrator."
    }
    $st = Get-Content $script:CompanionStatus -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($st.state -eq 'stopped') {
        throw "companion reported state=stopped. Run companion\start.cmd (it usually needs no UAC)."
    }
    if (-not $st.lastBeat) {
        throw "companion status has no heartbeat yet (worker is starting). Retry in a moment."
    }
    $beat = [datetime]::Parse($st.lastBeat, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
    $age = [math]::Round(((Get-Date) - $beat).TotalSeconds, 1)
    $st | Add-Member -NotePropertyName ageSeconds -NotePropertyValue $age -Force
    if ($age -gt $MaxAgeSec) {
        throw "companion heartbeat is stale (${age}s > ${MaxAgeSec}s). Run companion\start.cmd (it usually needs no UAC)."
    }
    return $st
}

function Invoke-Companion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet(
            'ping', 'window.list', 'window.find', 'window.rect', 'child.list',
            'text.set', 'text.get', 'click', 'key', 'type', 'focus',
            'proc.start', 'proc.kill', 'proc.list', 'service.list', 'service.start', 'service.stop',
            'uia.find', 'uia.invoke', 'exec', 'mcp.start', 'file.read', 'file.write', 'office.convert', 'screenshot', 'wait', 'reload', 'stop')]
        [string]$Action,
        [hashtable]$Params = @{},
        [int]$TimeoutSec = 30,
        [switch]$AllowUnelevated
    )

    if (-not $AllowUnelevated) {
        # tolerate the few seconds of a reload hand-over / cold start
        $gate = (Get-Date).AddSeconds(25)
        $st = $null
        while ($true) {
            try { $st = Get-CompanionStatus; break } catch {
                if ((Get-Date) -gt $gate) { throw }
                Start-Sleep -Milliseconds 400
            }
        }
        if (-not $st.elevated) {
            throw "companion is running at integrity '$($st.integrity)', not elevated. Run companion\install.cmd as administrator."
        }
    }

    foreach ($d in @($script:CompanionInbox, $script:CompanionOutbox)) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    }

    $id = [guid]::NewGuid().ToString()
    $reqPath = Join-Path $script:CompanionInbox "req-$id.json"
    $resPath = Join-Path $script:CompanionOutbox "res-$id.json"

    $body = [ordered]@{
        id     = $id
        action = $Action
        params = $Params
        ts     = (Get-Date).ToString('o')
    }
    $json = $body | ConvertTo-Json -Compress -Depth 8
    $tmp = "$reqPath.tmp"
    [IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item $tmp $reqPath -Force

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $res = $null
    while ((Get-Date) -lt $deadline) {
        if (Test-Path $resPath) {
            try {
                $raw = [IO.File]::ReadAllText($resPath, [Text.Encoding]::UTF8)
                if ($raw -and $raw.Trim().Length -gt 0) { $res = $raw | ConvertFrom-Json; break }
            } catch { }
        }
        Start-Sleep -Milliseconds 60
    }

    if (-not $res) {
        # the request may still be picked up later; leave it for the worker to drain
        throw "companion timed out after ${TimeoutSec}s waiting for '$Action' (id=$id)"
    }
    if ($res.id -ne $id) { throw "companion returned mismatched id: $($res.id) != $id" }

    try { Remove-Item $resPath -Force -ErrorAction SilentlyContinue } catch { }

    if (-not $res.ok) {
        throw "companion action '$Action' failed: $($res.error)"
    }
    return $res
}

function Test-Companion {
    [CmdletBinding()]
    param([int]$TimeoutSec = 15)
    try {
        $p = Invoke-Companion -Action ping -TimeoutSec $TimeoutSec
        [pscustomobject]@{
            Running   = $true
            Elevated  = [bool]$p.data.elevated
            Integrity = $p.data.integrity
            Pid       = $p.data.pid
            Session   = $p.data.sessionId
            CanWriteProgramFiles = [bool]$p.data.programFilesWritable
        }
    } catch {
        [pscustomobject]@{
            Running   = $false
            Elevated  = $false
            Integrity = $null
            Pid       = $null
            Session   = $null
            CanWriteProgramFiles = $false
            Error     = $_.Exception.Message
        }
    }
}
