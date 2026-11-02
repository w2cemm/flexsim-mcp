#!/usr/bin/env python3
"""FlexSim MCP server (stdio, stdlib only).

Any MCP client can use it:

  * DeepSeek Harness  -> profile cordis.patch.yml bridge row (see README)
  * Codex             -> ~/.codex/config.toml  [mcp_servers.flexsim]

The GUI work is delegated to the elevated companion (companion/worker.ps1) over
its file protocol, so this process can stay low-integrity: FlexSim runs as
Administrator and would otherwise be unreachable through UIPI.

Protocol: newline-delimited JSON-RPC 2.0 on stdin/stdout (MCP stdio transport).
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
import uuid
import hashlib
import shutil
import unicodedata
from pathlib import Path
from datetime import datetime, timezone
from contextlib import contextmanager
from typing import Any, Callable

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_COMPANION = os.path.abspath(os.path.join(HERE, "..", "companion"))
COMPANION = os.path.abspath(os.environ.get("FLEXSIM_COMPANION_DIR", DEFAULT_COMPANION))

FLEXSIM_EXE = os.environ.get(
    "FLEXSIM_EXE", r"C:\Program Files\FlexSim 2023\program\flexsim.exe"
)

LOG = os.environ.get("FLEXSIM_MCP_LOG", os.path.join(HERE, "flexsim-mcp.log"))


def log(msg: str) -> None:
    try:
        with open(LOG, "a", encoding="utf-8") as fh:
            fh.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {msg}\n")
    except Exception:
        pass


# --------------------------------------------------------------------- companion
def read_json_retry(path: str, attempts: int = 25, delay: float = 0.08) -> dict | None:
    """Read a result file.

    The worker writes with write-tmp + rename, but a reader can still hit a
    transient Windows sharing violation (surfaced as PermissionError); retry a
    little instead of failing the tool call.
    """
    for _ in range(attempts):
        try:
            with open(path, "r", encoding="utf-8-sig") as fh:
                raw = fh.read()
            if raw.strip():
                return json.loads(raw)
        except (PermissionError, OSError, json.JSONDecodeError, UnicodeDecodeError):
            pass
        time.sleep(delay)
    return None


class Companion:
    def __init__(self, root: str) -> None:
        self.root = root
        self.inbox = os.path.join(root, "spool", "inbox")
        self.outbox = os.path.join(root, "spool", "outbox")
        self.status = os.path.join(root, "status.json")

    def status_info(self) -> dict:
        # The heartbeat can be replaced while a reader opens it; do not treat a
        # single sharing violation or partial JSON read as a dead worker.
        return read_json_retry(self.status, attempts=8, delay=0.05) or {}

    def alive(self, max_age: float = 30.0) -> tuple[bool, str]:
        st = self.status_info()
        if not st:
            return False, "status.json missing"
        if not st.get("elevated"):
            return False, f"worker integrity={st.get('integrity')!r}, not elevated"
        try:
            from datetime import datetime, timezone

            beat = datetime.fromisoformat(st["lastBeat"])
            age = (datetime.now(timezone.utc) - beat).total_seconds()
        except Exception:
            age = 999.0
        if age > max_age:
            return False, f"heartbeat stale ({age:.0f}s)"
        return True, ""

    def call(self, action: str, params: dict | None = None, timeout: float = 45.0) -> dict:
        ok, why = self.alive()
        if not ok:
            raise RuntimeError(f"companion not available: {why}")
        try:
            os.makedirs(self.inbox, exist_ok=True)
        except OSError:
            pass

        rid = str(uuid.uuid4())
        req = {"id": rid, "action": action, "params": params or {}, "ts": time.strftime("%Y-%m-%dT%H:%M:%S")}
        tmp = os.path.join(self.inbox, f"req-{rid}.json.tmp")
        dst = os.path.join(self.inbox, f"req-{rid}.json")
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(req, fh, ensure_ascii=False)
        os.replace(tmp, dst)

        res_path = os.path.join(self.outbox, f"res-{rid}.json")
        deadline = time.time() + timeout
        while time.time() < deadline:
            if os.path.exists(res_path):
                res = read_json_retry(res_path)
                if res is not None:
                    try:
                        os.remove(res_path)
                    except Exception:
                        pass
                    if not res.get("ok"):
                        raise RuntimeError(res.get("error") or "companion action failed")
                    return res.get("data") or {}
            time.sleep(0.06)
        raise TimeoutError(f"companion action {action!r} timed out after {timeout}s")


COMP = Companion(COMPANION)


# --------------------------------------------------------------------- flexsim
PINNED_HWND: int | None = None


def persist_target(win: dict) -> None:
    if not win.get("pid"):
        return
    path = runtime_root() / "selected_window.json"
    temporary = path.with_suffix("." + uuid.uuid4().hex + ".tmp")
    temporary.write_text(json.dumps({k: win.get(k) for k in ("hwnd", "pid", "title")}, ensure_ascii=False), encoding="utf-8")
    os.replace(temporary, path)


def find_main_window() -> dict | None:
    global PINNED_HWND
    data = COMP.call("window.list", {"className": "CWindowMainAppWnd", "processName": "flexsim", "visibleOnly": True}, timeout=20)
    windows = data.get("windows", [])
    chosen = next((w for w in windows if w.get("hwnd") == PINNED_HWND), None)
    if chosen is None:
        foreground = [w for w in windows if w.get("foreground")]
        if len(foreground) == 1:
            chosen = foreground[0]
        elif len(windows) == 1:
            chosen = windows[0]
        elif windows:
            path = runtime_root() / "selected_window.json"
            saved = read_json_retry(str(path), attempts=3) if path.exists() else None
            if saved and saved.get("pid"):
                chosen = next((w for w in windows if (w.get("hwnd"), w.get("pid")) == (saved.get("hwnd"), saved.get("pid"))), None)
            if chosen is None:
                raise RuntimeError("Multiple FlexSim windows; bring the intended model to the foreground before retrying")
    if chosen:
        PINNED_HWND = chosen["hwnd"]
        persist_target(chosen)
        return {**chosen, "found": True}
    return None


def wait_main_window(timeout: float = 90.0, model_name: str | None = None) -> dict | None:
    global PINNED_HWND
    end = time.time() + timeout
    while time.time() < end:
        if model_name:
            windows = COMP.call("window.list", {"className": "CWindowMainAppWnd", "processName": "flexsim", "visibleOnly": True}, timeout=20).get("windows", [])
            matches = [w for w in windows if model_name.casefold() in w.get("title", "").casefold()]
            foreground = [w for w in matches if w.get("foreground")]
            if len(foreground) == 1 or len(matches) == 1:
                win = foreground[0] if foreground else matches[0]
                PINNED_HWND = win["hwnd"]
                persist_target(win)
                return {**win, "found": True}
        else:
            win = find_main_window()
            if win:
                return win
        time.sleep(1.0)
    return None


def open_script_panel(win: dict) -> None:
    """Open the Script panel if it is not already visible.

    Ctrl+` does not open it in this build, so click the toolbar "脚本" button
    (owner-drawn, no UIA name - the offset comes from calibration and can be
    overridden in config.json).
    """
    focus = COMP.call("focus", {"hwnd": win["hwnd"]}, timeout=20)
    if not focus.get("ok") or focus.get("foreground") != win["hwnd"]:
        raise RuntimeError("FlexSim focus was not confirmed; no input sent")
    # Restoring a minimized window invalidates the old (-32000, -32000) rect.
    current = COMP.call("window.rect", {"hwnd": win["hwnd"]}, timeout=20)
    win["rect"] = current["rect"]
    if editor_window(win):
        return
    time.sleep(0.3)
    COMP.call(
        "click",
        {"hwnd": win["hwnd"], "rel": True, "x": OFF["script_btn_dx"], "y": OFF["script_btn_dy"]},
        timeout=20,
    )
    for _ in range(20):
        time.sleep(0.25)
        if editor_window(win):
            return


def editor_window(win: dict) -> dict | None:
    data = COMP.call("child.list", {"hwnd": win["hwnd"], "className": "Scintilla", "visibleOnly": True}, timeout=20)
    candidates = [c for c in data.get("children", []) if is_script_editor(c)]
    if len(candidates) > 1:
        raise RuntimeError("Multiple writable script editors found; refusing to guess by window area")
    return candidates[0] if candidates else None


def is_script_editor(child: dict) -> bool:
    if child.get("className") != "Scintilla" or child.get("visible") is False:
        return False
    if child.get("readOnly") is not False or child.get("metadataError"):
        return False
    ancestry = child.get("ancestorTitles", "").casefold()
    if any(s in ancestry for s in ("compiler", "output", "编译器", "输出")):
        return False
    # FlexSim's input uses the C/C++ lexer. The diagnostic pane uses no lexer.
    return child.get("lexer") == 3 or any(s in ancestry for s in ("script", "脚本"))


def read_console(win: dict, limit: int = 20000) -> str:
    data = COMP.call(
        "child.list", {"hwnd": win["hwnd"], "className": "Scintilla", "visibleOnly": True}, timeout=20
    )
    chunks = []
    for child in data.get("children", []):
        if is_script_editor(child):
            continue
        try:
            got = COMP.call("text.get", {"hwnd": child["hwnd"]}, timeout=20)
            text = got.get("text") or ""
            if text.strip():
                chunks.append(text[:limit])
        except Exception:
            continue
    return "\n".join(chunks)[:limit]


def load_offsets() -> dict:
    path = os.path.join(HERE, "config.json")
    defaults = {"tab_dx": 150, "tab_dy": 40, "script_btn_dx": 525, "script_btn_dy": 54,
                "run_dx": 88, "run_dy": -18, "run_wait_ms": 4000}
    try:
        with open(path, "r", encoding="utf-8") as fh:
            defaults.update(json.load(fh))
    except Exception:
        pass
    return defaults


OFF = load_offsets()


def runtime_root() -> Path:
    path = Path(os.environ.get("FLEXSIM_MCP_RUNTIME_DIR", os.path.join(HERE, "runtime"))).resolve()
    path.mkdir(parents=True, exist_ok=True)
    return path


@contextmanager
def operation_lock():
    """Serialize the desktop across MCP clients; OS releases the lock on exit."""
    import msvcrt
    with (runtime_root() / "desktop.lock").open("a+b") as lock:
        if lock.tell() == 0:
            lock.write(b"0"); lock.flush()
        lock.seek(0)
        try:
            msvcrt.locking(lock.fileno(), msvcrt.LK_NBLCK, 1)
        except OSError as exc:
            raise RuntimeError("Another FlexSim desktop operation is in progress; no input sent") from exc
        try:
            yield
        finally:
            lock.seek(0)
            msvcrt.locking(lock.fileno(), msvcrt.LK_UNLCK, 1)


def fs_string(text: str) -> str:
    # FlexScript strings are not JSON unicode escapes. Use real UTF-8 in files.
    return json.dumps(text, ensure_ascii=False)


def load_script(args: dict) -> str:
    if bool(args.get("path")) == bool(args.get("text")):
        raise ValueError("Provide exactly one of path or text")
    text = Path(args["path"]).read_text(encoding="utf-8-sig") if args.get("path") else args["text"]
    if not isinstance(text, str) or not text.strip() or "\0" in text:
        raise ValueError("Script must be non-empty text without NUL characters")
    if len(text.encode("utf-8")) > 2_000_000:
        raise ValueError("Script exceeds the 2 MB limit")
    return text


def run_script_text(text: str, wait_ms: int | None = None, timeout_ms: int = 30000) -> dict:
    with operation_lock():
        return _run_script_text(text, wait_ms, timeout_ms)


def _run_script_text(text: str, wait_ms: int | None, timeout_ms: int) -> dict:
    if not 100 <= timeout_ms <= 600000:
        raise ValueError("timeout_ms must be between 100 and 600000")
    run_id = uuid.uuid4().hex
    directory = runtime_root() / "runs" / run_id
    directory.mkdir(parents=True)
    payload = directory / "script.fs"
    marker = directory / "completed.txt"
    footer = ("\n{ fileopen(" + fs_string(marker.as_posix()) + ', "w"); fpt('
              + fs_string(run_id) + "); fileclose(); }\n")
    payload.write_text(text + "\n" + footer, encoding="utf-8")
    wrapper = "executefsfile(" + fs_string(payload.as_posix()) + ",1);"
    win = find_main_window()
    if not win:
        raise RuntimeError("FlexSim main window not found (open the application first)")
    open_script_panel(win)
    ed = editor_window(win)
    if not ed:
        raise RuntimeError("script panel (Scintilla) not found; is the model window open?")

    written = COMP.call("text.set", {"hwnd": ed["hwnd"], "text": wrapper}, timeout=15)
    if not written.get("ok"):
        raise RuntimeError("Script editor rejected text; Run was not clicked")
    back = COMP.call("text.get", {"hwnd": ed["hwnd"]}, timeout=15).get("text")
    if back != wrapper:
        raise RuntimeError("Editor read-back differs from the launcher; Run was not clicked")
    left, top = ed["rect"]["left"], ed["rect"]["top"]

    # The Run triangle sits on the panel toolbar, just above the editor.
    COMP.call("click", {"hwnd": win["hwnd"], "rel": True,
                        "x": left + OFF["run_dx"] - win["rect"]["left"],
                        "y": top + OFF["run_dy"] - win["rect"]["top"]}, timeout=20)
    deadline = time.monotonic() + timeout_ms / 1000
    while time.monotonic() < deadline:
        try:
            if marker.read_text(encoding="utf-8-sig").strip() == run_id:
                if wait_ms:
                    time.sleep(min(max(wait_ms, 0), 60000) / 1000)
                result = {"ran": True, "verified": True, "run_id": run_id,
                          "script_path": str(payload), "console": read_console(win)}
                (directory / "result.json").write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
                return result
        except (OSError, UnicodeError):
            pass
        time.sleep(0.1)
    diagnostics = read_console(win)
    raise RuntimeError("Execution was not verified: completion marker absent (compile/runtime error, early return, or timeout). "
                       f"No automatic retry was performed. Script: {payload}. Diagnostics: {diagnostics[-4000:]}")


# --------------------------------------------------------------------- tools
def t_status(_: dict) -> dict:
    ok, why = COMP.alive()
    win = find_main_window() if ok else None
    return {
        "companion": {"ok": ok, "reason": why, "pid": (COMP.status_info() or {}).get("pid")},
        "flexsim": {
            "running": bool(win),
            "window": win,
        },
    }


def t_open(args: dict) -> dict:
    global PINNED_HWND
    existing = find_main_window() if not args.get("model") and not args.get("exe") else None
    if existing and not args.get("model") and not args.get("exe"):
        return {"window": existing, "model": None, "reused": True}
    model = args.get("model")
    exe = args.get("exe") or FLEXSIM_EXE
    if not os.path.exists(exe):
        raise RuntimeError(f"FlexSim executable not found: {exe}")
    params: dict[str, Any] = {"exe": exe, "args": []}
    if model:
        model = os.path.abspath(model)
        if not os.path.exists(model):
            raise RuntimeError(f"model not found: {model}")
        # PowerShell Start-Process joins ArgumentList elements without quoting.
        params["args"] = [subprocess.list2cmdline([model])]
        PINNED_HWND = None
    COMP.call("proc.start", params, timeout=40)
    win = wait_main_window(args.get("timeout", 90), os.path.basename(model) if model else None)
    if not win:
        raise RuntimeError("Requested FlexSim model did not finish opening before the timeout; no old window was accepted as success")
    return {"window": win, "model": model or None}


def t_close(_: dict) -> dict:
    return COMP.call("proc.kill", {"name": "flexsim"}, timeout=30)


def t_set_script(args: dict) -> dict:
    text = load_script(args)
    with operation_lock():
        win = find_main_window()
        if not win:
            raise RuntimeError("FlexSim main window not found")
        open_script_panel(win)
        ed = editor_window(win)
        if not ed:
            raise RuntimeError("No positively identified writable script editor")
        out = COMP.call("text.set", {"hwnd": ed["hwnd"], "text": text}, timeout=30)
        if not out.get("ok") or COMP.call("text.get", {"hwnd": ed["hwnd"]}).get("text") != text:
            raise RuntimeError("Script text did not round-trip; nothing was run")
        return {"written": True, "verified": True, "characters": len(text)}


def t_run_script(args: dict) -> dict:
    return run_script_text(load_script(args), args.get("wait_ms"), args.get("timeout_ms", 30000))


def t_console(args: dict) -> dict:
    win = find_main_window()
    if not win:
        raise RuntimeError("FlexSim main window not found")
    return {"console": read_console(win, args.get("limit", 20000)),
            "source": "diagnostic_panes", "note": "Script input is excluded; print() output may not be exposed by this FlexSim version."}


def t_save(args: dict) -> dict:
    raw = os.path.expandvars(os.path.expanduser(args["path"]))
    if not os.path.isabs(raw):
        raise ValueError("Save path must be absolute")
    path = Path(unicodedata.normalize("NFC", raw)).resolve()
    reserved = {"CON", "PRN", "AUX", "NUL"} | {f"{p}{i}" for p in ("COM", "LPT") for i in range(1, 10)}
    for part in path.parts[1:]:
        if (part.rstrip(" .") != part or any(c in part for c in '<>:"|?*')
                or part.split(".")[0].upper() in reserved):
            raise ValueError("Invalid or reserved Windows path component: " + part)
    if path.suffix.casefold() != ".fsm":
        raise ValueError("Model filename must end with .fsm")
    path.parent.mkdir(parents=True, exist_ok=True)
    with operation_lock():
        before = path.stat() if path.exists() else None
        previous_hash = hashlib.sha256(path.read_bytes()).hexdigest() if before else None
        if before and not args.get("overwrite", False):
            raise FileExistsError("Destination already exists; use a new filename or explicitly set overwrite=true")
        backup = None
        if before:
            directory = path.parent / ".backups"
            directory.mkdir(exist_ok=True)
            stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
            backup = directory / f"{path.stem}.{stamp}.{uuid.uuid4().hex[:8]}.fsm"
            shutil.copy2(path, backup)
        try:
            out = _run_script_text("savebyname(model(), " + fs_string(path.as_posix()) + ");", None, args.get("timeout_ms", 30000))
        except Exception as exc:
            raise RuntimeError(f"Save failed; previous model backup: {backup}. {exc}") from exc
        if not path.is_file() or path.stat().st_size == 0:
            raise RuntimeError("Save returned, but a non-empty model file was not produced")
        first = path.stat()
        time.sleep(0.25)
        after = path.stat()
        if (first.st_size, first.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
            raise RuntimeError("Saved file is still changing; save not confirmed")
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        if before and (before.st_mtime_ns, before.st_size, previous_hash) == (after.st_mtime_ns, after.st_size, digest):
            raise RuntimeError("Existing file did not change; a fresh save could not be verified")
        result = {**out, "saved_to": str(path), "exists": True, "size_bytes": after.st_size,
                  "sha256": digest, "backup": str(backup) if backup else None,
                  "saved_at_utc": datetime.now(timezone.utc).isoformat()}
        manifest = runtime_root() / "saves" / (out["run_id"] + ".json")
        manifest.parent.mkdir(exist_ok=True)
        manifest.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
        result["manifest"] = str(manifest)
        return result


def t_stats(args: dict) -> dict:
    import csv

    path = os.path.abspath(args["path"])
    if not os.path.exists(path):
        raise RuntimeError(f"stats file not found: {path}")
    with open(path, "r", encoding="utf-8-sig", newline="") as fh:
        rows = list(csv.DictReader(fh))
    return {"path": path, "rows": len(rows), "columns": list(rows[0].keys()) if rows else [], "data": rows[:200]}


TOOLS: dict[str, tuple[Callable[[dict], dict], dict]] = {
    "flexsim_status": (
        t_status,
        {"type": "object", "properties": {}, "additionalProperties": False,
         "description": "Companion/worker health and whether a FlexSim window is open."},
    ),
    "flexsim_open": (
        t_open,
        {"type": "object", "properties": {
            "model": {"type": "string", "description": "Optional .fsm path to open"},
            "exe": {"type": "string", "description": "Optional FlexSim executable override"},
            "timeout": {"type": "number", "description": "Seconds to wait for the main window (default 90)"},
         }, "additionalProperties": False,
         "description": "Launch FlexSim at administrator integrity (through the companion) and wait for its window."},
    ),
    "flexsim_run_script": (
        t_run_script,
        {"type": "object", "properties": {
            "path": {"type": "string", "description": "Script file (workspace path)"},
            "text": {"type": "string", "description": "Inline FlexScript source"},
            "wait_ms": {"type": "number", "description": "How long to wait after Run (default 4000)"},
            "timeout_ms": {"type": "integer", "minimum": 100, "maximum": 600000, "description": "Maximum wait for verified script completion; default 30000"},
         }, "additionalProperties": False,
         "description": "Run a UTF-8 script file through a verified input editor; report success only after a unique completion marker. Does not wait for asynchronous simulation completion."},
    ),
    "flexsim_set_script": (
        t_set_script,
        {"type": "object", "properties": {
            "path": {"type": "string"}, "text": {"type": "string"},
         }, "additionalProperties": False,
         "description": "Load script text into the Script panel without running it."},
    ),
    "flexsim_console": (
        t_console,
        {"type": "object", "properties": {"limit": {"type": "number"}}, "additionalProperties": False,
         "description": "Read the current Script panel / console text."},
    ),
    "flexsim_save": (
        t_save,
        {"type": "object", "properties": {"path": {"type": "string"},
            "overwrite": {"type": "boolean", "default": False},
            "timeout_ms": {"type": "integer", "minimum": 100, "maximum": 600000}}, "required": ["path"],
         "additionalProperties": False,
         "description": "Save to an absolute .fsm path; refuse accidental overwrite, back up explicit replacements, and verify a fresh stable non-empty file with SHA-256."},
    ),
    "flexsim_stats": (
        t_stats,
        {"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"],
         "additionalProperties": False,
         "description": "Read a CSV exported by the model (e.g. experiment results)."},
    ),
    "flexsim_close": (
        t_close,
        {"type": "object", "properties": {}, "additionalProperties": False,
         "description": "Terminate FlexSim (through the companion)."},
    ),
}


# --------------------------------------------------------------------- MCP plumbing
def tool_list() -> list[dict]:
    return [
        {"name": name, "description": spec[1].get("description", ""), "inputSchema": spec[1]}
        for name, spec in TOOLS.items()
    ]


def handle(msg: dict) -> dict | None:
    method = msg.get("method")
    mid = msg.get("id")

    if method == "initialize":
        return {
            "jsonrpc": "2.0", "id": mid,
            "result": {
                "protocolVersion": "2024-11-05",
                "capabilities": {"tools": {"listChanged": False}},
                "serverInfo": {"name": "flexsim", "version": "1.1.1"},
                "instructions": "FlexSim automation through the elevated companion.",
            },
        }
    if method in ("notifications/initialized", "initialized"):
        return None
    if method == "ping":
        return {"jsonrpc": "2.0", "id": mid, "result": {}}
    if method == "tools/list":
        return {"jsonrpc": "2.0", "id": mid, "result": {"tools": tool_list()}}
    if method == "tools/call":
        name = (msg.get("params") or {}).get("name")
        args = (msg.get("params") or {}).get("arguments") or {}
        if name not in TOOLS:
            return {"jsonrpc": "2.0", "id": mid,
                    "error": {"code": -32602, "message": f"unknown tool: {name}"}}
        try:
            result = TOOLS[name][0](args)
            text = json.dumps(result, ensure_ascii=False, indent=2)
            return {"jsonrpc": "2.0", "id": mid,
                    "result": {"content": [{"type": "text", "text": text}], "isError": False}}
        except Exception as exc:  # noqa: BLE001 - report tool errors, never crash the server
            log(f"tool {name} failed: {exc!r}")
            return {"jsonrpc": "2.0", "id": mid,
                    "result": {"content": [{"type": "text", "text": f"{type(exc).__name__}: {exc}"}],
                               "isError": True}}
    if mid is None:
        return None
    return {"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": f"method not found: {method}"}}


def main() -> None:
    for stream in (sys.stdin, sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8")
    log(f"start companion={COMPANION}")
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            log(f"bad json: {line[:200]}")
            continue
        try:
            resp = handle(msg)
        except Exception as exc:  # noqa: BLE001
            log(f"handler crashed: {exc!r}")
            resp = None
        if resp is not None:
            sys.stdout.write(json.dumps(resp, ensure_ascii=False) + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    main()
