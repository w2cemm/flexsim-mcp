"""Start the bundled stdio server without writing diagnostics to stdout."""
from __future__ import annotations

import json
import os
from pathlib import Path
import runpy
import sys

ROOT = Path(__file__).resolve().parents[1]


def settings_path() -> Path:
    if os.environ.get('FLEXSIM_MCP_SETTINGS'):
        return Path(os.environ['FLEXSIM_MCP_SETTINGS'])
    base = Path(os.environ['LOCALAPPDATA']) if os.environ.get('LOCALAPPDATA') else Path.home() / '.local' / 'share'
    return base / 'FlexSimMCP' / 'settings.json'


def configure() -> None:
    path = settings_path()
    settings = json.loads(path.read_text(encoding='utf-8-sig')) if path.exists() else {}
    for key, value in settings.items():
        if key in {'FLEXSIM_COMPANION_DIR', 'FLEXSIM_EXE', 'FLEXSIM_MCP_RUNTIME_DIR', 'FLEXSIM_MCP_LOG'}:
            if not isinstance(value, str) or not value:
                raise ValueError(f'{key} must be a nonempty string')
            os.environ.setdefault(key, value)
    companion = Path(os.environ.get('FLEXSIM_COMPANION_DIR', ROOT / 'companion')).resolve()
    os.environ.setdefault('FLEXSIM_COMPANION_DIR', str(companion))
    # Every client using the same companion must share the desktop lock.
    default_runtime = companion.parent / 'flexsim-mcp' / 'runtime'
    os.environ.setdefault('FLEXSIM_MCP_RUNTIME_DIR', str(default_runtime))
    os.environ.setdefault('FLEXSIM_MCP_LOG', str(Path(os.environ['FLEXSIM_MCP_RUNTIME_DIR']) / 'flexsim-mcp.log'))


if __name__ == '__main__':
    try:
        configure()
        runpy.run_path(str(ROOT / 'flexsim-mcp' / 'server.py'), run_name='__main__')
    except Exception as exc:
        print(f'FlexSim MCP startup failed: {exc}', file=sys.stderr)
        raise SystemExit(1)
