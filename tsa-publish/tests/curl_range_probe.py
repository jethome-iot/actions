#!/usr/bin/python3
"""Зафиксировать, что curl реально кладёт в запрос заливки артефакта.

Проверяются два допущения шага заливки: Content-Range при возобновлении
и сохранность версии в пути URL.

Шаг заливки возобновляет передачу через `curl -T <файл> -C <received>` и
полагается на то, что curl сам выставит `Content-Range: bytes <от>-<до>/<всего>`,
а без `-C` пошлёт файл целиком и без этого заголовка. Сервера у тестов нет,
поэтому поведение проверяется на заглушке из stdlib: тест заметит, если
очередная версия curl начнёт посылать что-то другое.

Выход 77 — curl не найден, проверка пропущена.
"""
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import os

# Размер тела фиксирован, чтобы границы в Content-Range были стабильны в golden
PAYLOAD = bytes(range(256)) * 4

# Интересуют только эти заголовки: остальные зависят от версии curl
WANTED = ('content-range', 'content-length')


def run_case(path, resume, url_path='/releases/v1.16/artifact'):
    """Поднять заглушку, сходить на неё curl-ом и вернуть строки запроса."""
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(('127.0.0.1', 0))
    server.listen(1)
    server.settimeout(10)
    port = server.getsockname()[1]

    cmd = ['curl', '-sS', '--max-time', '10',
           '-H', 'Content-Type: application/octet-stream', '-T', path]
    if resume is not None:
        cmd += ['-C', resume]
    cmd.append(f'http://127.0.0.1:{port}{url_path}')

    curl = subprocess.Popen(cmd, stdout=subprocess.DEVNULL,
                            stderr=subprocess.PIPE)
    try:
        conn, _ = server.accept()
        conn.settimeout(10)
        raw = b''
        while b'\r\n\r\n' not in raw and len(raw) < 65536:
            chunk = conn.recv(4096)
            if not chunk:
                break
            raw += chunk
        conn.sendall(b'HTTP/1.1 202 Accepted\r\nContent-Length: 0\r\n'
                     b'Connection: close\r\n\r\n')
        conn.close()
    finally:
        curl.wait(timeout=15)
        server.close()

    head = raw.split(b'\r\n\r\n', 1)[0].decode('latin-1')
    lines = head.split('\r\n')
    result = [lines[0]]
    found = {}
    for line in lines[1:]:
        name, _, value = line.partition(':')
        if name.strip().lower() in WANTED:
            found[name.strip().lower()] = value.strip()
    for name in WANTED:
        result.append(f'{name}: {found.get(name, "(absent)")}')
    return result


def main():
    if shutil.which('curl') is None:
        print('curl not found, probe skipped', file=sys.stderr)
        sys.exit(77)

    tmpdir = tempfile.mkdtemp(prefix='tsa-range-probe-')
    path = os.path.join(tmpdir, 'payload.bin')
    try:
        with open(path, 'wb') as f:
            f.write(PAYLOAD)
        print(f'payload: {len(PAYLOAD)} bytes')
        # Версией бывает ISO-таймштамп: проверяем, что '+' и ':' доезжают в
        # пути как есть и '+' не превращается в пробел
        cases = (
            ('no -C', None, '/releases/v1.16/artifact'),
            ('-C 0', '0', '/releases/v1.16/artifact'),
            ('-C 100', '100', '/releases/v1.16/artifact'),
            ('ISO version in path', None,
             '/releases/2025-12-23T07:05:42+00:00/artifact'),
        )
        for label, resume, url_path in cases:
            lines = run_case(path, resume, url_path)
            print(f'case {label}:')
            for line in lines:
                # Версия протокола в строке запроса не влияет на проверку
                print(f'  {re.sub(r" HTTP/.*$", " HTTP", line)}')
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


if __name__ == '__main__':
    main()
