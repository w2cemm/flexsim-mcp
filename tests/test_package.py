import importlib.util
import json
import os
import re
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('launcher', ROOT / 'scripts' / 'launch.py')
launcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(launcher)


class PackageTests(unittest.TestCase):
    def test_manifest_and_marketplace_paths(self):
        manifest = json.loads((ROOT / '.codex-plugin/plugin.json').read_text(encoding='utf-8'))
        self.assertTrue(manifest['requires_local_executor'])
        self.assertTrue((ROOT / manifest['mcpServers']).is_file())
        marketplace = json.loads((ROOT / '.agents/plugins/marketplace.json').read_text(encoding='utf-8'))
        self.assertEqual(marketplace['plugins'][0]['name'], manifest['name'])
        self.assertEqual((ROOT / marketplace['plugins'][0]['source']['path']).resolve(), ROOT)
        config = json.loads((ROOT / '.mcp.json').read_text(encoding='utf-8'))['mcpServers']['flexsim']
        self.assertEqual(config['args'], ['${PLUGIN_ROOT}/scripts/launch.py'])
        self.assertEqual(config['type'], 'stdio')

    def test_stdio_handshake_list_and_unknown_tool(self):
        with tempfile.TemporaryDirectory() as temp:
            env = dict(os.environ, FLEXSIM_MCP_SETTINGS=str(Path(temp) / 'missing.json'),
                       FLEXSIM_MCP_RUNTIME_DIR=temp, FLEXSIM_MCP_LOG=str(Path(temp) / 'mcp.log'))
            requests = [
                {'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {}},
                {'jsonrpc': '2.0', 'method': 'notifications/initialized'},
                {'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'},
                {'jsonrpc': '2.0', 'id': 3, 'method': 'tools/call', 'params': {'name': 'unknown', 'arguments': {}}},
            ]
            result = subprocess.run([sys.executable, str(ROOT / 'scripts/launch.py')],
                                    input='\n'.join(json.dumps(x) for x in requests) + '\n',
                                    text=True, encoding='utf-8', env=env, capture_output=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stderr)
            responses = [json.loads(line) for line in result.stdout.splitlines()]
            self.assertEqual(len(responses), 3)
            self.assertEqual(responses[0]['result']['serverInfo']['version'], '1.1.1')
            self.assertEqual(len(responses[1]['result']['tools']), 8)
            self.assertEqual(responses[2]['error']['code'], -32602)

    def test_environment_overrides_personal_settings(self):
        with tempfile.TemporaryDirectory() as temp:
            settings = Path(temp) / 'settings.json'
            settings.write_text(json.dumps({'FLEXSIM_EXE': 'settings.exe', 'FLEXSIM_COMPANION_DIR': temp}), encoding='utf-8')
            with patch.dict(os.environ, {'FLEXSIM_MCP_SETTINGS': str(settings), 'FLEXSIM_EXE': 'environment.exe'}, clear=True):
                launcher.configure()
                self.assertEqual(os.environ['FLEXSIM_EXE'], 'environment.exe')
                self.assertEqual(Path(os.environ['FLEXSIM_COMPANION_DIR']), Path(temp))

    def test_same_companion_uses_existing_desktop_lock(self):
        with tempfile.TemporaryDirectory() as temp:
            companion = Path(temp) / 'companion'
            with patch.dict(os.environ, {'FLEXSIM_MCP_SETTINGS': str(Path(temp) / 'missing.json'),
                                        'FLEXSIM_COMPANION_DIR': str(companion)}, clear=True):
                launcher.configure()
                self.assertEqual(Path(os.environ['FLEXSIM_MCP_RUNTIME_DIR']), Path(temp) / 'flexsim-mcp/runtime')

    def test_invalid_settings_fail_cleanly_without_protocol_output(self):
        with tempfile.TemporaryDirectory() as temp:
            settings = Path(temp) / 'settings.json'
            settings.write_text('{invalid', encoding='utf-8')
            env = dict(os.environ, FLEXSIM_MCP_SETTINGS=str(settings))
            result = subprocess.run([sys.executable, str(ROOT / 'scripts/launch.py')], input='', text=True,
                                    encoding='utf-8', env=env, capture_output=True, timeout=15)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, '')
            self.assertIn('startup failed', result.stderr)

    def test_distribution_has_no_user_absolute_path(self):
        for name in ['.codex-plugin/plugin.json', '.mcp.json', '.agents/plugins/marketplace.json',
                     'companion/worker.ps1', 'scripts/launch.py', 'scripts/install_local.py']:
            text = (ROOT / name).read_text(encoding='utf-8')
            self.assertIsNone(re.search(r'[A-Za-z]:[/\\]Users[/\\][^/\\\s\"\']+', text), name)


if __name__ == '__main__':
    unittest.main()
