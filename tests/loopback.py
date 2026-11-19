"""Exercise real VLESS TCP/TLS through localhost only. Run as a regular user."""

import contextlib
import http.server
import json
import os
import shutil
import socket
import subprocess
import tempfile
import threading
import time
from pathlib import Path

TOOLBOX = Path(__file__).resolve().parent.parent / 'singbox-toolbox.sh'
MESSAGE = b'sing-box loopback integration\n'


def executable(default, env_var=None):
    requested = os.environ.get(env_var, default) if env_var else default
    path = shutil.which(requested)
    if not path:
        raise SystemExit(f'Required test executable missing: {default}.')
    return Path(path).resolve()


def unused_port():
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 0))
        return probe.getsockname()[1]


class TestOrigin(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Length', str(len(MESSAGE)))
        self.end_headers()
        self.wfile.write(MESSAGE)

    def log_message(self, _format, *args):
        pass


@contextlib.contextmanager
def start_box(box, config, listen_port, folder):
    subprocess.run([box, 'check', '-c', config], cwd=folder, check=True)
    with (folder / (config.stem + '.log')).open('wb') as log:
        process = subprocess.Popen([box, 'run', '-c', config], cwd=folder, stdout=log, stderr=subprocess.STDOUT)
        try:
            until = time.monotonic() + 4
            while time.monotonic() < until and process.poll() is None:
                try:
                    with socket.create_connection(('127.0.0.1', listen_port), timeout=.2):
                        break
                except OSError:
                    time.sleep(.05)
            else:
                raise RuntimeError('A sing-box loopback listener did not start.')
            yield
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=4)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=1)


def write_json(path, value):
    path.write_text(json.dumps(value), encoding='utf-8')


def client_config(bash, folder, name, uuid, upstream_port, proxy_port, certificate):
    link = folder / f'{name}.vless'
    profile = folder / f'{name}.profile.json'
    config = folder / f'{name}.config.json'
    no_exclusions = folder / 'no-exclusions.json'
    link.write_text(f'vless://{uuid}@127.0.0.1:{upstream_port}?type=tcp&security=tls&sni=localhost\n')
    write_json(no_exclusions, [])
    generate = '\n'.join([
        'set -e',
        'source "$1"',
        'vless_profile "$2" "$3"',
        'generate_config "$3" proxy no "$4" "$5"',
    ])
    subprocess.run(
        [bash, '-c', generate, 'loopback', TOOLBOX, link, profile, no_exclusions, config],
        cwd=folder,
        check=True,
    )
    data = json.loads(config.read_text())
    data['inbounds'][0]['listen_port'] = proxy_port
    data['outbounds'][0]['tls']['certificate'] = [certificate.read_text()]
    write_json(config, data)
    return config


def fetch(curl, origin_port, proxy=None):
    args = [curl, '-q', '-fsS', '--max-time', '4']
    args += ['--proxy', proxy, '--noproxy', ''] if proxy else ['--proxy', '', '--noproxy', '*']
    return subprocess.run([*args, f'http://127.0.0.1:{origin_port}/probe'], capture_output=True, check=False)


def main():
    if os.geteuid() == 0:
        raise SystemExit('Run this loopback test as an unprivileged user.')
    box = executable('sing-box', 'SINGBOX_TEST_BIN')
    bash = executable('bash', 'BASH_TEST_BIN')
    curl = executable('curl')
    openssl = executable('openssl')
    working = '00000000-0000-4000-8000-000000000001'
    wrong = '00000000-0000-4000-8000-000000000002'
    with tempfile.TemporaryDirectory(prefix='singbox-loopback-') as tmp:
        folder = Path(tmp)
        certificate, key = folder / 'localhost.cert', folder / 'localhost.key'
        subprocess.run([openssl, 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                        '-subj', '/CN=localhost', '-addext', 'subjectAltName=DNS:localhost',
                        '-keyout', key, '-out', certificate], cwd=folder, check=True, stderr=subprocess.DEVNULL)
        with http.server.ThreadingHTTPServer(('127.0.0.1', 0), TestOrigin) as origin:
            thread = threading.Thread(target=origin.serve_forever, daemon=True)
            thread.start()
            try:
                origin_port = origin.server_address[1]
                direct = fetch(curl, origin_port)
                if direct.returncode or direct.stdout != MESSAGE:
                    raise RuntimeError('The independent loopback HTTP origin is unavailable.')
                upstream_port = unused_port()
                upstream = folder / 'upstream.json'
                write_json(upstream, {
                    'log': {'disabled': True},
                    'inbounds': [{
                        'type': 'vless',
                        'tag': 'in',
                        'listen': '127.0.0.1',
                        'listen_port': upstream_port,
                        'users': [{'uuid': working}],
                        'tls': {
                            'enabled': True,
                            'certificate_path': str(certificate),
                            'key_path': str(key),
                        },
                    }],
                    'outbounds': [{'type': 'direct', 'tag': 'direct'}],
                })
                with start_box(box, upstream, upstream_port, folder):
                    proxy_port = unused_port()
                    healthy = client_config(bash, folder, 'working', working, upstream_port, proxy_port, certificate)
                    with start_box(box, healthy, proxy_port, folder):
                        for protocol in ('socks5h', 'http'):
                            response = fetch(curl, origin_port, f'{protocol}://127.0.0.1:{proxy_port}')
                            if response.returncode or response.stdout != MESSAGE:
                                raise RuntimeError(f'Loopback VLESS TCP/TLS failed with {protocol}.')
                            print(f'PASS real VLESS TCP/TLS via {protocol}, with certificate verification')
                    invalid = client_config(bash, folder, 'wrong', wrong, upstream_port, proxy_port, certificate)
                    with start_box(box, invalid, proxy_port, folder):
                        response = fetch(curl, origin_port, f'socks5h://127.0.0.1:{proxy_port}')
                        if not response.returncode or response.stdout == MESSAGE:
                            raise RuntimeError('An incorrect VLESS UUID successfully fetched the loopback origin.')
                        print('PASS wrong UUID passes configuration checks and fails real SOCKS5 connectivity')
            finally:
                origin.shutdown()
                thread.join(timeout=2)


if __name__ == '__main__':
    main()
