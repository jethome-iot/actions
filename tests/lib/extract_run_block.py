#!/usr/bin/python3
"""Достаёт тело run-блока из composite action.yml.

Временная обвязка: нужна, пока shell живёт внутри action.yml. После выноса
скриптов в scripts/*.sh драйвер зовёт их напрямую, и этот файл удаляется.
PyYAML не используем — в проекте только стандартная библиотека.
"""
import re
import sys


def extract(path, step_id):
    with open(path, encoding='utf-8') as f:
        lines = f.read().split('\n')
    current_id = None
    i = 0
    while i < len(lines):
        m = re.match(r'^\s*id:\s*(\S+)\s*$', lines[i])
        if m:
            current_id = m.group(1)
        m = re.match(r'^(\s*)run:\s*\|\s*$', lines[i])
        if m and current_id == step_id:
            indent = len(m.group(1)) + 2
            i += 1
            body = []
            while i < len(lines):
                line = lines[i]
                if line.strip() and len(line) - len(line.lstrip()) < indent:
                    break
                body.append(line[indent:] if len(line) >= indent else '')
                i += 1
            return '\n'.join(body)
        i += 1
    raise SystemExit(f"step '{step_id}' with a literal run block not found in {path}")


def substitute(body):
    """Заменяет выражения GitHub на обращения к переменным окружения.

    Правила подстановки совпадают с теми, по которым Task 5-6 переносят код
    в скрипты, — поэтому имена переменных здесь и там одинаковые.
    """
    body = re.sub(r'\$\{\{\s*inputs\.([A-Za-z0-9_]+)\s*\}\}',
                  lambda m: '${INPUT_' + m.group(1).upper() + '}', body)
    body = re.sub(r'\$\{\{\s*steps\.([A-Za-z0-9_-]+)\.outputs\.([A-Za-z0-9_]+)\s*\}\}',
                  lambda m: '${' + m.group(1).replace('-', '_').upper() + '_' + m.group(2).upper() + '}', body)
    body = re.sub(r'\$\{\{\s*github\.action_path\s*\}\}', '${GITHUB_ACTION_PATH}', body)
    body = re.sub(r'\$\{\{\s*env\.RANDOM\s*\}\}', '${KEY_ID}', body)
    return body


if __name__ == '__main__':
    print(substitute(extract(sys.argv[1], sys.argv[2])))
