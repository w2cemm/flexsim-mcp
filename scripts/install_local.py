"""Register the plugin using Codex's supported CLI; no elevation or task changes."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--companion', type=Path, help='Reuse an existing companion directory')
    parser.add_argument('--codex', default='codex', help='Codex executable')
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()
    codex = shutil.which(args.codex)
    if not codex:
        parser.error('Codex CLI was not found; use --codex with its full executable path')
    companion = (args.companion or ROOT / 'companion').resolve()
    if not (companion / 'worker.ps1').is_file():
        parser.error(f'worker.ps1 not found in {companion}')
    base = Path(os.environ['LOCALAPPDATA']) if os.environ.get('LOCALAPPDATA') else Path.home() / '.local' / 'share'
    state = base / 'FlexSimMCP'
    settings = state / 'settings.json'
    commands = [[codex, 'plugin', 'marketplace', 'add', str(ROOT), '--json'],
                [codex, 'plugin', 'add', 'flexsim-mcp@flexsim-local', '--json']]
    values = {'FLEXSIM_COMPANION_DIR': str(companion),
              'FLEXSIM_MCP_RUNTIME_DIR': str(companion.parent / 'flexsim-mcp' / 'runtime')}
    print(json.dumps({'settings': str(settings), 'values': values, 'commands': commands}, ensure_ascii=False, indent=2))
    if args.dry_run:
        return
    state.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    codex_home = Path(os.environ.get('CODEX_HOME', Path.home() / '.codex'))
    codex_config = codex_home / 'config.toml'
    if codex_config.exists():
        shutil.copy2(codex_config, state / f'codex-config.{stamp}.backup.toml')
    if settings.exists():
        current = json.loads(settings.read_text(encoding='utf-8-sig'))
        current.update(values)
        values = current
        shutil.copy2(settings, state / f'settings.{stamp}.backup.json')
    settings.write_text(json.dumps(values, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    outputs = []
    for command in commands:
        result = subprocess.run(command, text=True, encoding='utf-8', capture_output=True)
        print(result.stdout)
        print(result.stderr, file=sys.stderr)
        if result.returncode:
            raise SystemExit(result.returncode)
        outputs.append(json.loads(result.stdout))
    files = ['.codex-plugin/plugin.json', '.mcp.json', 'scripts/launch.py', 'flexsim-mcp/server.py', 'companion/worker.ps1']
    receipt = {'installed_at_utc': datetime.now(timezone.utc).isoformat(), 'version': '1.1.1',
               'source': str(ROOT), 'settings': str(settings), 'companion': str(companion),
               'registration': outputs,
               'sha256': {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in files}}
    (state / 'installation.json').write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(f'Installation receipt: {state / "installation.json"}')


if __name__ == '__main__':
    main()
