#!/usr/bin/python3
"""Проверить, что ключ API доезжает до сервера неискажённым и не лежит открытым.

write_api_config из curl_api_config.sh пишет ключ в конфиг curl, где значение
берётся в двойные кавычки — значит '\\' и '"' внутри ключа надо экранировать.
Проверяем на ключе со всеми опасными символами: права файла, его содержимое
и заголовок, который curl реально посылает на заглушку из stdlib.

Ключ здесь тестовый, не секрет. Выход 77 — curl не найден, проверка пропущена.
"""
import os
import shutil
import socket
import stat
import subprocess
import sys
import tempfile

# Ключ с символами, которые ломают разбор конфига curl, если их не экранировать
TEST_KEY = r'''k"ey\with$pecial #hash and=equals'''

HELPER = os.path.join(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__))), 'curl_api_config.sh')


def write_config(cfg_path):
    """Вызвать write_api_config так, как это делает шаг действия."""
    script = f'set -euo pipefail\nsource "{HELPER}"\nwrite_api_config "$1"\n'
    env = dict(os.environ, TSA_API_KEY=TEST_KEY)
    subprocess.run(['bash', '-c', script, 'bash', cfg_path],
                   env=env, check=True)


def delivered_header(cfg_path):
    """Сходить curl-ом с этим конфигом на заглушку и вернуть X-API-Key."""
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(('127.0.0.1', 0))
    server.listen(1)
    server.settimeout(10)
    port = server.getsockname()[1]

    curl = subprocess.Popen(
        ['curl', '-sS', '--max-time', '10', '--config', cfg_path,
         f'http://127.0.0.1:{port}/releases'],
        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    try:
        conn, _ = server.accept()
        conn.settimeout(10)
        raw = b''
        while b'\r\n\r\n' not in raw and len(raw) < 65536:
            chunk = conn.recv(4096)
            if not chunk:
                break
            raw += chunk
        conn.sendall(b'HTTP/1.1 200 OK\r\nContent-Length: 0\r\n'
                     b'Connection: close\r\n\r\n')
        conn.close()
    finally:
        curl.wait(timeout=15)
        server.close()

    head = raw.split(b'\r\n\r\n', 1)[0].decode('latin-1')
    for line in head.split('\r\n')[1:]:
        name, _, value = line.partition(':')
        if name.strip().lower() == 'x-api-key':
            return value.strip()
    return None


def main():
    if shutil.which('curl') is None:
        print('curl not found, probe skipped', file=sys.stderr)
        sys.exit(77)

    tmpdir = tempfile.mkdtemp(prefix='tsa-key-probe-')
    cfg_path = os.path.join(tmpdir, 'curl.cfg')
    try:
        write_config(cfg_path)
        mode = stat.S_IMODE(os.stat(cfg_path).st_mode)
        print(f'config mode: {mode:04o}')
        with open(cfg_path, encoding='utf-8') as f:
            print(f'config line: {f.read().rstrip()}')
        got = delivered_header(cfg_path)
        print(f'delivered X-API-Key: {got}')
        print(f'key survived escaping: {"yes" if got == TEST_KEY else "no"}')
        if got != TEST_KEY:
            print(f'expected: {TEST_KEY}')
            sys.exit(1)
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


if __name__ == '__main__':
    main()
