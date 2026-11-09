#!/usr/bin/python3
"""Сборка release-info.json для сервера обновлений tsa (платформа v2).

Подкоманды:
    build            — собрать release-info.json (считает size и sha256 по файлам)
    plan             — выдать план заливки артефактов в виде TSV для shell-цикла
    poll-state       — решить по ответу сервера, досылать артефакт или нет
    publish-summary  — расшифровать решение сервера по каналам публикации
    limit-check      — сверить размеры файлов с max_artifact_size сервера
    verify           — проверить, что релиз собран полностью

Только stdlib: действие запускается на self-hosted раннерах без pip.
"""
import argparse
import hashlib
import json
import os
import re
import sys

# Версия формата release-info.json, которую понимает сервер
INFO_VERSION = 1

# Все шаблоны ниже проверяются только через fullmatch и поэтому заданы без
# анкеров: '$' в Python совпадает и перед завершающим переводом строки, так что
# re.match('...$') пропустил бы значение с '\n' на конце — а оно уехало бы и в
# JSON релиза, и в URL. Через fullmatch такая ошибка невозможна по построению.

# built_at принимается только как RFC 3339 в UTC: иначе релиз уедет с чужим временем
BUILT_AT_RE = re.compile(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z')

# stream и kind подставляются в query-строку запросов к серверу, version,
# vendor и product — в путь. Разрешаем только то, что в URL не требует
# экранирования: иначе шаг заливки обратился бы не по тому адресу.
# '/' в query допустим, в сегменте пути — нет.
SLUG_RE = re.compile(r'[A-Za-z0-9._~/-]+')
SLUG_CHARS = 'A-Z a-z 0-9 . _ ~ - /'

SEGMENT_RE = re.compile(r'[A-Za-z0-9._~-]+')
SEGMENT_CHARS = 'A-Z a-z 0-9 . _ ~ -'

# В версии дополнительно разрешены '+' и ':': версией бывает ISO-таймштамп
# (2025-12-23T07:05:42+00:00), и сервер такую версию принимает. В пути URL оба
# символа легальны (RFC 3986, pchar), и '+' в пути — это плюс, а не пробел;
# в query-строке он читался бы как пробел, поэтому в SLUG_RE его нет.
VERSION_RE = re.compile(r'[A-Za-z0-9._+:~-]+')
VERSION_CHARS = 'A-Z a-z 0-9 . _ + : ~ -'

# Размер блока чтения при подсчёте sha256: образы бывают до 1.5 ГБ
CHUNK_SIZE = 1024 * 1024

# Цепочка статусов артефакта на сервере: pending → uploading → uploaded → published.
# Принятыми считаются два последних — на них заливка закончена.
ACCEPTED_STATUSES = ('uploaded', 'published')

# Расшифровка решения сервера по каналам автопубликации.
# approval — штатный ответ для публичных каналов продукта, не ошибка.
PUBLISH_DECISIONS = {
    'auto': 'server publishes it once all artifacts are accepted',
    'approval': 'waits for administrator confirmation',
}


class InputError(Exception):
    """Ошибка во входных данных — печатается пользователю без трейсбека."""


def check_url_segment(value, name, pattern, chars):
    """Проверить значение, которое уедет сегментом пути URL."""
    if not pattern.fullmatch(value):
        raise InputError(
            f'{name}: has characters that are not URL-safe '
            f'(allowed: {chars}), got {value!r}')
    # Значение из одних точек ('.', '..') — это сегмент относительного пути:
    # запрос ушёл бы не к релизу, а на уровень выше
    if set(value) == {'.'}:
        raise InputError(f'{name}: must not consist of dots only, got {value!r}')


def parse_artifacts(text):
    """Разобрать многострочный вход artifacts.

    Формат строки: потоки_через_запятую  kind  путь_к_файлу  [audience]
    Пустые строки и строки, начинающиеся с '#', игнорируются.
    """
    artifacts = []
    seen = {}
    for lineno, raw in enumerate(text.splitlines(), start=1):
        line = raw.strip()
        if not line or line.startswith('#'):
            continue
        if '\t' in raw:
            raise InputError(
                f'artifacts line {lineno}: tab is not allowed, separate fields with spaces')
        fields = line.split()
        if len(fields) < 3 or len(fields) > 4:
            raise InputError(
                f'artifacts line {lineno}: expected "streams kind path [audience]", '
                f'got {len(fields)} field(s): {line!r}')
        streams_field, kind, path = fields[:3]
        audience = fields[3] if len(fields) == 4 else None

        streams = [s for s in streams_field.split(',') if s]
        if not streams:
            raise InputError(f'artifacts line {lineno}: empty stream list')
        if len(set(streams)) != len(streams):
            raise InputError(
                f'artifacts line {lineno}: duplicate stream in {streams_field!r}')
        # stream и kind уезжают значениями query-параметров, не сегментами
        # пути: точки и слэши в них путь обойти не могут, а символы, которые
        # порвали бы саму query ('&', '#', пробел), шаблон не пропускает
        for value, name in [(kind, 'kind')] + [(s, 'stream') for s in streams]:
            if not SLUG_RE.fullmatch(value):
                raise InputError(
                    f'artifacts line {lineno}: {name} {value!r} has characters '
                    f'that are not URL-safe (allowed: {SLUG_CHARS})')

        # Артефакт запрашивается у сервера по паре (stream, kind) — она должна быть
        # уникальной, иначе шаг заливки не сможет различить два артефакта
        for stream in streams:
            key = (stream, kind)
            if key in seen:
                raise InputError(
                    f'artifacts line {lineno}: stream {stream!r} already has kind '
                    f'{kind!r} on line {seen[key]}')
            seen[key] = lineno

        artifacts.append({
            'streams': streams,
            'kind': kind,
            'path': path,
            'audience': audience,
            'lineno': lineno,
        })
    if not artifacts:
        raise InputError('artifacts: no artifact lines given')
    return artifacts


def read_artifacts_text(args):
    if args.artifacts_file == '-':
        return sys.stdin.read()
    try:
        with open(args.artifacts_file, encoding='utf-8') as f:
            return f.read()
    except OSError as e:
        raise InputError(f'cannot read artifacts file: {e}')
    except UnicodeDecodeError as e:
        raise InputError(f'artifacts file is not valid UTF-8: {e}')


def require_file(path, artifact):
    """Проверить, что файл артефакта на месте и не пуст, объяснить разбор строки."""
    if os.path.isfile(path):
        # Сервер отвергает нулевой размер при создании релиза
        # ('size must be greater than zero'). Падаем здесь, до сети: иначе
        # причина выяснилась бы кодом 400 на шаге создания релиза
        if os.path.getsize(path) == 0:
            raise InputError(
                f'artifacts line {artifact["lineno"]}: {path} is empty; '
                f'the server does not accept an artifact of size 0')
        return
    # Поля строки разделены пробелами, поэтому путь с пробелом разбирается
    # как путь + audience. Без подсказки пользователь видит в ошибке путь,
    # которого не писал, и ищет опечатку не там
    hint = ''
    if artifact['audience']:
        hint = (f' (line parsed as kind {artifact["kind"]!r}, path '
                f'{artifact["path"]!r}, audience {artifact["audience"]!r}'
                f' — a path cannot contain spaces)')
    raise InputError(
        f'artifacts line {artifact["lineno"]}: no such file: {path}{hint}')


def file_size_and_sha256(path):
    """Размер и sha256 (строчный hex) файла; читаем блоками, файлы большие."""
    digest = hashlib.sha256()
    size = 0
    try:
        with open(path, 'rb') as f:
            while True:
                chunk = f.read(CHUNK_SIZE)
                if not chunk:
                    break
                size += len(chunk)
                digest.update(chunk)
    except OSError as e:
        raise InputError(f'cannot read artifact file: {e}')
    return size, digest.hexdigest()


def cmd_build(args):
    artifacts = parse_artifacts(read_artifacts_text(args))

    for name in ('vendor', 'product', 'version', 'git_commit'):
        if not getattr(args, name):
            raise InputError(f'{name}: must not be empty')
    # vendor и product образуют базовый адрес API {url}/{vendor}/{product}/api/v1
    check_url_segment(args.vendor, 'vendor', SEGMENT_RE, SEGMENT_CHARS)
    check_url_segment(args.product, 'product', SEGMENT_RE, SEGMENT_CHARS)
    # Версия едет в путь URL и должна совпадать с тем, что прошивка печатает
    # о себе: ведущую 'v' тега не срезаем, но проверяем набор символов
    check_url_segment(args.version, 'version', VERSION_RE, VERSION_CHARS)
    if not BUILT_AT_RE.fullmatch(args.built_at):
        raise InputError(
            f'built_at: expected RFC 3339 in UTC (2026-10-22T08:00:00Z), '
            f'got {args.built_at!r}')

    release = {
        'info_version': INFO_VERSION,
        'vendor': args.vendor,
        'product': args.product,
        'version': args.version,
        'git_commit': args.git_commit,
        'built_at': args.built_at,
    }
    # Каналы автопубликации: вход publish — каналы через пробел
    channels = args.publish.split()
    if channels:
        release['publish'] = channels
    # Без public сборка внутренняя и в публичные каналы не публикуется
    if args.public:
        release['public'] = True

    entries = []
    for artifact in artifacts:
        path = os.path.join(args.base_dir, artifact['path'])
        require_file(path, artifact)
        size, sha256 = file_size_and_sha256(path)
        entry = {
            'streams': artifact['streams'],
            'kind': artifact['kind'],
            # Имя, под которым файл скачает потребитель — только базовое имя
            'file': os.path.basename(artifact['path']),
            'size': size,
            'sha256': sha256,
        }
        if artifact['audience']:
            entry['audience'] = artifact['audience']
        entries.append(entry)
    release['artifacts'] = entries

    print(json.dumps(release, indent=4))


def cmd_plan(args):
    """План заливки: по строке на артефакт, поля через табуляцию.

    stream — любой из потоков артефакта, по нему шаг заливки спрашивает статус.
    size нужен шагу заливки, чтобы не досылать уже принятый целиком файл.
    """
    artifacts = parse_artifacts(read_artifacts_text(args))
    for artifact in artifacts:
        path = os.path.join(args.base_dir, artifact['path'])
        require_file(path, artifact)
        print('\t'.join([
            artifact['streams'][0],
            artifact['kind'],
            path,
            os.path.basename(artifact['path']),
            str(os.path.getsize(path)),
        ]))


def cmd_poll_state(args):
    """Решить, что делать с артефактом, по ответу GET …/artifact.

    Печатает одной строкой: <действие> <принято байт> <статус>, где действие —
    skip (уже принят), wait (сервер держит все байты, но ещё не принял) либо
    send (досылать с offset).
    """
    data = load_response(args.json_file)

    status = data.get('status')
    if not isinstance(status, str) or not status:
        raise InputError('artifact state has no usable "status" field')

    # received уходит в curl -C: нецелое или отрицательное значение curl
    # отвергает как параметр, и шаг крутил бы пустые попытки
    received = data.get('received', 0)
    if isinstance(received, bool) or not isinstance(received, int) or received < 0:
        raise InputError(
            f'artifact state has a bad "received" value: {received!r}')

    if status in ACCEPTED_STATUSES:
        action = 'skip'
    elif received > 0 and received >= args.size:
        # curl -T с -C >= размера файла выходит с кодом 18, не послав ни
        # байта: досылать нечего, надо перечитать состояние.
        # Условие received > 0 здесь — страховка: артефакт нулевого размера
        # отвергается ещё в build, потому что его не принимает сервер, но
        # poll-state вызывается и самостоятельно и не должен это предполагать
        action = 'wait'
    else:
        action = 'send'
    print(f'{action} {received} {status}')


def load_response(path):
    try:
        with open(path, encoding='utf-8') as f:
            data = json.load(f)
    except (OSError, ValueError) as e:
        raise InputError(f'cannot parse server response: {e}')
    if not isinstance(data, dict):
        raise InputError('server response is not a JSON object')
    return data


def cmd_publish_summary(args):
    """Напечатать решение сервера по каждому каналу автопубликации."""
    data = load_response(args.json_file)
    publish = data.get('publish')
    if not publish:
        print('publish: not requested, release stays unpublished')
        return
    if not isinstance(publish, dict):
        raise InputError('publish: expected an object of channel -> decision')
    for channel in sorted(publish):
        decision = publish[channel]
        explanation = PUBLISH_DECISIONS.get(decision, 'unknown decision')
        print(f"publish channel '{channel}': {decision} — {explanation}")


def cmd_limit_check(args):
    """Сверить размеры файлов с лимитом сервера — до начала заливки гигабайтов."""
    data = load_response(args.json_file)
    limit = data.get('max_artifact_size')
    if limit is None:
        print('max_artifact_size: not reported by server, size check skipped')
        return
    # Присланный, но непригодный лимит — не повод молча отключить проверку:
    # иначе отказ по размеру случится на середине заливки гигабайта
    if isinstance(limit, bool) or not isinstance(limit, int) or limit <= 0:
        raise InputError(
            f'max_artifact_size: expected a positive whole number of bytes, '
            f'got {limit!r}')
    artifacts = parse_artifacts(read_artifacts_text(args))
    oversized = []
    for artifact in artifacts:
        path = os.path.join(args.base_dir, artifact['path'])
        try:
            size = os.path.getsize(path)
        except OSError as e:
            raise InputError(f'cannot stat artifact file: {e}')
        if size > limit:
            oversized.append((os.path.basename(artifact['path']), size))
    if oversized:
        for name, size in oversized:
            print(f'{name}: {size} bytes exceeds server limit {limit} bytes',
                  file=sys.stderr)
        raise InputError(
            f'{len(oversized)} artifact(s) larger than max_artifact_size {limit}')
    print(f'max_artifact_size: {limit} bytes, all artifacts fit')


def cmd_verify(args):
    """Релиз собран, когда каждый артефакт в статусе uploaded или published."""
    data = load_response(args.json_file)
    artifacts = data.get('artifacts')
    if not isinstance(artifacts, list) or not artifacts:
        raise InputError('release has no artifacts[] to verify')

    pending = []
    for artifact in artifacts:
        if not isinstance(artifact, dict):
            raise InputError('artifacts[]: expected JSON objects')
        streams = artifact.get('streams') or ['?']
        label = f'{streams[0]}/{artifact.get("kind", "?")}'
        status = artifact.get('status', 'unknown')
        received = artifact.get('received', 0)
        size = artifact.get('size', 0)
        print(f'  {status:<10} {label:<48} {received}/{size}')
        if status not in ACCEPTED_STATUSES:
            pending.append((label, status))

    version = data.get('version', '?')
    if pending:
        print(f'release {version}: incomplete, '
              f'{len(pending)} of {len(artifacts)} artifact(s) not accepted',
              file=sys.stderr)
        for label, status in pending:
            print(f'  {label}: {status}', file=sys.stderr)
        sys.exit(1)
    print(f'release {version}: complete, '
          f'all {len(artifacts)} artifact(s) accepted')


def main():
    parser = argparse.ArgumentParser(
        prog='release_info.py', description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest='command', required=True)

    def add_artifacts_args(p):
        p.add_argument('--artifacts-file', required=True,
                       help='file with artifact lines, "-" for stdin')
        p.add_argument('--base-dir', default='.',
                       help='directory artifact paths are relative to')

    p_build = sub.add_parser('build', help='build release-info.json')
    add_artifacts_args(p_build)
    p_build.add_argument('--vendor', required=True)
    p_build.add_argument('--product', required=True)
    p_build.add_argument('--version', required=True)
    p_build.add_argument('--git-commit', required=True)
    p_build.add_argument('--built-at', required=True,
                         help='RFC 3339 in UTC, e.g. 2026-10-22T08:00:00Z')
    p_build.add_argument('--publish', default='',
                         help='autopublish channels, space separated')
    p_build.add_argument('--public', action='store_true',
                         help='mark build public')
    p_build.set_defaults(func=cmd_build)

    p_plan = sub.add_parser('plan', help='print upload plan as TSV')
    add_artifacts_args(p_plan)
    p_plan.set_defaults(func=cmd_plan)

    p_poll = sub.add_parser('poll-state',
                            help='decide what to do with an artifact')
    p_poll.add_argument('json_file')
    p_poll.add_argument('--size', type=int, required=True,
                        help='declared size of the artifact file in bytes')
    p_poll.set_defaults(func=cmd_poll_state)

    p_summary = sub.add_parser('publish-summary',
                               help='explain per-channel publish decision')
    p_summary.add_argument('json_file')
    p_summary.set_defaults(func=cmd_publish_summary)

    p_limit = sub.add_parser('limit-check',
                             help='check artifact sizes against server limit')
    add_artifacts_args(p_limit)
    p_limit.add_argument('json_file')
    p_limit.set_defaults(func=cmd_limit_check)

    p_verify = sub.add_parser('verify', help='fail unless release is complete')
    p_verify.add_argument('json_file')
    p_verify.set_defaults(func=cmd_verify)

    args = parser.parse_args()
    try:
        args.func(args)
    except InputError as e:
        print(f'error: {e}', file=sys.stderr)
        sys.exit(2)


if __name__ == '__main__':
    main()
