#requires -Version 5.1
<#
    Word COM conversion helper. Runs as a SEPARATE process (spawned by the
    companion worker with a hard timeout) so a hung Word can never block the
    worker's request loop.

    Usage: powershell -File word-convert.ps1 -In a.doc -Out a.docx -Format docx
#>
param(
    [Parameter(Mandatory = $true)][string]$In,
    [Parameter(Mandatory = $true)][string]$Out,
    [Parameter(Mandatory = $true)][ValidateSet('docx', 'txt', 'pdf')][string]$Format
)

$logDir = Join-Path $PSScriptRoot 'logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
$log = Join-Path $logDir 'word-convert.log'

function L([string]$m) {
    try { Add-Content -Path $log -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') + ' ' + $m) -Encoding UTF8 } catch { }
}

$word = $null
try {
    L "start in=$In out=$Out fmt=$Format pid=$PID"
    $fmt = @{ docx = 16; txt = 7; pdf = 17 }[$Format]
    $word = New-Object -ComObject Word.Application
    $word.Visible = $false
    $word.DisplayAlerts = 0
    $word.AutomationSecurity = 3          # msoAutomationSecurityForceDisable
    $word.Options.ConfirmConversions = $false
    $doc = $word.Documents.Open($In, $false, $true)   # ConfirmConversions=$false, ReadOnly=$true
    try {
        $doc.SaveAs2($Out, $fmt)
    } finally {
        try { $doc.Close(0) } catch { }
    }
    L 'done'
    exit 0
} catch {
    L ('ERROR: ' + $_.Exception.GetType().FullName + ' :: ' + $_.Exception.Message)
    exit 1
} finally {
    if ($word) { try { $word.Quit() } catch { } }
}
