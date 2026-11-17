#!/usr/bin/env python3
"""Local safety checks. No network requests leave the loopback test server."""
import contextlib
import http.server
import json
import os
from pathlib import Path
import shutil
import socket
import ssl
import subprocess
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / 'scripts'


def run_script(name, *args, env=None):
    return subprocess.run(['/bin/bash', str(SCRIPTS / name), *args],
                          text=True, capture_output=True, timeout=30,
                          env=env or os.environ.copy())


def refuse_mutation_env(base):
    fake = base / 'bin'
    fake.mkdir()
    calls = base / 'mutations'
    for name in ('docker', 'systemctl', 'apt-get', 'dpkg', 'rm', 'mv', 'cp',
                 'iptables', 'ufw', 'nft', 'sudo', 'forever', 'pm2'):
        command = fake / name
        command.write_text('#!/bin/sh\nprintf "%s\\n" "$0" >> "$TEST_CALLS"\nexit 97\n')
        command.chmod(0o755)
    env = os.environ.copy()
    env['PATH'] = str(fake) + os.pathsep + '/usr/bin:/bin'
    env['TEST_CALLS'] = str(calls)
    return env, calls


class RefusalTests(unittest.TestCase):
    def test_cutover_apply_and_rollback_never_execute_commands(self):
        for mode in ('--apply', '--rollback'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as d:
                env, calls = refuse_mutation_env(Path(d))
                r = run_script('cutover-and-rollback.sh', mode, '--domains', 'example.test', env=env)
                self.assertNotEqual(r.returncode, 0)
                self.assertIn('no changes were made', r.stderr)
                self.assertFalse(calls.exists())

    def test_manifest_is_never_sourced_in_planning(self):
        with tempfile.TemporaryDirectory() as d:
            base = Path(d)
            marker = base / 'executed'
            (base / 'MANIFEST.env').write_text(f'touch {marker}\n')
            r = run_script('cutover-and-rollback.sh', '--dry-run', '--backup-dir', str(base))
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertFalse(marker.exists())

    def test_panel_apply_refuses_even_with_confirm_and_receipt(self):
        with tempfile.TemporaryDirectory() as d:
            receipt = Path(d) / 'receipt'
            receipt.write_text('VERIFIED_EPOCH=9999999999\n')
            env, calls = refuse_mutation_env(Path(d))
            r = run_script('purge-panel-safe.sh', '--panel', 'fastpanel2', '--confirm-verified',
                           '--receipt-file', str(receipt), '--apply', env=env)
            self.assertNotEqual(r.returncode, 0)
            self.assertIn('no changes were made', r.stderr)
            self.assertFalse(calls.exists())

    def test_panel_plan_simulates_exact_installed_packages_only(self):
        with tempfile.TemporaryDirectory() as d:
            base = Path(d)
            calls = base / 'calls'
            fake = base / 'bin'
            fake.mkdir()
            def executable(name, body):
                p = fake / name
                p.write_text('#!/bin/sh\n' + body + '\n')
                p.chmod(0o755)
            executable('dpkg-query', 'case "$*" in *fastpanel2-nginx|*fastpanel2) printf installed;; *) printf "not-installed";; esac')
            executable('apt-get', 'printf "%s\\n" "$*" >> "$TEST_CALLS"')
            executable('docker', 'exit 1')
            executable('ss', 'exit 0')
            env = os.environ.copy()
            env['PATH'] = str(fake) + os.pathsep + '/usr/bin:/bin'
            env['TEST_CALLS'] = str(calls)
            r = run_script('purge-panel-safe.sh', '--panel', 'fastpanel2', env=env)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual(calls.read_text().strip(),
                '-s -o APT::Get::AutomaticRemove=false remove fastpanel2 fastpanel2-nginx')

    def test_failed_snapshot_does_not_emit_success_manifest(self):
        with tempfile.TemporaryDirectory() as d:
            base = Path(d)
            fake = base / 'bin'
            fake.mkdir()
            df = fake / 'df'
            df.write_text('#!/bin/sh\nprintf "Filesystem 1024-blocks Used Available Capacity Mounted\\nmock 100000000 10000000 90000000 10%% /\\n"\n')
            df.chmod(0o755)
            tar = fake / 'tar'
            tar.write_text('#!/bin/sh\nexit 2\n')
            tar.chmod(0o755)
            env = os.environ.copy()
            env['PATH'] = str(fake) + os.pathsep + env['PATH']
            r = run_script('backup-state.sh', '--backup-root', str(base), env=env)
            self.assertNotEqual(r.returncode, 0)
            self.assertFalse(list(base.rglob('MANIFEST.env')))
            self.assertNotIn('Snapshot created successfully', r.stdout)

    def test_preflight_does_not_launch_pm2_or_forever(self):
        with tempfile.TemporaryDirectory() as d:
            base = Path(d)
            fake = base / 'bin'
            fake.mkdir()
            calls = base / 'calls'
            for name in ('pm2', 'forever'):
                p = fake / name
                p.write_text('#!/bin/sh\necho invoked >> "$TEST_CALLS"\n')
                p.chmod(0o755)
            for name in ('docker', 'systemctl', 'find'):
                p = fake / name
                p.write_text('#!/bin/sh\nexit 1\n')
                p.chmod(0o755)
            env = os.environ.copy()
            env['PATH'] = str(fake) + os.pathsep + env['PATH']
            env['TEST_CALLS'] = str(calls)
            r = run_script('preflight-inventory.sh', '--dns-limit', '0', env=env)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertFalse(calls.exists())
            self.assertIn('PM2/forever CLIs were not invoked', r.stdout)

    def test_preflight_discovers_unicode_and_punycode_names(self):
        with tempfile.TemporaryDirectory() as d:
            fake = Path(d) / 'bin'
            fake.mkdir()
            grep = fake / 'grep'
            grep.write_text('#!/bin/sh\ncase "$*" in *server_name*) printf "server_name твойплюс.рф www.твойплюс.рф xn--e1afmkfd.xn--p1ai\\n";; esac\n')
            grep.chmod(0o755)
            for name in ('docker', 'systemctl', 'find'):
                p = fake / name
                p.write_text('#!/bin/sh\nexit 1\n')
                p.chmod(0o755)
            env = os.environ.copy()
            env['PATH'] = str(fake) + os.pathsep + env['PATH']
            r = run_script('preflight-inventory.sh', '--dns-limit', '0', env=env)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIn('твойплюс.рф'.encode('idna').decode(), r.stdout)
            self.assertIn('www.' + 'твойплюс.рф'.encode('idna').decode(), r.stdout)
            self.assertIn('xn--e1afmkfd.xn--p1ai', r.stdout)

    @unittest.skipUnless(shutil.which('node'), 'requires node')
    def test_port_guard_refuses_occupied_port_without_exposing_arguments(self):
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            listener.listen()
            r = subprocess.run(['node', str(SCRIPTS / 'start-guard.js'), '--host', '127.0.0.1',
                                '--port', str(listener.getsockname()[1]), '--', 'echo', 'private-test-token'],
                               text=True, capture_output=True, timeout=10)
            self.assertNotEqual(r.returncode, 0)
            self.assertIn('REFUSING START', r.stderr)
            self.assertNotIn('private-test-token', r.stdout + r.stderr)


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.server.hosts.append(self.headers.get('Host'))
        status = self.server.responses.pop(0) if self.server.responses else self.server.response
        self.send_response(status)
        if status == 301:
            self.send_header('Location', 'https://unreachable.invalid/')
        self.end_headers()
        self.wfile.write(b'fixture')
    def log_message(self, *_):
        pass


@unittest.skipUnless(shutil.which('openssl') and shutil.which('curl'), 'requires openssl and curl')
class RouteTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        base = Path(cls.temp.name)
        cls.cert = base / 'cert.pem'
        key = base / 'key.pem'
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                        '-keyout', str(key), '-out', str(cls.cert), '-days', '1',
                        '-subj', '/CN=example.test', '-addext', 'subjectAltName=DNS:example.test'],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        cls.server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
        cls.server.response = 200
        cls.server.responses = []
        cls.server.hosts = []
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(cls.cert, key)
        cls.server.socket = ctx.wrap_socket(cls.server.socket, server_side=True)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.thread.join()
        cls.server.server_close()
        cls.temp.cleanup()

    def setUp(self):
        self.server.response = 200
        self.server.responses = []
        self.server.hosts.clear()
        self.target = f'127.0.0.1:{self.server.server_port}'

    def verify(self, *args):
        return run_script('stage-verify.sh', '--domains', 'example.test', '--target', self.target, *args)

    def test_default_rejects_untrusted_tls_and_never_creates_receipt(self):
        with tempfile.TemporaryDirectory() as d:
            receipt = Path(d) / 'receipt'
            r = self.verify('--receipt-file', str(receipt))
            self.assertNotEqual(r.returncode, 0)
            self.assertFalse(receipt.exists())
            self.assertIn('HTTP 000', r.stdout)

    def test_nonstandard_port_keeps_original_host_and_verified_tls(self):
        r = self.verify('--cacert', str(self.cert))
        self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        self.assertEqual(self.server.hosts, ['example.test'])

    def test_redirect_is_not_followed(self):
        self.server.response = 301
        r = self.verify('--cacert', str(self.cert))
        self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        self.assertIn('HTTP 301', r.stdout)
        self.assertEqual(self.server.hosts, ['example.test'])

    def test_transient_failure_is_visible_and_retried_once(self):
        self.server.responses = [503, 200]
        r = self.verify('--cacert', str(self.cert))
        self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        self.assertIn('initial HTTP 503', r.stderr)
        self.assertIn('HTTP 200', r.stdout)
        self.assertEqual(self.server.hosts, ['example.test', 'example.test'])

    def test_explicitly_expected_502_is_not_retried(self):
        self.server.response = 502
        r = self.verify('--cacert', str(self.cert), '--expect', '502')
        self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        self.assertNotIn('[RETRY]', r.stderr)
        self.assertEqual(self.server.hosts, ['example.test'])

    def test_insecure_diagnostic_cannot_issue_receipt(self):
        with tempfile.TemporaryDirectory() as d:
            receipt = Path(d) / 'receipt'
            r = self.verify('--insecure', '--write-receipt', '--receipt-file', str(receipt))
            self.assertNotEqual(r.returncode, 0)
            self.assertFalse(receipt.exists())

    def test_explicit_receipt_and_upload_read_do_not_leak_query(self):
        with tempfile.TemporaryDirectory() as d:
            receipt = Path(d) / 'receipt'
            r = self.verify('--cacert', str(self.cert), '--write-receipt', '--receipt-file', str(receipt),
                            '--upload-url', 'https://example.test/image?token=private-test-token')
            self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
            self.assertIn('SCOPE=route_checks_only', receipt.read_text())
            self.assertNotIn('private-test-token', r.stdout + r.stderr)
            self.assertEqual(self.server.hosts, ['example.test', 'example.test'])

    def test_unicode_requires_punycode(self):
        r = run_script('stage-verify.sh', '--domains', 'тест.рф', '--target', self.target)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('ASCII/Punycode', r.stderr)


if __name__ == '__main__':
    unittest.main(verbosity=2)
