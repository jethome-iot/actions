#!/usr/bin/python3
"""Прогнать upload_artifacts.sh против заглушки сервера приёма артефактов.

Цикл повторов и его границы по ответам сервера не угадываются: именно здесь
жили находки про `-C >= размера` (curl выходит с кодом 18, не послав байтов) и
про нечитаемое тело с кодом 200 (подстановка под set -e рвала оболочку в обход
цикла). Заглушка из stdlib воспроизводит протокол приёма ровно настолько,
насколько его видит шаг заливки.

Сценарий задаётся аргументом; печатает вывод скрипта с заменой порта на <port>,
чтобы golden не зависел от выбранного ядром номера.

Выход 77 — curl не найден, проверка пропущена.
"""
import http.server
import json
import os
import re
import shutil
import socketserver
import subprocess
import sys
import tempfile
import threading
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
ACTION_DIR = os.path.dirname(HERE)

ARTIFACT = b'firmware payload, 64 bytes long, padded to be exactly that..\n' + b'xx'
ACCEPTED = ('uploaded', 'published')


class Scenario:
    """Состояние артефакта на заглушке и правила её ответов."""

    def __init__(self, name, size):
        self.name = name
        self.size = size
        self.status = 'pending'
        self.received = 0
        self.puts = 0
        self.polls = 0
        # Сколько байт заглушка принимает за один PUT (None — сколько прислали)
        self.chunk = None
        # Сколько первых опросов отдают нечитаемое тело с кодом 200
        self.broken_polls = 0
        # Отвергать первый PUT кодом 422 (sha256 не совпал)
        self.reject_422 = False
        # Статус становится принятым только после N опросов в состоянии
        # «все байты на сервере» — сервер досчитывает sha256
        self.settle_after = 0
        self.settled_polls = 0
        # Отвечать на опрос 404: релиз или артефакт серверу неизвестен
        self.unknown = False

    @classmethod
    def build(cls, name):
        size = len(ARTIFACT)
        s = cls(name, size)
        if name == 'fresh':
            pass
        elif name == 'resume':
            # Сервер уже держит часть файла: клиент должен дослать с offset
            s.status, s.received = 'uploading', 20
        elif name == 'already-uploaded':
            s.status, s.received = 'uploaded', size
        elif name == 'rejected-422':
            s.reject_422 = True
        elif name == 'all-bytes-not-settled':
            # Байты доехали, но статус ещё uploading: PUT делать нельзя
            s.status, s.received, s.settle_after = 'uploading', size, 1
        elif name == 'all-bytes-stuck':
            # Тот же стык, но сервер так и не принимает: падение по существу
            s.status, s.received, s.settle_after = 'uploading', size, 99
        elif name == 'broken-poll-body':
            s.broken_polls = 2
        elif name == 'artifact-unknown':
            # POST /releases не проходил: повторять опрос бессмысленно
            s.unknown = True
        elif name == 'many-parts':
            # Принимает по 8 байт за PUT: частей больше, чем бюджет неудач
            s.chunk = 8
        else:
            raise SystemExit(f'unknown scenario: {name}')
        return s


class Handler(http.server.BaseHTTPRequestHandler):
    scenario = None

    def log_message(self, *args):
        pass  # лог заглушки в вывод теста не нужен

    def _json(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        s = self.scenario
        s.polls += 1
        if s.unknown:
            self._json(404, {'error': 'release or artifact not found'})
            return
        if s.broken_polls > 0:
            s.broken_polls -= 1
            # Страница ошибки от прокси, отданная с кодом 200
            body = b'<html><head><title>502 Bad Gateway</title></head></html>'
            self.send_response(200)
            self.send_header('Content-Type', 'text/html')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if s.received >= s.size and s.status not in ACCEPTED:
            s.settled_polls += 1
            if s.settled_polls > s.settle_after:
                s.status = 'uploaded'
        query = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        self._json(200, {
            'streams': query.get('stream', ['?']),
            'kind': query.get('kind', ['?'])[0],
            'status': s.status,
            'size': s.size,
            'received': s.received,
        })

    def do_PUT(self):
        s = self.scenario
        s.puts += 1
        length = int(self.headers.get('Content-Length', '0'))
        crange = self.headers.get('Content-Range')
        data = self.rfile.read(length) if length else b''

        if s.reject_422:
            s.reject_422 = False
            s.received, s.status = 0, 'pending'
            self._json(422, {'error': 'sha256 mismatch', 'received': 0})
            return

        offset = 0
        if crange:
            m = re.match(r'bytes (\d+)-(\d+)/(\d+)', crange)
            if not m:
                self._json(400, {'error': f'bad Content-Range: {crange}'})
                return
            offset = int(m.group(1))
        if offset != s.received:
            # Часть обязана начинаться ровно с текущего received
            self._json(416, {'error': 'out of sequence', 'received': s.received})
            return

        take = len(data) if s.chunk is None else min(s.chunk, len(data))
        s.received += take
        if s.received >= s.size:
            s.received = s.size
            s.status = 'uploaded'
            self._json(201, {'status': s.status, 'received': s.received})
        else:
            s.status = 'uploading'
            self._json(202, {'status': s.status, 'received': s.received})


def run(scenario_name):
    scenario = Scenario.build(scenario_name)
    Handler.scenario = scenario

    class Server(socketserver.ThreadingTCPServer):
        allow_reuse_address = True
        daemon_threads = True

    httpd = Server(('127.0.0.1', 0), Handler)
    port = httpd.server_address[1]
    threading.Thread(target=httpd.serve_forever, daemon=True).start()

    tmpdir = tempfile.mkdtemp(prefix='tsa-upload-probe-')
    try:
        artifact = os.path.join(tmpdir, 'firmware.factory.bin')
        with open(artifact, 'wb') as f:
            f.write(ARTIFACT)

        plan = os.path.join(tmpdir, 'plan.tsv')
        with open(plan, 'w', encoding='utf-8') as f:
            f.write('\t'.join(['board-selftest', 'factory', artifact,
                               'firmware.factory.bin',
                               str(len(ARTIFACT))]) + '\n')

        cfg = os.path.join(tmpdir, 'curl.cfg')
        with open(cfg, 'w', encoding='utf-8') as f:
            f.write('header = "X-API-Key: test-key"\n')

        env = dict(
            os.environ,
            TSA_BASE=f'http://127.0.0.1:{port}/jethome/tst-firmware-esp/api/v1',
            TSA_VERSION='v1.16',
            TSA_RUN_DIR=tmpdir,
            TSA_HELPER=os.path.join(ACTION_DIR, 'release_info.py'),
            TSA_CURL_CFG=cfg,
            # Без задержек: проверяется логика цикла, а не ожидание
            TSA_RETRY_DELAY='0',
            TSA_MAX_FAILURES='5',
        )
        proc = subprocess.run(
            ['bash', os.path.join(ACTION_DIR, 'upload_artifacts.sh'), plan],
            env=env, capture_output=True, text=True, timeout=120)

        out = proc.stdout + proc.stderr
        # Путь во временный каталог и порт в golden попадать не должны
        out = out.replace(tmpdir, '<tmp>').replace(str(port), '<port>')
        print(out, end='' if out.endswith('\n') or not out else '\n')
        print(f'exit: {proc.returncode}')
        accepted_file = os.path.join(tmpdir, 'accepted')
        if os.path.exists(accepted_file):
            with open(accepted_file, encoding='utf-8') as f:
                print(f'accepted file: {f.read().strip()}')
        else:
            print('accepted file: absent')
        print(f'server saw: {scenario.polls} poll(s), {scenario.puts} PUT(s), '
              f'status {scenario.status}, received {scenario.received}')
    finally:
        httpd.shutdown()
        shutil.rmtree(tmpdir, ignore_errors=True)


def main():
    if shutil.which('curl') is None:
        print('curl not found, probe skipped', file=sys.stderr)
        sys.exit(77)
    if len(sys.argv) != 2:
        raise SystemExit('usage: upload_loop_probe.py <scenario>')
    run(sys.argv[1])


if __name__ == '__main__':
    main()
