#requires -Version 5.1
<#
    DSH Elevated Companion - High-integrity worker.

    Runs as Administrator (registered by install.ps1 as a scheduled task with
    RunLevel=Highest, logon trigger). It polls spool\inbox for request files,
    validates them against a strict whitelist, executes one action, and writes
    the result to spool\outbox. It never executes arbitrary scripts or commands.

    Protocol (JSON, one request per file):
      inbox\req-<guid>.json   { "id": "<guid>", "action": "<name>", "params": {..}, "ts": "<iso>" }
      outbox\res-<guid>.json  { "id": "<guid>", "ok": true|false, "action": "<name>",
                                "elapsedMs": 12, "data": {..}, "error": null }
#>
param(
    [switch]$Serve,
    [int]$PollMs = 150,
    [switch]$Child,
    [switch]$Supervise
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Off

$Root   = $PSScriptRoot
$Ws     = Split-Path $Root -Parent
$Spool  = Join-Path $Root 'spool'
$Inbox  = Join-Path $Spool 'inbox'
$Outbox = Join-Path $Spool 'outbox'
$Done   = Join-Path $Spool 'processed'
$Audit  = Join-Path $Root 'audit.log'
$Status = Join-Path $Root 'status.json'
$StopFile = Join-Path $Root 'stop.flag'

foreach ($d in @($Spool, $Inbox, $Outbox, $Done)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
}

$script:StartedAt = (Get-Date).ToString('o')
$script:LastAction = ''
$script:LastError = ''

function Write-Audit([string]$msg) {
    try {
        $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') + ' ' + $msg
        Add-Content -Path $Audit -Value $line -Encoding UTF8
        $fi = Get-Item $Audit -ErrorAction SilentlyContinue
        if ($fi -and $fi.Length -gt 4MB) {
            Move-Item $Audit ($Audit + '.1') -Force
        }
    } catch { }
}

function Write-Status {
    try {
        $fi = Get-Item $Status -ErrorAction SilentlyContinue
        if ($fi -and $fi.Length -gt 0) {
            $st = Get-Content $Status -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($st.stop -eq $true) { return }
        }
        $obj = [ordered]@{
            pid       = $PID
            user      = "$env:USERDOMAIN\$env:USERNAME"
            integrity = [Cmp]::Integrity()
            elevated  = [Cmp]::IsElevated()
            sessionId = (Get-Process -Id $PID).SessionId
            startedAt = $script:StartedAt
            lastBeat  = (Get-Date).ToString('o')
            lastAction = $script:LastAction
            lastError = $script:LastError
            version   = '1.0'
        }
        $tmp = "$Status.$PID.tmp"
        [System.IO.File]::WriteAllText($tmp, ($obj | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding($false)))
        if ([IO.File]::Exists($Status)) { [IO.File]::Replace($tmp, $Status, [NullString]::Value) }
        else { [IO.File]::Move($tmp, $Status) }
    } catch { Write-Audit ('heartbeat update failed: ' + $_.Exception.Message) }
}

# ---------------------------------------------------------------- supervisor
# The scheduled task starts this script in supervisor mode. The supervisor owns
# no automation state: it just keeps a worker child alive, so a crash or a
# `reload` costs ~0.5 s instead of "hunt down a UAC prompt".
if (-not $Child -and ($Supervise -or (Test-Path (Join-Path $Root 'supervise.flag')))) {
    $supMutex = New-Object System.Threading.Mutex($false, 'Local\DSH_ElevCompanionSuper')
    $haveSup = $false
    try { $haveSup = $supMutex.WaitOne(1500) } catch [System.Threading.AbandonedMutexException] { $haveSup = $true }

    if (-not $haveSup) {
        # An incumbent supervisor is alive. Ask it to step down (by refreshing the
        # stop flag it polls) and take over when it exits. This is what makes
        # `schtasks /run` an in-place upgrade instead of a no-op.
        Write-Audit "=== supervisor handover request pid=$PID"
        $deadline = (Get-Date).AddSeconds(30)
        while (-not $haveSup -and (Get-Date) -lt $deadline) {
            Set-Content -Path $StopFile -Value 'stop' -Encoding ASCII -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 300
            try { $haveSup = $supMutex.WaitOne(500) } catch [System.Threading.AbandonedMutexException] { $haveSup = $true }
        }
        if (-not $haveSup) { Write-Audit '=== supervisor handover timeout'; exit 0 }
    }

    Remove-Item $StopFile -Force -ErrorAction SilentlyContinue
    Write-Audit "=== supervisor start pid=$PID"
    $mcpExe = Join-Path $env:USERPROFILE '.local\bin\windows-mcp.exe'
    $mcpLog = Join-Path $Root 'logs\mcp.log'
    $mcpErr = Join-Path $Root 'logs\mcp.err.log'
    $logDir = Join-Path $Root 'logs'
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
    $mcpProc = $null
    $mcpLastStart = [DateTime]::MinValue
    $wrk = $null
    try {
        while ($true) {
            if (Test-Path $StopFile) {
                Write-Audit '=== supervisor: stop flag found'
                Remove-Item $StopFile -Force -ErrorAction SilentlyContinue
                break
            }

            # --- MCP server (streamable-http on loopback), supervised like the worker
            if ((Test-Path $mcpExe) -and (-not $mcpProc -or $mcpProc.HasExited)) {
                if (([DateTime]::Now - $mcpLastStart).TotalSeconds -lt 3) { Start-Sleep -Seconds 2 }
                try {
                    $mcpProc = Start-Process -FilePath $mcpExe -WindowStyle Hidden -PassThru `
                        -RedirectStandardOutput $mcpLog -RedirectStandardError $mcpErr `
                        -ArgumentList @('serve', '--transport', 'streamable-http', '--host', '127.0.0.1', '--port', '8000')
                    $mcpLastStart = [DateTime]::Now
                    Write-Audit "=== supervisor: mcp started pid=$($mcpProc.Id)"
                } catch {
                    Write-Audit ('=== supervisor: mcp spawn failed: ' + $_.Exception.Message)
                    Start-Sleep -Seconds 3
                }
            }

            # --- worker child
            if (-not $wrk -or $wrk.HasExited) {
                if ($wrk) {
                    $code0 = -1
                    try { $code0 = $wrk.ExitCode } catch { }
                    Write-Audit "=== supervisor: worker exited code=$code0, restarting"
                    if ($code0 -ne 3) { Start-Sleep -Milliseconds 700 }
                }
                $wrk = $null
                try {
                    $wrk = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -PassThru -ArgumentList @(
                        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
                        '-File', $PSCommandPath, '-Child', '-Serve')
                    Write-Audit "=== supervisor: spawned worker pid=$($wrk.Id)"
                } catch {
                    Write-Audit ('=== supervisor: spawn failed: ' + $_.Exception.GetType().FullName + ' :: ' + $_.Exception.Message)
                    Start-Sleep -Seconds 2
                }
            }
            Start-Sleep -Milliseconds 400
        }
    } catch {
        Write-Audit ('=== supervisor: fatal: ' + $_.Exception.Message)
    } finally {
        Write-Audit "=== supervisor stop pid=$PID"
        try { $supMutex.ReleaseMutex() } catch { }
        $supMutex.Dispose()
    }
    exit 0
}

# ---------------------------------------------------------------- native interop
Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Drawing;
using System.Drawing.Imaging;

public class Cmp {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Explicit)] public struct INPUTUNION {
        [FieldOffset(0)] public MOUSEINPUT mi;
        [FieldOffset(0)] public KEYBDINPUT ki;
    }
    [StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public INPUTUNION u; }

    public delegate bool EnumProc(IntPtr h, IntPtr l);

    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr p, EnumProc cb, IntPtr l);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder sb, int max);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder sb, int max);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextLength(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint attach, uint attachTo, bool fAttach);
    [DllImport("user32.dll")] public static extern void SwitchToThisWindow(IntPtr h, bool altTab);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern IntPtr GetParent(IntPtr h);
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int idx);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll", SetLastError = true)] public static extern uint SendInput(uint n, INPUT[] a, int size);
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern IntPtr SendMessageTimeout(IntPtr h, uint msg, IntPtr w, IntPtr l, uint flags, uint timeout, out IntPtr res);

    [DllImport("kernel32.dll")] public static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll", SetLastError = true)] public static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern IntPtr VirtualAllocEx(IntPtr p, IntPtr addr, UIntPtr size, uint type, uint protect);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool VirtualFreeEx(IntPtr p, IntPtr addr, UIntPtr size, uint type);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool WriteProcessMemory(IntPtr p, IntPtr addr, byte[] buf, UIntPtr size, out UIntPtr written);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool ReadProcessMemory(IntPtr p, IntPtr addr, byte[] buf, UIntPtr size, out UIntPtr read);

    [DllImport("advapi32.dll", SetLastError = true)] public static extern bool OpenProcessToken(IntPtr p, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true)] public static extern bool GetTokenInformation(IntPtr token, int cls, IntPtr info, int len, out int ret);

    [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr h);
    [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr h, IntPtr dc);
    [DllImport("gdi32.dll")] public static extern IntPtr CreateCompatibleDC(IntPtr dc);
    [DllImport("gdi32.dll")] public static extern IntPtr CreateCompatibleBitmap(IntPtr dc, int w, int h);
    [DllImport("gdi32.dll")] public static extern IntPtr SelectObject(IntPtr dc, IntPtr obj);
    [DllImport("gdi32.dll")] public static extern bool BitBlt(IntPtr dst, int x, int y, int w, int h, IntPtr src, int sx, int sy, uint rop);
    [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr obj);
    [DllImport("gdi32.dll")] public static extern bool DeleteDC(IntPtr dc);

    public struct POINT { public int X; public int Y; }

    public const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
    public const uint MOUSEEVENTF_LEFTUP = 0x0004;
    public const uint MOUSEEVENTF_RIGHTDOWN = 0x0008;
    public const uint MOUSEEVENTF_RIGHTUP = 0x0010;
    public const uint KEYEVENTF_KEYUP = 0x0002;
    public const uint KEYEVENTF_UNICODE = 0x0004;

    public static string Integrity() {
        IntPtr token;
        if (!OpenProcessToken(GetCurrentProcess(), 0x0008, out token)) return "Unknown";
        int len = 0;
        GetTokenInformation(token, 25, IntPtr.Zero, 0, out len);
        if (len <= 0) { CloseHandle(token); return "Unknown"; }
        IntPtr buf = Marshal.AllocHGlobal(len);
        try {
            if (!GetTokenInformation(token, 25, buf, len, out len)) return "Unknown";
            IntPtr sid = Marshal.ReadIntPtr(buf);
            int count = Marshal.ReadByte(sid, 1);
            if (count < 1) return "Unknown";
            int rid = Marshal.ReadInt32(sid, 8 + 4 * (count - 1));
            switch (rid) {
                case 0x1000: return "Low";
                case 0x2000: return "Medium";
                case 0x3000: return "High";
                case 0x4000: return "System";
                default: return "IL-" + rid;
            }
        } finally {
            Marshal.FreeHGlobal(buf);
            CloseHandle(token);
        }
    }

    public static bool IsElevated() {
        string il = Integrity();
        return il == "High" || il == "System";
    }

    public static string ClassOf(IntPtr h) {
        var sb = new StringBuilder(256);
        GetClassName(h, sb, 256);
        return sb.ToString();
    }

    public static string TitleOf(IntPtr h) {
        int n = GetWindowTextLength(h);
        var sb = new StringBuilder(n + 2);
        GetWindowText(h, sb, n + 2);
        return sb.ToString();
    }

    public static List<IntPtr> TopWindows() {
        var list = new List<IntPtr>();
        EnumWindows(delegate(IntPtr h, IntPtr l) { list.Add(h); return true; }, IntPtr.Zero);
        return list;
    }

    public static List<IntPtr> Children(IntPtr parent) {
        var list = new List<IntPtr>();
        EnumChildWindows(parent, delegate(IntPtr h, IntPtr l) { list.Add(h); return true; }, IntPtr.Zero);
        return list;
    }

    public static int[] Rect(IntPtr h) {
        RECT r;
        if (!GetWindowRect(h, out r)) return null;
        return new int[] { r.Left, r.Top, r.Right, r.Bottom };
    }

    public static uint PidOf(IntPtr h) {
        uint pid;
        GetWindowThreadProcessId(h, out pid);
        return pid;
    }

    public static bool Focus(IntPtr h) { return FocusEx(h, out _detail); }
    public static string _detail = "";

    public static bool FocusEx(IntPtr h, out string detail) {
        IntPtr fg0 = GetForegroundWindow();
        var d = new StringBuilder();
        d.Append("fg0=" + fg0.ToInt64() + ";");
        if (IsIconic(h)) { ShowWindow(h, 9); } // SW_RESTORE only when minimized
        BringWindowToTop(h);

        uint tmp;
        uint fgThread = fg0 == IntPtr.Zero ? 0 : GetWindowThreadProcessId(fg0, out tmp);
        uint myThread = GetCurrentThreadId();
        bool attached = false;
        if (fgThread != 0 && fgThread != myThread) { attached = AttachThreadInput(myThread, fgThread, true); }
        d.Append("attached=" + attached + ";");
        bool setOk = SetForegroundWindow(h);
        if (attached) { AttachThreadInput(myThread, fgThread, false); }
        d.Append("setFg=" + setOk + ";");
        IntPtr fg1 = GetForegroundWindow();
        d.Append("fg1=" + fg1.ToInt64() + ";");

        if (fg1 != h) {
            SwitchToThisWindow(h, true);
            System.Threading.Thread.Sleep(200);
            IntPtr fg2 = GetForegroundWindow();
            d.Append("fg2=" + fg2.ToInt64() + ";");
            if (fg2 != h) {
                // Last resort: a synthetic ALT keystroke marks this process as the
                // last input receiver, which lifts the foreground lock.
                keybd_event(0x12, 0, 0, UIntPtr.Zero);
                keybd_event(0x12, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
                System.Threading.Thread.Sleep(60);
                SetForegroundWindow(h);
                System.Threading.Thread.Sleep(200);
            }
        }
        IntPtr fg3 = GetForegroundWindow();
        d.Append("fg3=" + fg3.ToInt64());
        detail = d.ToString();
        return fg3 == h;
    }

    public static void Click(int x, int y, string button) {
        SetCursorPos(x, y);
        System.Threading.Thread.Sleep(60);
        uint down = MOUSEEVENTF_LEFTDOWN, up = MOUSEEVENTF_LEFTUP;
        if (button == "right") { down = MOUSEEVENTF_RIGHTDOWN; up = MOUSEEVENTF_RIGHTUP; }
        INPUT[] a = new INPUT[2];
        a[0].type = 0; a[0].u.mi.dwFlags = down;
        a[1].type = 0; a[1].u.mi.dwFlags = up;
        SendInput(2, a, Marshal.SizeOf(typeof(INPUT)));
    }

    public static void Chord(byte[] mods, byte vk) {
        foreach (byte m in mods) { keybd_event(m, 0, 0, UIntPtr.Zero); System.Threading.Thread.Sleep(40); }
        keybd_event(vk, 0, 0, UIntPtr.Zero);
        System.Threading.Thread.Sleep(60);
        keybd_event(vk, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
        for (int i = mods.Length - 1; i >= 0; i--) { System.Threading.Thread.Sleep(30); keybd_event(mods[i], 0, KEYEVENTF_KEYUP, UIntPtr.Zero); }
    }

    public static void TypeText(string s) {
        foreach (char c in s) {
            INPUT[] a = new INPUT[2];
            a[0].type = 1; a[0].u.ki.wScan = (ushort)c; a[0].u.ki.dwFlags = KEYEVENTF_UNICODE;
            a[1].type = 1; a[1].u.ki.wScan = (ushort)c; a[1].u.ki.dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP;
            SendInput(2, a, Marshal.SizeOf(typeof(INPUT)));
            System.Threading.Thread.Sleep(2);
        }
    }

    public static long SciValue(IntPtr hwnd, uint message) {
        IntPtr result;
        if (SendMessageTimeout(hwnd, message, IntPtr.Zero, IntPtr.Zero, 2, 1500, out result) == IntPtr.Zero)
            throw new TimeoutException("Scintilla did not respond to " + message);
        return result.ToInt64();
    }

    public static string AncestorTitles(IntPtr hwnd) {
        var result = new StringBuilder();
        for (int i = 0; hwnd != IntPtr.Zero && i < 16; i++, hwnd = GetParent(hwnd)) {
            result.Append(TitleOf(hwnd)).Append("|");
        }
        return result.ToString();
    }

    private static Encoding SciEncoding(IntPtr hwnd) {
        int codePage = (int)SciValue(hwnd, 2137); // SCI_GETCODEPAGE
        return codePage == 0 ? Encoding.Default : Encoding.GetEncoding(codePage);
    }

    public static bool SetText(IntPtr hwnd, string text) {
        if (SciValue(hwnd, 2140) != 0) return false; // never write to a read-only output pane
        uint pid = PidOf(hwnd);
        IntPtr p = OpenProcess(0x1F0FFF, false, pid);
        if (p == IntPtr.Zero) return false;
        try {
            Encoding encoding = SciEncoding(hwnd);
            byte[] d = encoding.GetBytes(text + "\0");
            if (encoding.GetString(d, 0, d.Length - 1) != text)
                throw new InvalidOperationException("Text cannot be represented in the editor's code page; use a UTF-8 script file.");
            IntPtr r = VirtualAllocEx(p, IntPtr.Zero, (UIntPtr)d.Length, 0x3000, 4);
            if (r == IntPtr.Zero) return false;
            try {
                UIntPtr w;
                if (!WriteProcessMemory(p, r, d, (UIntPtr)d.Length, out w)) return false;
                SendMessage(hwnd, 2181, IntPtr.Zero, r); // SCI_SETTEXT
                return true;
            } finally { VirtualFreeEx(p, r, UIntPtr.Zero, 0x8000); }
        } finally { CloseHandle(p); }
    }

    public static string GetText(IntPtr hwnd) {
        uint pid = PidOf(hwnd);
        IntPtr p = OpenProcess(0x1F0FFF, false, pid);
        if (p == IntPtr.Zero) return null;
        try {
            long len = SciValue(hwnd, 2006); // SCI_GETLENGTH
            if (len < 0) len = 0;
            if (len > 2000000) len = 2000000;
            IntPtr r = VirtualAllocEx(p, IntPtr.Zero, (UIntPtr)(len + 2), 0x3000, 4);
            if (r == IntPtr.Zero) return null;
            try {
                IntPtr tmp;
                SendMessageTimeout(hwnd, 2182, (IntPtr)(len + 1), r, 0, 5000, out tmp); // SCI_GETTEXT
                byte[] b = new byte[len + 1];
                UIntPtr rd;
                if (!ReadProcessMemory(p, r, b, (UIntPtr)(len + 1), out rd)) return null;
                int n = 0; while (n < b.Length && b[n] != 0) n++;
                return SciEncoding(hwnd).GetString(b, 0, n);
            } finally { VirtualFreeEx(p, r, UIntPtr.Zero, 0x8000); }
        } finally { CloseHandle(p); }
    }

    public static bool Capture(IntPtr hwnd, string path) {
        RECT r;
        if (hwnd != IntPtr.Zero) {
            if (!GetWindowRect(hwnd, out r)) return false;
        } else {
            r.Left = 0; r.Top = 0; r.Right = GetSystemMetrics(0); r.Bottom = GetSystemMetrics(1);
        }
        int w = r.Right - r.Left, h = r.Bottom - r.Top;
        if (w <= 0 || h <= 0) return false;
        IntPtr src = GetDC(IntPtr.Zero);
        IntPtr mem = CreateCompatibleDC(src);
        IntPtr bmp = CreateCompatibleBitmap(src, w, h);
        IntPtr old = SelectObject(mem, bmp);
        try {
            BitBlt(mem, 0, 0, w, h, src, r.Left, r.Top, 0x00CC0020 | 0x40000000);
            using (Bitmap b = Bitmap.FromHbitmap(bmp)) { b.Save(path, ImageFormat.Png); }
            return true;
        } finally {
            SelectObject(mem, old);
            DeleteObject(bmp);
            DeleteDC(mem);
            ReleaseDC(IntPtr.Zero, src);
        }
    }
}
'@

# UIA is used by uia.find / uia.invoke. Load once; the worker still runs if the
# assemblies are unavailable (those two actions then fail cleanly).
try {
    Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
    Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop
} catch {
    Write-Audit ('WARN: UIAutomation assemblies unavailable: ' + $_.Exception.Message)
}

# ---------------------------------------------------------------- mcp helper
function Test-CompanionPort([int]$Port) {
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $ar = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        $ok = $ar.AsyncWaitHandle.WaitOne(900)
        $connected = $ok -and $client.Connected
        $client.Close()
        return $connected
    } catch { return $false }
}

function Start-CompanionMcp([int]$Port) {
    $exe = Join-Path $env:USERPROFILE '.local\bin\windows-mcp.exe'
    if (-not (Test-Path $exe)) { throw "windows-mcp not found at $exe" }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = 'serve --transport streamable-http --host 127.0.0.1 --port ' + $Port + ' --exclude-tools App,PowerShell,FileSystem'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.EnvironmentVariables['ANONYMIZED_TELEMETRY'] = 'false'
    $psi.EnvironmentVariables['WINDOWS_MCP_DISABLE_FLASH'] = '1'
    $psi.EnvironmentVariables['WINDOWS_MCP_SCREENSHOT_SCALE'] = '0.75'
    $proc = [System.Diagnostics.Process]::Start($psi)
    Write-Audit ("=== mcp start pid=" + $proc.Id + " port=" + $Port)
    return $proc
}

# ---------------------------------------------------------------- validation
$Allowed = @{
    'ping'         = @()
    'window.list'  = @('processName', 'titleContains', 'className', 'visibleOnly', 'maxItems')
    'window.find'  = @('processName', 'titleContains', 'className', 'visibleOnly')
    'window.rect'  = @('hwnd')
    'child.list'   = @('hwnd', 'className', 'visibleOnly', 'maxItems')
    'text.set'     = @('hwnd', 'path', 'text')
    'text.get'     = @('hwnd', 'outFile')
    'click'        = @('x', 'y', 'button', 'hwnd', 'rel')
    'key'          = @('keys')
    'type'         = @('text')
    'focus'        = @('hwnd')
    'proc.start'   = @('exe', 'args', 'workdir')
    'proc.kill'    = @('name')
    'proc.list'    = @('processName', 'maxItems')
    'service.list' = @('filter')
    'service.start' = @('name')
    'service.stop' = @('name')
    'uia.find'     = @('hwnd', 'name', 'controlType', 'maxItems')
    'uia.invoke'   = @('hwnd', 'name', 'controlType')
    'exec'         = @('exe', 'args', 'timeoutSec', 'workdir')
    'mcp.start'    = @('port')
    'file.read'    = @('path')
    'file.write'   = @('path', 'text')
    'office.convert' = @('path', 'to', 'outFile', 'timeoutSec')
    'screenshot'   = @('hwnd', 'outFile')
    'wait'         = @('ms')
    'reload'       = @()
    'stop'         = @()
}

$ExeAllow  = @(
    'C:\Program Files\FlexSim 2023\program\flexsim.exe',
    "$env:USERPROFILE\.local\bin\windows-mcp.exe"
)
$KillAllow = @('flexsim', 'FlexSim')

# Programs the worker may launch with captured stdout/stderr. Keep this tight:
# an entry here is effectively "this executable may run elevated on request".
$ExecAllow = @(
    "$env:USERPROFILE\.local\bin\uv.exe",
    "$env:USERPROFILE\.local\bin\uvx.exe",
    "$env:USERPROFILE\.local\bin\windows-mcp.exe",
    "$env:USERPROFILE\.local\bin\curl.exe",
    "$env:LOCALAPPDATA\Programs\Python\Python313\python.exe",
    'C:\Windows\System32\schtasks.exe',
    'C:\Windows\System32\sc.exe',
    'C:\Windows\System32\winget.exe',
    'C:\Program Files\LibreOffice\program\soffice.exe'
) | ForEach-Object { $_ }

# Services the worker may start/stop.
$ServiceAllow = @(
    'FlexSim 2023 Server',
    'FlexNet Licensing Service',
    'FlexNet Licensing Service 64'
)

function Fail([string]$m) { throw $m }

function Resolve-UnderWs([string]$p) {
    if ([string]::IsNullOrWhiteSpace($p)) { Fail 'path is empty' }
    $full = [System.IO.Path]::GetFullPath($p)
    $root = [System.IO.Path]::GetFullPath($Ws).TrimEnd('\') + '\'
    if (-not $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
        Fail "path outside workspace: $full"
    }
    return $full
}

function ToHwnd($v) {
    if ($null -eq $v) { Fail 'hwnd required' }
    $n = [int64]$v
    if ($n -le 0) { Fail 'invalid hwnd' }
    return [IntPtr]$n
}

$VkMap = @{
    'ctrl' = 0x11; 'control' = 0x11; 'shift' = 0x10; 'alt' = 0x12; 'win' = 0x5B
    'enter' = 0x0D; 'return' = 0x0D; 'esc' = 0x1B; 'escape' = 0x1B
    'tab' = 0x09; 'space' = 0x20; 'backspace' = 0x08; 'delete' = 0x2E
    'up' = 0x26; 'down' = 0x28; 'left' = 0x25; 'right' = 0x27
    'home' = 0x24; 'end' = 0x23; 'pageup' = 0x21; 'pagedown' = 0x22
    '`' = 0xC0; 'backtick' = 0xC0
    'f1' = 0x70; 'f2' = 0x71; 'f3' = 0x72; 'f4' = 0x73; 'f5' = 0x74; 'f6' = 0x75
    'f7' = 0x76; 'f8' = 0x77; 'f9' = 0x78; 'f10' = 0x79; 'f11' = 0x7A; 'f12' = 0x7B
}

function KeyToVk([string]$k) {
    $lk = $k.ToLowerInvariant()
    if ($VkMap.ContainsKey($lk)) { return [byte]$VkMap[$lk] }
    if ($lk.Length -eq 1) {
        $ch = [char]$lk
        if ($ch -match '[a-z]') { return [byte]([int][char]::ToUpperInvariant($ch)) }
        if ($ch -match '[0-9]') { return [byte]([int][char]$ch) }
        switch ($ch) {
            '-' { return [byte]0xBD } '=' { return [byte]0xBB } '[' { return [byte]0xDB }
            ']' { return [byte]0xDD } '\' { return [byte]0xDC } ';' { return [byte]0xBA }
            "'" { return [byte]0xDE } ',' { return [byte]0xBC } '.' { return [byte]0xBE }
            '/' { return [byte]0xBF }
        }
    }
    Fail "unsupported key: $k"
}

# ---------------------------------------------------------------- actions
function Invoke-Action([string]$action, $p) {
    switch ($action) {
        'ping' {
            $wr = $false
            $probe = Join-Path 'C:\Program Files\FlexSim 2023\program' ('.dsh_probe_' + [guid]::NewGuid().ToString('N') + '.tmp')
            try { [IO.File]::WriteAllText($probe, 'x'); $wr = $true; Remove-Item $probe -Force -ErrorAction SilentlyContinue } catch { }
            return [ordered]@{
                pid = $PID; user = "$env:USERDOMAIN\$env:USERNAME"
                integrity = [Cmp]::Integrity(); elevated = [Cmp]::IsElevated()
                sessionId = (Get-Process -Id $PID).SessionId
                powershell = $PSVersionTable.PSVersion.ToString()
                programFilesWritable = $wr
                workspace = $Ws; startedAt = $script:StartedAt
                actions = @($Allowed.Keys | Sort-Object)
            }
        }
        'window.list' {
            $visibleOnly = $true; if ($p.ContainsKey('visibleOnly') -and $p['visibleOnly'] -eq $false) { $visibleOnly = $false }
            $max = 100; if ($p.ContainsKey('maxItems')) { $max = [Math]::Min(500, [Math]::Max(1, [int]$p['maxItems'])) }
            $out = @()
            foreach ($h in [Cmp]::TopWindows()) {
                if ($h -eq [IntPtr]::Zero) { continue }
                $vis = [Cmp]::IsWindowVisible($h)
                if ($visibleOnly -and -not $vis) { continue }
                $cls = [Cmp]::ClassOf($h)
                if ($p.ContainsKey('className') -and $cls -ne $p['className']) { continue }
                $ttl = [Cmp]::TitleOf($h)
                if ($p.ContainsKey('titleContains') -and $p['titleContains'] -and $ttl -notlike ('*' + $p['titleContains'] + '*')) { continue }
                $procName = ''
                try { $procName = (Get-Process -Id ([Cmp]::PidOf($h)) -ErrorAction Stop).ProcessName } catch { }
                if ($p.ContainsKey('processName') -and $p['processName'] -and $procName -notlike $p['processName']) { continue }
                $r = [Cmp]::Rect($h)
                if (-not $r) { continue }
                $out += [ordered]@{
                    hwnd = $h.ToInt64(); className = $cls; title = $ttl; pid = [Cmp]::PidOf($h)
                    process = $procName; visible = $vis; foreground = ($h -eq [Cmp]::GetForegroundWindow())
                    rect = @{ left = $r[0]; top = $r[1]; right = $r[2]; bottom = $r[3] }
                    area = (($r[2] - $r[0]) * ($r[3] - $r[1]))
                }
                if ($out.Count -ge $max) { break }
            }
            return [ordered]@{ count = $out.Count; windows = $out }
        }
        'window.find' {
            $best = $null
            foreach ($h in [Cmp]::TopWindows()) {
                $vis = [Cmp]::IsWindowVisible($h)
                if (-not $vis) { continue }
                $cls = [Cmp]::ClassOf($h)
                if ($p.ContainsKey('className') -and $p['className'] -and $cls -ne $p['className']) { continue }
                if ($cls -eq 'Progman' -or $cls -eq 'WorkerW') { continue }
                $ttl = [Cmp]::TitleOf($h)
                if ($p.ContainsKey('titleContains') -and $p['titleContains'] -and $ttl -notlike ('*' + $p['titleContains'] + '*')) { continue }
                $procName = ''
                try { $procName = (Get-Process -Id ([Cmp]::PidOf($h)) -ErrorAction Stop).ProcessName } catch { }
                if ($p.ContainsKey('processName') -and $p['processName'] -and $procName -notlike $p['processName']) { continue }
                $r = [Cmp]::Rect($h)
                if (-not $r) { continue }
                $area = ($r[2] - $r[0]) * ($r[3] - $r[1])
                if ($area -lt 4000) { continue }
                if (-not $best -or $area -gt $best.area) {
                    $best = [ordered]@{
                        hwnd = $h.ToInt64(); className = $cls; title = $ttl; pid = [Cmp]::PidOf($h)
                        process = $procName; rect = @{ left = $r[0]; top = $r[1]; right = $r[2]; bottom = $r[3] }; area = $area
                    }
                }
            }
            if (-not $best) { return [ordered]@{ found = $false } }
            $best['found'] = $true
            return $best
        }
        'window.rect' {
            $h = ToHwnd $p['hwnd']
            if (-not [Cmp]::IsWindow($h)) { Fail 'not a window' }
            $r = [Cmp]::Rect($h)
            return [ordered]@{
                hwnd = $h.ToInt64(); className = [Cmp]::ClassOf($h); title = [Cmp]::TitleOf($h)
                visible = [Cmp]::IsWindowVisible($h)
                rect = @{ left = $r[0]; top = $r[1]; right = $r[2]; bottom = $r[3] }
            }
        }
        'child.list' {
            $h = ToHwnd $p['hwnd']
            $visibleOnly = $true; if ($p.ContainsKey('visibleOnly') -and $p['visibleOnly'] -eq $false) { $visibleOnly = $false }
            $max = 200; if ($p.ContainsKey('maxItems')) { $max = [Math]::Min(1000, [Math]::Max(1, [int]$p['maxItems'])) }
            $out = @()
            foreach ($c in [Cmp]::Children($h)) {
                $vis = [Cmp]::IsWindowVisible($c)
                if ($visibleOnly -and -not $vis) { continue }
                $cls = [Cmp]::ClassOf($c)
                if ($p.ContainsKey('className') -and $p['className'] -and $cls -notlike $p['className']) { continue }
                $r = [Cmp]::Rect($c)
                if (-not $r) { continue }
                $entry = [ordered]@{
                    hwnd = $c.ToInt64(); className = $cls; visible = $vis
                    rect = @{ left = $r[0]; top = $r[1]; right = $r[2]; bottom = $r[3] }
                    area = (($r[2] - $r[0]) * ($r[3] - $r[1]))
                }
                if ($cls -eq 'Scintilla') {
                    try {
                        $entry['readOnly'] = ([Cmp]::SciValue($c, 2140) -ne 0)
                        $entry['lexer'] = [Cmp]::SciValue($c, 4002)
                        $entry['codePage'] = [Cmp]::SciValue($c, 2137)
                        $entry['ancestorTitles'] = [Cmp]::AncestorTitles($c)
                    } catch { $entry['metadataError'] = $_.Exception.Message }
                }
                $out += $entry
                if ($out.Count -ge $max) { break }
            }
            return [ordered]@{ count = $out.Count; children = $out }
        }
        'text.set' {
            $h = ToHwnd $p['hwnd']
            $text = $null
            if ($p.ContainsKey('path') -and $p['path']) {
                $f = Resolve-UnderWs ([string]$p['path'])
                if (-not (Test-Path $f -PathType Leaf)) { Fail "file not found: $f" }
                $text = [IO.File]::ReadAllText($f, [Text.Encoding]::UTF8)
            } elseif ($p.ContainsKey('text')) {
                $text = [string]$p['text']
            } else { Fail 'path or text required' }
            if ($text.Length -gt 2000000) { Fail 'text too large (2MB limit)' }
            $ok = [Cmp]::SetText($h, $text)
            Start-Sleep -Milliseconds 250
            $back = [Cmp]::GetText($h)
            return [ordered]@{
                ok = $ok; chars = $text.Length
                verifiedChars = if ($back) { $back.Length } else { -1 }
                head = if ($back) { $back.Substring(0, [Math]::Min(120, $back.Length)) } else { '' }
            }
        }
        'text.get' {
            $h = ToHwnd $p['hwnd']
            $t = [Cmp]::GetText($h)
            if ($null -eq $t) { Fail 'GetText failed (access denied or not a Scintilla window)' }
            if ($p.ContainsKey('outFile') -and $p['outFile']) {
                $f = Resolve-UnderWs ([string]$p['outFile'])
                [IO.File]::WriteAllText($f, $t, (New-Object System.Text.UTF8Encoding($false)))
                return [ordered]@{ chars = $t.Length; path = $f; preview = $t.Substring(0, [Math]::Min(200, $t.Length)) }
            }
            return [ordered]@{ chars = $t.Length; text = $t }
        }
        'click' {
            $x = [int]$p['x']; $y = [int]$p['y']
            $rel = ($p.ContainsKey('rel') -and $p['rel'] -eq $true)
            if ($rel) {
                if (-not ($p.ContainsKey('hwnd') -and $p['hwnd'])) { Fail 'rel click needs hwnd' }
                $h = ToHwnd $p['hwnd']
                $r = [Cmp]::Rect($h)
                if (-not $r) { Fail 'cannot read window rect' }
                $x = $r[0] + $x; $y = $r[1] + $y
            }
            if ($x -lt -20000 -or $x -gt 20000 -or $y -lt -20000 -or $y -gt 20000) { Fail 'coordinates out of range' }
            $btn = 'left'; if ($p.ContainsKey('button') -and $p['button']) { $btn = [string]$p['button'] }
            if ($btn -notin @('left', 'right')) { Fail 'button must be left|right' }
            [Cmp]::Click($x, $y, $btn)
            Start-Sleep -Milliseconds 120
            return [ordered]@{ x = $x; y = $y; button = $btn; relative = $rel; foreground = [Cmp]::GetForegroundWindow().ToInt64() }
        }
        'key' {
            $keys = @($p['keys'])
            if ($keys.Count -lt 1 -or $keys.Count -gt 5) { Fail 'keys must contain 1..5 entries' }
            $mods = New-Object System.Collections.Generic.List[byte]
            for ($i = 0; $i -lt $keys.Count - 1; $i++) {
                $lk = ([string]$keys[$i]).ToLowerInvariant()
                if (-not $VkMap.ContainsKey($lk)) { Fail "unsupported modifier: $lk" }
                $mods.Add([byte]$VkMap[$lk])
            }
            $vk = KeyToVk ([string]$keys[$keys.Count - 1])
            [Cmp]::Chord($mods.ToArray(), $vk)
            Start-Sleep -Milliseconds 200
            return [ordered]@{ keys = $keys; vk = $vk }
        }
        'type' {
            if (-not $p.ContainsKey('text')) { Fail 'text required' }
            $t = [string]$p['text']
            if ($t.Length -gt 20000) { Fail 'text too large (20k limit)' }
            [Cmp]::TypeText($t)
            return [ordered]@{ chars = $t.Length }
        }
        'focus' {
            $h = ToHwnd $p['hwnd']
            $detail = ''
            $ok = [Cmp]::FocusEx($h, [ref]$detail)
            return [ordered]@{ ok = $ok; foreground = [Cmp]::GetForegroundWindow().ToInt64(); detail = $detail }
        }
        'proc.start' {
            $exe = [string]$p['exe']
            $full = [IO.Path]::GetFullPath($exe)
            $allowed = $false
            foreach ($a in $ExeAllow) { if ($full -eq $a) { $allowed = $true } }
            if (-not $allowed) { Fail "exe not in allowlist: $full" }
            $args = @()
            if ($p.ContainsKey('args') -and $p['args']) { $args = @($p['args'] | ForEach-Object { [string]$_ }) }
            $wd = $null
            if ($p.ContainsKey('workdir') -and $p['workdir']) { $wd = Resolve-UnderWs ([string]$p['workdir']) }
            $sp = @{ FilePath = $full; PassThru = $true }
            if ($args.Count -gt 0) { $sp['ArgumentList'] = $args }
            if ($wd) { $sp['WorkingDirectory'] = $wd }
            $proc = Start-Process @sp
            Start-Sleep -Milliseconds 400
            return [ordered]@{ pid = $proc.Id; exe = $full; args = $args }
        }
        'proc.kill' {
            $name = ([string]$p['name']).ToLowerInvariant()
            if ($KillAllow -notcontains ([string]$p['name']) -and $KillAllow -notcontains $name) { Fail "process not in allowlist: $name" }
            $procs = @(Get-Process -Name $name -ErrorAction SilentlyContinue)
            $ids = @($procs | ForEach-Object { $_.Id })
            foreach ($pr in $procs) { try { $pr | Stop-Process -Force -ErrorAction Stop } catch { } }
            return [ordered]@{ killed = $ids.Count; pids = $ids }
        }
        'proc.list' {
            $max = 100; if ($p.ContainsKey('maxItems')) { $max = [Math]::Min(500, [Math]::Max(1, [int]$p['maxItems'])) }
            $filter = ''
            if ($p.ContainsKey('processName') -and $p['processName']) { $filter = [string]$p['processName'] }
            $procs = @(Get-Process -ErrorAction SilentlyContinue)
            if ($filter) { $procs = @($procs | Where-Object { $_.ProcessName -like $filter }) }
            $out = @()
            foreach ($pr in ($procs | Sort-Object -Property Id)) {
                $path = ''
                try { $path = $pr.Path } catch { }
                $started = ''
                try { $started = $pr.StartTime.ToString('s') } catch { }
                $out += [ordered]@{
                    pid = $pr.Id; name = $pr.ProcessName; path = $path
                    sessionId = $pr.SessionId
                    started = $started
                    wsMB = [Math]::Round($pr.WorkingSet64 / 1MB, 1)
                }
                if ($out.Count -ge $max) { break }
            }
            return [ordered]@{ count = $out.Count; processes = $out }
        }
        'service.list' {
            $filter = ''
            if ($p.ContainsKey('filter') -and $p['filter']) { $filter = [string]$p['filter'] }
            $svc = @(Get-Service -ErrorAction SilentlyContinue)
            if ($filter) { $svc = @($svc | Where-Object { $_.Name -like "*$filter*" -or $_.DisplayName -like "*$filter*" }) }
            $out = @()
            foreach ($s in $svc) {
                $out += [ordered]@{
                    name = $s.Name; displayName = $s.DisplayName
                    status = [string]$s.Status; startType = [string]$s.StartType
                    canStop = [bool]$s.CanStop
                }
                if ($out.Count -ge 200) { break }
            }
            return [ordered]@{ count = $out.Count; services = $out }
        }
        'service.start' {
            $n = [string]$p['name']
            if ($ServiceAllow -notcontains $n) { Fail "service not in allowlist: $n" }
            Start-Service -Name $n -ErrorAction Stop
            Start-Sleep -Milliseconds 400
            $s = Get-Service -Name $n
            return [ordered]@{ name = $n; status = [string]$s.Status }
        }
        'service.stop' {
            $n = [string]$p['name']
            if ($ServiceAllow -notcontains $n) { Fail "service not in allowlist: $n" }
            Stop-Service -Name $n -Force -ErrorAction Stop
            Start-Sleep -Milliseconds 400
            $s = Get-Service -Name $n
            return [ordered]@{ name = $n; status = [string]$s.Status }
        }
        'uia.find' {
            $h = ToHwnd $p['hwnd']
            $root = [System.Windows.Automation.AutomationElement]::FromHandle($h)
            if (-not $root) { Fail 'AutomationElement.FromHandle failed' }
            $conds = New-Object System.Collections.Generic.List[System.Windows.Automation.Condition]
            if ($p.ContainsKey('name') -and $p['name']) {
                $conds.Add((New-Object System.Windows.Automation.PropertyCondition(
                    [System.Windows.Automation.AutomationElement]::NameProperty, [string]$p['name'])))
            }
            if ($p.ContainsKey('controlType') -and $p['controlType']) {
                $ctName = [string]$p['controlType']
                $ct = [System.Windows.Automation.ControlType]::$ctName
                if (-not $ct) { Fail "unknown controlType: $ctName" }
                $conds.Add((New-Object System.Windows.Automation.PropertyCondition(
                    [System.Windows.Automation.AutomationElement]::ControlTypeProperty, $ct)))
            }
            if ($conds.Count -eq 0) { $cond = [System.Windows.Automation.Condition]::TrueCondition }
            elseif ($conds.Count -eq 1) { $cond = $conds[0] }
            else { $cond = New-Object System.Windows.Automation.AndCondition(,$conds.ToArray()) }

            $max = 50; if ($p.ContainsKey('maxItems')) { $max = [Math]::Min(300, [Math]::Max(1, [int]$p['maxItems'])) }
            $found = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)
            $out = @()
            foreach ($el in $found) {
                if ($out.Count -ge $max) { break }
                $cur = $el.Current
                $r = $cur.BoundingRectangle
                $out += [ordered]@{
                    name = $cur.Name
                    controlType = ($cur.ControlType.ProgrammaticName -replace 'ControlType\.', '')
                    automationId = $cur.AutomationId; className = $cur.ClassName
                    enabled = $cur.IsEnabled; offscreen = $cur.IsOffscreen
                    rect = @{ left = [int]$r.Left; top = [int]$r.Top; right = [int]$r.Right; bottom = [int]$r.Bottom }
                }
            }
            return [ordered]@{ count = $out.Count; elements = $out }
        }
        'uia.invoke' {
            $h = ToHwnd $p['hwnd']
            $root = [System.Windows.Automation.AutomationElement]::FromHandle($h)
            if (-not $root) { Fail 'AutomationElement.FromHandle failed' }
            $cond = [System.Windows.Automation.Condition]::TrueCondition
            if ($p.ContainsKey('name') -and $p['name']) {
                $cond = New-Object System.Windows.Automation.PropertyCondition(
                    [System.Windows.Automation.AutomationElement]::NameProperty, [string]$p['name'])
            }
            if ($p.ContainsKey('controlType') -and $p['controlType']) {
                $ct = [System.Windows.Automation.ControlType]::([string]$p['controlType'])
                $c2 = New-Object System.Windows.Automation.PropertyCondition(
                    [System.Windows.Automation.AutomationElement]::ControlTypeProperty, $ct)
                $cond = New-Object System.Windows.Automation.AndCondition(,$cond, $c2)
            }
            $el = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
            if (-not $el) { Fail 'element not found' }
            $used = $null
            try { $el.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke(); $used = 'Invoke' } catch {
                try { $el.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select(); $used = 'Select' } catch {
                    try { $el.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Toggle(); $used = 'Toggle' } catch {
                        Fail ('no invokable pattern; available=' + (($el.GetSupportedPatterns() | ForEach-Object { $_.ProgrammaticName }) -join ','))
                    }
                }
            }
            Start-Sleep -Milliseconds 250
            return [ordered]@{ invoked = $true; pattern = $used; name = $el.Current.Name }
        }
        'exec' {
            $exe = [IO.Path]::GetFullPath([string]$p['exe'])
            $allowed = $false
            foreach ($a in $ExecAllow) { if ($a -and $a.Equals($exe, [StringComparison]::OrdinalIgnoreCase)) { $allowed = $true } }
            if (-not $allowed) { Fail "exe not in exec allowlist: $exe" }
            $argList = @()
            if ($p.ContainsKey('args') -and $p['args']) { $argList = @($p['args'] | ForEach-Object { [string]$_ }) }
            $timeout = 600; if ($p.ContainsKey('timeoutSec')) { $timeout = [Math]::Min(3600, [Math]::Max(5, [int]$p['timeoutSec'])) }
            $wd = $null
            if ($p.ContainsKey('workdir') -and $p['workdir']) { $wd = Resolve-UnderWs ([string]$p['workdir']) }

            $logDir = Join-Path $Root 'logs'
            if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
            $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
            $outF = Join-Path $logDir "exec-$stamp.out.log"
            $errF = Join-Path $logDir "exec-$stamp.err.log"

            # System.Diagnostics.Process (not Start-Process): its ExitCode is
            # reliable. Windows PowerShell 5.1 / .NET Framework has no
            # ArgumentList, so quoting is done by hand.
            $quoted = @()
            foreach ($a in $argList) {
                if ($a -match '[\s"]') { $quoted += ('"' + ($a -replace '"', '\"') + '"') } else { $quoted += $a }
            }
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $exe
            $psi.Arguments = ($quoted -join ' ')
            $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.CreateNoWindow = $true
            if ($wd) { $psi.WorkingDirectory = $wd }

            $proc = [System.Diagnostics.Process]::Start($psi)
            $oTask = $proc.StandardOutput.ReadToEndAsync()
            $eTask = $proc.StandardError.ReadToEndAsync()
            $finished = $proc.WaitForExit($timeout * 1000)
            if (-not $finished) { try { $proc.Kill() } catch { } }
            $stdout = ''
            $stderr = ''
            try { if ($oTask.Wait(5000)) { $stdout = $oTask.Result } } catch { }
            try { if ($eTask.Wait(5000)) { $stderr = $eTask.Result } } catch { }
            [IO.File]::WriteAllText($outF, $stdout, (New-Object System.Text.UTF8Encoding($false)))
            [IO.File]::WriteAllText($errF, $stderr, (New-Object System.Text.UTF8Encoding($false)))
            $code = -1
            try { if ($proc.HasExited) { $code = $proc.ExitCode } } catch { }
            return [ordered]@{
                exitCode = $code; timedOut = (-not $finished)
                stdoutFile = $outF; stderrFile = $errF
                stdoutHead = $stdout.Substring(0, [Math]::Min(1500, $stdout.Length))
                stderrHead = $stderr.Substring(0, [Math]::Min(1500, $stderr.Length))
                args = $argList
            }
        }
        'file.read' {
            # Narrow escape hatch for config files outside the workspace (the DSH
            # profile lives in %USERPROFILE%\.dsh, which the agent sandbox cannot
            # write). Only the profile tree is reachable.
            if (-not $p.ContainsKey('path') -or -not $p['path']) { Fail 'path required' }
            $full = [IO.Path]::GetFullPath([string]$p['path'])
            $root = [IO.Path]::GetFullPath((Join-Path $env:USERPROFILE '.dsh\profiles')).TrimEnd('\') + '\'
            if (-not $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { Fail "path outside profile root: $full" }
            if (-not (Test-Path $full -PathType Leaf)) { Fail "file not found: $full" }
            $t = [IO.File]::ReadAllText($full, [Text.Encoding]::UTF8)
            return [ordered]@{ path = $full; chars = $t.Length; text = $t }
        }
        'file.write' {
            if (-not $p.ContainsKey('path') -or -not $p['path']) { Fail 'path required' }
            if (-not $p.ContainsKey('text')) { Fail 'text required' }
            $full = [IO.Path]::GetFullPath([string]$p['path'])
            $root = [IO.Path]::GetFullPath((Join-Path $env:USERPROFILE '.dsh\profiles')).TrimEnd('\') + '\'
            if (-not $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { Fail "path outside profile root: $full" }
            $t = [string]$p['text']
            if ($t.Length -gt 1048576) { Fail 'text too large (1MB)' }
            if (Test-Path $full) {
                $bak = "$full.bak-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
                Copy-Item $full $bak -Force -ErrorAction SilentlyContinue
            }
            $tmp = "$full.tmp"
            [IO.File]::WriteAllText($tmp, $t, (New-Object System.Text.UTF8Encoding($false)))
            Move-Item $tmp $full -Force
            return [ordered]@{ path = $full; chars = $t.Length }
        }
        'office.convert' {
            # Word COM runs in a child process with a hard timeout: a hung Word
            # is killed with its parent and can never freeze the request loop.
            $in = Resolve-UnderWs ([string]$p['path'])
            if (-not (Test-Path $in -PathType Leaf)) { Fail "file not found: $in" }
            $to = 'docx'
            if ($p.ContainsKey('to') -and $p['to']) { $to = ([string]$p['to']).ToLowerInvariant() }
            if ($to -notin @('docx', 'txt', 'pdf')) { Fail 'to must be docx|txt|pdf' }
            $out = $null
            if ($p.ContainsKey('outFile') -and $p['outFile']) {
                $out = Resolve-UnderWs ([string]$p['outFile'])
            } else {
                $base = [IO.Path]::GetFileNameWithoutExtension($in)
                $out = Join-Path (Split-Path $in -Parent) ($base + '.' + $to)
            }
            Remove-Item $out -Force -ErrorAction SilentlyContinue

            $helper = Join-Path $Root 'word-convert.ps1'
            if (-not (Test-Path $helper)) { Fail 'word-convert.ps1 missing' }

            $timeoutSec = 90
            if ($p.ContainsKey('timeoutSec')) { $timeoutSec = [Math]::Min(600, [Math]::Max(10, [int]$p['timeoutSec'])) }

            $started = Get-Date
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = 'powershell.exe'
            $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $helper +
                             '" -In "' + $in + '" -Out "' + $out + '" -Format ' + $to
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true

            $child = [System.Diagnostics.Process]::Start($psi)
            if (-not $child.WaitForExit($timeoutSec * 1000)) {
                try { $child.Kill() } catch { }
                try {
                    Get-Process WINWORD -ErrorAction SilentlyContinue |
                        Where-Object { $_.StartTime -ge $started } |
                        Stop-Process -Force -ErrorAction SilentlyContinue
                } catch { }
                Fail ("conversion timed out after ${timeoutSec}s; Word was terminated")
            }

            $code = -1
            try { $code = $child.ExitCode } catch { }
            if (-not (Test-Path $out)) {
                $err = ''
                try { $err = (Get-Content (Join-Path $Root 'logs\word-convert.log') -Tail 5) -join ' | ' } catch { }
                Fail ("conversion failed (exit=$code); log=$err")
            }
            return [ordered]@{
                ok = $true; to = $to; input = $in; output = $out
                sizeBytes = (Get-Item $out).Length
                ms = [int]((Get-Date) - $started).TotalMilliseconds
            }
        }        'mcp.start' {
            # Restart the elevated Windows-MCP HTTP server (curated tool list,
            # telemetry off). Any existing windows-mcp instance is stopped first
            # because desktop control is exclusive.
            $port = 8000
            if ($p.ContainsKey('port')) { $port = [int]$p['port'] }

            try {
                Get-CimInstance Win32_Process -Filter "Name='python.exe' OR Name='windows-mcp.exe'" -ErrorAction SilentlyContinue |
                    Where-Object { ($_.Name -eq 'windows-mcp.exe') -or ($_.CommandLine -and $_.CommandLine -match 'windows.mcp') } |
                    ForEach-Object {
                        Write-Audit ("mcp.start: stopping pid=" + $_.ProcessId)
                        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
                    }
            } catch { }
            Start-Sleep -Milliseconds 1200

            $proc = Start-CompanionMcp $port
            Start-Sleep -Milliseconds 1500
            return [ordered]@{ pid = $proc.Id; port = $port }
        }        'screenshot' {
            if (-not $p.ContainsKey('outFile') -or -not $p['outFile']) { Fail 'outFile required' }
            $f = Resolve-UnderWs ([string]$p['outFile'])
            $h = [IntPtr]::Zero
            if ($p.ContainsKey('hwnd') -and $p['hwnd']) { $h = ToHwnd $p['hwnd'] }
            $ok = [Cmp]::Capture($h, $f)
            return [ordered]@{ ok = $ok; path = $f }
        }
        'wait' {
            $ms = 500; if ($p.ContainsKey('ms')) { $ms = [Math]::Min(30000, [Math]::Max(0, [int]$p['ms'])) }
            Start-Sleep -Milliseconds $ms
            return [ordered]@{ waitedMs = $ms }
        }
        'stop' {
            # Ask the supervisor to stop as well, otherwise it would restart us.
            Set-Content -Path $StopFile -Value 'stop' -Encoding ASCII -ErrorAction SilentlyContinue
            $script:StopRequested = $true
            return [ordered]@{ stopping = $true }
        }
        'reload' {
            # Exit with code 3: the supervisor restarts the worker with the code
            # on disk. No UAC prompt, no self-spawn race.
            $script:StopRequested = $true
            $script:ExitCode = 3
            return [ordered]@{ reloading = $true; script = $PSCommandPath }
        }
        default { Fail "unknown action: $action" }
    }
}

# ---------------------------------------------------------------- request loop
function Handle-Request([System.IO.FileInfo]$fi) {
    $req = $null
    $id = $null
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $raw = [IO.File]::ReadAllText($fi.FullName, [Text.Encoding]::UTF8)
        $req = $raw | ConvertFrom-Json
        $id = [string]$req.id
        if ($id -notmatch '^[0-9a-fA-F\-]{36}$') { throw 'bad request id' }
        $action = [string]$req.action
        if (-not $Allowed.ContainsKey($action)) { throw "action not allowed: $action" }
        $params = @{}
        if ($req.PSObject.Properties.Name -contains 'params' -and $req.params) {
            foreach ($prop in $req.params.PSObject.Properties) {
                if ($Allowed[$action] -notcontains $prop.Name) { throw "param not allowed for ${action}: $($prop.Name)" }
                $params[$prop.Name] = $prop.Value
            }
        }
        $script:LastAction = $action
        $data = Invoke-Action $action $params
        $res = [ordered]@{ id = $id; ok = $true; action = $action; elapsedMs = [int]$sw.ElapsedMilliseconds; data = $data; error = $null }
        $script:LastError = ''
    } catch {
        $script:LastError = $_.Exception.Message
        $res = [ordered]@{ id = $id; ok = $false; action = ([string]$req.action); elapsedMs = [int]$sw.ElapsedMilliseconds; data = $null; error = $_.Exception.Message }
    } finally {
        $sw.Stop()
    }
    try {
        if ($id -and $id -match '^[0-9a-fA-F\-]{36}$') {
            $out = Join-Path $Outbox ("res-$id.json")
            $tmp = "$out.tmp"
            [IO.File]::WriteAllText($tmp, ($res | ConvertTo-Json -Compress -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
            Move-Item $tmp $out -Force
        }
        $dst = Join-Path $Done ($fi.Name)
        try { Move-Item $fi.FullName $dst -Force } catch { Remove-Item $fi.FullName -Force -ErrorAction SilentlyContinue }
    } catch { }
    Write-Audit ("id=$id action=$($res.action) ok=$($res.ok) ms=$($res.elapsedMs) err=$($res.error)")
}

Write-Audit "=== worker start pid=$PID integrity=$([Cmp]::Integrity()) user=$env:USERNAME ws=$Ws"

# The bridge in DSH points at 127.0.0.1:8000; make sure the elevated server is
# up after a reboot (the supervisor/worker start before DSH).
try {
    if (-not (Test-CompanionPort 8000)) { Start-CompanionMcp 8000 | Out-Null }
} catch { Write-Audit ('=== mcp startup failed: ' + $_.Exception.Message) }

$mutex = New-Object System.Threading.Mutex($false, 'Local\DSH_ElevCompanion')
# 10s instead of 0: a previous instance may still be unwinding after a reload.
$haveMutex = $false
try { $haveMutex = $mutex.WaitOne(10000) } catch [System.Threading.AbandonedMutexException] { $haveMutex = $true }
if (-not $haveMutex) {
    Write-Audit 'another instance is running; exiting'
    exit 0
}

$lastStatus = [DateTime]::MinValue
$script:StopRequested = $false
$script:ExitCode = 0

try {
    while ($true) {
        if (Test-Path $StopFile) { break }
        if ([DateTime]::Now - $lastStatus -gt [TimeSpan]::FromSeconds(2)) {
            Write-Status
            $lastStatus = [DateTime]::Now
            # cleanup of old results (>2h) so the spool does not grow
            try {
                Get-ChildItem $Outbox -Filter 'res-*.json' -ErrorAction SilentlyContinue |
                    Where-Object { $_.LastWriteTime -lt (Get-Date).AddHours(-2) } |
                    Remove-Item -Force -ErrorAction SilentlyContinue
                Get-ChildItem $Done -Filter '*.json' -ErrorAction SilentlyContinue |
                    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-1) } |
                    Remove-Item -Force -ErrorAction SilentlyContinue
            } catch { }
        }
        $reqs = @(Get-ChildItem $Inbox -Filter 'req-*.json' -ErrorAction SilentlyContinue | Sort-Object Name)
        foreach ($f in $reqs) {
            if (Test-Path (Join-Path $Outbox ("res-" + ($f.BaseName -replace '^req-', '') + '.json'))) {
                try { Move-Item $f.FullName (Join-Path $Done $f.Name) -Force } catch { }
                continue
            }
            Handle-Request $f
            if ($script:StopRequested) { break }
        }
        if ($script:StopRequested) { break }
        Start-Sleep -Milliseconds $PollMs
    }
} finally {
    if ($script:ExitCode -eq 0) {
        try {
            $obj = [ordered]@{ pid = $PID; state = 'stopped'; at = (Get-Date).ToString('o') }
            [IO.File]::WriteAllText($Status, ($obj | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding($false)))
        } catch { }
    }
    Write-Audit "=== worker stop pid=$PID code=$($script:ExitCode)"
    try { $mutex.ReleaseMutex() } catch { }
    $mutex.Dispose()
}

exit $script:ExitCode
