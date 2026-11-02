import importlib.util
import json
import os
from pathlib import Path
import re
import tempfile
import unittest
from contextlib import nullcontext
from unittest.mock import patch

spec=importlib.util.spec_from_file_location('flexsim_server',Path(__file__).with_name('server.py'))
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)

def editor(**changes):
    return dict({'hwnd':11,'className':'Scintilla','visible':True,'readOnly':False,'lexer':3,'area':25000,'ancestorTitles':'Script|FlexSim','rect':{'left':20,'top':500}},**changes)

class FakeComp:
    def __init__(self,complete=True,readback=True):self.complete=complete;self.readback=readback;self.text='';self.payload=None;self.clicks=0
    def call(self,action,args=None,**kw):
        args=args or {}
        if action=='window.list':return {'windows':[{'hwnd':1,'foreground':True,'className':'CWindowMainAppWnd','rect':{'left':0,'top':0}}]}
        if action=='focus':return {'ok':True,'foreground':1}
        if action=='window.rect':return {'rect':{'left':0,'top':0,'right':1280,'bottom':800}}
        if action=='child.list':return {'children':[editor(),{'hwnd':12,'className':'Scintilla','visible':True,'readOnly':True,'lexer':0,'area':100000,'ancestorTitles':'Compiler Console'}]}
        if action=='text.set':
            self.text=args['text'];self.payload=Path(json.loads(re.search(r'executefsfile\((.*),1\);',self.text).group(1)));return {'ok':True}
        if action=='text.get':return {'text':self.text if args['hwnd']==11 and self.readback else ''}
        if action=='click':
            self.clicks+=1
            if self.complete:
                body=self.payload.read_text(encoding='utf-8')
                path=json.loads(re.findall(r'fileopen\(("(?:\\.|[^"\\])*")',body)[-1])
                Path(path).write_text(self.payload.parent.name,encoding='utf-8')
            return {}
        raise AssertionError(action)

class ReliabilityTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.root=Path(self.tmp.name)
        self.env=patch.dict(os.environ,{'FLEXSIM_MCP_RUNTIME_DIR':str(self.root/'runtime')});self.env.start()
        self.lock=patch.object(m,'operation_lock',lambda:nullcontext());self.lock.start();m.PINNED_HWND=None
    def tearDown(self):self.lock.stop();self.env.stop();self.tmp.cleanup()
    def test_editor_is_not_biggest_console(self):
        with patch.object(m,'COMP',FakeComp()):self.assertEqual(m.editor_window({'hwnd':1})['hwnd'],11)
    def test_restored_window_refreshes_minimized_coordinates(self):
        window={'hwnd':1,'rect':{'left':-32000,'top':-32000}}
        with patch.object(m,'COMP',FakeComp()):m.open_script_panel(window)
        self.assertEqual(window['rect']['left'],0)
    def test_unknown_metadata_rejected(self):self.assertFalse(m.is_script_editor({'className':'Scintilla','area':999999}))
    def test_readonly_rejected(self):self.assertFalse(m.is_script_editor(editor(readOnly=True)))
    def test_compiler_title_rejected(self):self.assertFalse(m.is_script_editor(editor(ancestorTitles='Compiler output')))
    def test_ambiguous_editors_rejected(self):
        fake=FakeComp();fake.call=lambda *a,**kw:{'children':[editor(),editor(hwnd=13)]}
        with patch.object(m,'COMP',fake),self.assertRaisesRegex(RuntimeError,'Multiple writable'):m.editor_window({'hwnd':1})
    def test_unicode_payload_and_verified_execution(self):
        fake=FakeComp()
        with patch.object(m,'COMP',fake):result=m.run_script_text('string x="中文路径\\文件";')
        self.assertTrue(result['verified']);self.assertIn('中文路径',fake.payload.read_text(encoding='utf-8'));self.assertLess(len(fake.text),500)
    def test_failure_is_not_success(self):
        with patch.object(m,'COMP',FakeComp(complete=False)),self.assertRaisesRegex(RuntimeError,'not verified'):m.run_script_text('invalid syntax',timeout_ms=100)
    def test_readback_mismatch_never_clicks(self):
        fake=FakeComp(readback=False)
        with patch.object(m,'COMP',fake),self.assertRaisesRegex(RuntimeError,'read-back'):m.run_script_text('x;')
        self.assertEqual(fake.clicks,0)
    def test_script_bom(self):
        f=self.root/'中文.fs';f.write_text('print("中文");',encoding='utf-8-sig');self.assertEqual(m.load_script({'path':str(f)}),'print("中文");')
    def test_exactly_one_source(self):
        for args in ({},{'path':'x','text':'y'}):
            with self.assertRaises(ValueError):m.load_script(args)
    def test_nul_rejected(self):
        with self.assertRaises(ValueError):m.load_script({'text':'a\0b'})
    def test_heartbeat_bom(self):
        f=self.root/'status.json';f.write_text('{"pid":1}',encoding='utf-8-sig');self.assertEqual(m.read_json_retry(str(f)),{'pid':1})
    def test_partial_heartbeat_retried(self):
        f=self.root/'status.json';f.write_text('{',encoding='utf-8')
        with patch.object(m.time,'sleep',lambda _:f.write_text('{"pid":2}',encoding='utf-8')):self.assertEqual(m.read_json_retry(str(f)),{'pid':2})
    def test_refuse_overwrite_before_running(self):
        f=self.root/'same.fsm';f.write_bytes(b'old')
        with patch.object(m,'_run_script_text') as run,self.assertRaises(FileExistsError):m.t_save({'path':str(f)})
        run.assert_not_called();self.assertEqual(f.read_bytes(),b'old')
    def test_save_failure_cannot_accept_old_file(self):
        f=self.root/'same.fsm';f.write_bytes(b'old')
        with patch.object(m,'_run_script_text',return_value={'run_id':'test'}),self.assertRaisesRegex(RuntimeError,'did not change'):m.t_save({'path':str(f),'overwrite':True})
        self.assertEqual(f.read_bytes(),b'old')
    def test_save_missing_file(self):
        with patch.object(m,'_run_script_text',return_value={'run_id':'test'}),self.assertRaisesRegex(RuntimeError,'not produced'):m.t_save({'path':str(self.root/'new.fsm')})
    def test_save_empty_file(self):
        f=self.root/'empty.fsm'
        def write(*a):f.write_bytes(b'');return {'run_id':'test'}
        with patch.object(m,'_run_script_text',side_effect=write),self.assertRaisesRegex(RuntimeError,'not produced'):m.t_save({'path':str(f)})
    def test_unicode_save_backup_and_manifest(self):
        f=self.root/'中文 空格 $文件.fsm';f.write_bytes(b'old')
        def write(code,*args):
            self.assertIn('中文',code);self.assertNotIn('\\u4e2d',code);f.write_bytes(b'new model');return {'run_id':'test','ran':True,'verified':True}
        with patch.object(m,'_run_script_text',side_effect=write):r=m.t_save({'path':str(f),'overwrite':True})
        self.assertEqual(Path(r['backup']).read_bytes(),b'old');self.assertEqual(r['size_bytes'],9);self.assertEqual(len(r['sha256']),64);self.assertTrue(Path(r['manifest']).is_file())
    def test_save_extension_and_absolute(self):
        for path in ('relative.fsm',str(self.root/'wrong.txt')):
            with self.assertRaises(ValueError):m.t_save({'path':path})
    def test_string_quote_is_escaped_without_json_unicode(self):
        value=m.fs_string('中文 "路径"');self.assertIn('\\"',value);self.assertIn('中文',value)
    def test_windows_reserved_filename_rejected(self):
        for name in ('CON.fsm','bad?.fsm','tail. /x.fsm'):
            with self.assertRaises(ValueError):m.t_save({'path':str(self.root/name)})
    def test_mcp_errors_are_flagged(self):
        response=m.handle({'id':1,'method':'tools/call','params':{'name':'flexsim_run_script','arguments':{}}});self.assertTrue(response['result']['isError'])
    def test_console_excludes_editor_source(self):
        with patch.object(m,'COMP',FakeComp()):self.assertEqual(m.read_console({'hwnd':1}),'')
    def test_wait_does_not_accept_unloaded_homepage(self):
        fake=FakeComp();fake.call=unittest.mock.Mock(side_effect=[{'windows':[{'hwnd':1,'title':'FlexSim 2022'}]},{'windows':[{'hwnd':2,'title':'FlexSim 2022 - target.fsm'}]}])
        with patch.object(m,'COMP',fake),patch.object(m.time,'sleep'):
            self.assertIn('target.fsm',m.wait_main_window(2,'target.fsm')['title'])
    def test_wait_for_model_does_not_pin_the_old_window(self):
        m.PINNED_HWND=1
        fake=FakeComp();fake.call=lambda *a,**k:{'windows':[{'hwnd':1,'title':'old.fsm','foreground':True},{'hwnd':2,'title':'new.fsm'}]}
        with patch.object(m,'COMP',fake):self.assertEqual(m.wait_main_window(1,'new.fsm')['hwnd'],2)
    def test_reconnected_client_uses_verified_window_identity(self):
        m.persist_target({'hwnd':2,'pid':200,'title':'model.fsm'})
        fake=FakeComp();fake.call=lambda *a,**k:{'windows':[{'hwnd':1,'pid':100},{'hwnd':2,'pid':200}]}
        with patch.object(m,'COMP',fake):self.assertEqual(m.find_main_window()['hwnd'],2)
    def test_recycled_handle_is_not_trusted(self):
        m.persist_target({'hwnd':2,'pid':200,'title':'model.fsm'})
        fake=FakeComp();fake.call=lambda *a,**k:{'windows':[{'hwnd':1,'pid':100},{'hwnd':2,'pid':201}]}
        with patch.object(m,'COMP',fake),self.assertRaisesRegex(RuntimeError,'Multiple FlexSim'):m.find_main_window()
    def test_existing_window_reused_for_open_without_model(self):
        fake=FakeComp()
        with patch.object(m,'COMP',fake):self.assertTrue(m.t_open({})['reused'])

if __name__=='__main__':unittest.main()
