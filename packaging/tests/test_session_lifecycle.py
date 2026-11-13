"""Session shutdown ownership, graceful Fresh exit, and helper lifetime."""
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import socket
import tempfile
import threading
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]


def load(name):
    loader = importlib.machinery.SourceFileLoader(name.replace('-', '_'), str(ROOT / 'packaging/helpers' / name))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


STOP = load('mash-session-stop')


class LifecycleTest(unittest.TestCase):
    def test_selects_bundle_executable_identity_not_process_name(self):
        res = Path('/example/Mash.app/Contents/Resources')
        py, fresh = str(res / 'python/bin/python3'), str(res / 'libexec/fresh')
        listing = f'11 {py} {res}/bin/mash-dev-tab-park\n12 {fresh} --server\n13 /other/fresh --server\n14 {fresh} --server\n'
        def identity(pid, _):
            return ({11: py, 12: fresh, 14: '/other/fresh'}.get(pid, ''), str(pid))
        with patch.object(STOP, 'output', return_value=listing), patch.object(STOP, 'identity', side_effect=identity):
            self.assertEqual(set(STOP.owned(res)), {11, 12})

    def test_foreign_fresh_socket_is_never_contacted(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            (d / 'foreign.pid').write_text('99999')
            with patch.object(STOP, 'owned', return_value={}), patch.object(STOP, 'quit_fresh') as quit_:
                self.assertEqual(STOP.stop(Path('/bundle'), d, grace=0), 0)
                quit_.assert_not_called()

    def test_pid_reuse_prevents_signal_and_ipc(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp); (d/'ours.pid').write_text('11')
            targets = {11: ('fresh', ('/bundle/fresh', 'old')),
                       12: ('helper', ('/bundle/python', 'old'))}
            with patch.object(STOP, 'owned', return_value=targets), \
                 patch.object(STOP, 'identity', return_value=('/other', 'new')), \
                 patch.object(STOP.os, 'kill') as kill_, patch.object(STOP, 'quit_fresh') as quit_:
                self.assertEqual(STOP.stop(Path('/bundle'), d, grace=0), 0)
                kill_.assert_not_called(); quit_.assert_not_called()

    def test_unresponsive_fresh_is_not_forcibly_killed(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp); (d/'ours.pid').write_text('11')
            token = ('/bundle/fresh', 'start')
            with patch.object(STOP, 'owned', return_value={11: ('fresh', token)}), \
                 patch.object(STOP, 'identity', return_value=token), \
                 patch.object(STOP, 'quit_fresh', side_effect=OSError('timeout')), \
                 patch.object(STOP.os, 'kill') as kill_:
                self.assertEqual(STOP.stop(Path('/bundle'), d, grace=0), 1)
                kill_.assert_not_called()

    def test_fresh_receives_paired_handshake_then_graceful_quit(self):
        # Short path because macOS limits Unix socket paths to 104 bytes.
        with tempfile.TemporaryDirectory(prefix='mstop-', dir='/tmp') as tmp:
            pidfile = Path(tmp)/'own.pid'; pidfile.write_text('11')
            ctl, data = socket.socket(socket.AF_UNIX), socket.socket(socket.AF_UNIX)
            ctl.bind(str(pidfile)[:-4]+'.ctrl.sock'); ctl.listen()
            data.bind(str(pidfile)[:-4]+'.data.sock'); data.listen()
            messages = []; errors = []
            def serve():
                try:
                    with ctl.accept()[0] as c, data.accept()[0] as d:
                        c.settimeout(3); d.settimeout(3)
                        preamble = b''
                        while len(preamble)<43: preamble += d.recv(43-len(preamble))
                        stream = c.makefile('rb')
                        hello = json.loads(stream.readline()); messages.append((preamble, hello))
                        c.sendall(b'{"type":"hello"}\n')
                        messages.append(json.loads(stream.readline()))
                except Exception as e: errors.append(e)
            thread = threading.Thread(target=serve); thread.start()
            try: STOP.quit_fresh(pidfile)
            finally: thread.join(5); ctl.close(); data.close()
            self.assertFalse(errors)
            preamble, hello = messages[0]
            self.assertEqual(preamble, b'fresh-pair:'+hello['pair_token'].encode())
            self.assertEqual(hello['protocol_version'], 5)
            self.assertEqual(messages[1], {'type':'quit'})

    def test_helpers_exit_and_release_lock_after_server_disconnect(self):
        for name in ('mash-fresh-split-sync', 'mash-dev-tab-park'):
            m = load(name)
            with tempfile.TemporaryFile() as held, \
                 patch.object(m, 'single_instance', return_value=held), \
                 patch.object(m, 'socket_path', return_value='/tmp/test.sock'), \
                 patch.object(m.os.path, 'exists', return_value=True), \
                 patch.object(m, 'follow', side_effect=m.Unavailable('EOF')) as follow:
                if hasattr(m, 'seed_launch_staleness'):
                    with patch.object(m, 'seed_launch_staleness'), patch.object(m, 'visible_tabs', return_value=None):
                        self.assertEqual(m.main(), 0)
                else: self.assertEqual(m.main(), 0)
                self.assertEqual(follow.call_count, 1)

    def test_explicit_exit_and_update_use_same_detached_cleanup(self):
        stop = (ROOT/'packaging/helpers/mash-stop-sessions').read_text()
        update = (ROOT/'packaging/helpers/mash-update-common').read_text()
        self.assertIn('mash-session-stop', stop)
        self.assertIn('mash-session-stop', update)
        section = update.split('mash_update_quiesce() {',1)[1].split('\n}\n',1)[0]
        self.assertLess(section.index('detached-stop'), section.index('while :; do'))

    def test_agents_sidebar_uses_tab_label_on_both_platforms(self):
        import tomllib
        for filename in ('config.toml','config.linux.toml'):
            config = tomllib.loads((ROOT/'packaging/defaults/herdr'/filename).read_text())
            rows = config['ui']['sidebar']['agents']['rows']
            self.assertIn(['tab'], rows)
            self.assertNotIn(['terminal_title_stripped'], rows)


if __name__ == '__main__':
    unittest.main()
