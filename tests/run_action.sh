#!/bin/bash
# Прогоняет один шаг экшена со стабами вместо внешних команд и сравнивает
# перехваченный argv с эталоном.

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_DIR="$(dirname "${TESTS_DIR}")"

SCENARIO="$1"
NAME="$(basename "${SCENARIO}" .env)"
GOLDEN="${TESTS_DIR}/argv/${NAME}.expected"

# Канонический путь: на macOS mktemp отдаёт /var/..., а pwd -P — /private/var/...
WORK="$(mktemp -d)"
WORK="$(cd "${WORK}" && pwd -P)"
trap 'rm -rf "${WORK}"' EXIT

export STUB_TMPDIR="${WORK}/tmp"
mkdir -p "${STUB_TMPDIR}"
export ARGV_LOG="${WORK}/argv.log"
export MKTEMP_COUNTER="${WORK}/mktemp.counter"
export GITHUB_OUTPUT="${WORK}/github_output"
export GITHUB_ENV="${WORK}/github_env"
: >"${ARGV_LOG}"
: >"${GITHUB_OUTPUT}"
: >"${GITHUB_ENV}"

# Песочница сценария: входные файлы, HOME. Живёт внутри WORK и убирается
# вместе с ним.
SANDBOX="${WORK}/sandbox"
mkdir -p "${SANDBOX}"
# Файлы, которые шаг пишет вместо сети (VERSION, json с версией): сценарий
# перечисляет их пути относительно песочницы, содержимое идёт в эталон.
RESULT_FILES=()

# Сценарий задаёт ACTION_DIR, STEP_ID и переменные окружения шага.
# shellcheck source=/dev/null
source "${SCENARIO}"

export GITHUB_ACTION_PATH="${REPO_DIR}/${ACTION_DIR}"
export PATH="${TESTS_DIR}/stubs:${PATH}"

SCRIPT="${REPO_DIR}/${ACTION_DIR}/scripts/${STEP_ID}.sh"
# Зовём скрипт так же, как его зовёт action.yml: bash без опций, опции
# шелла задаёт сам скрипт.
bash "${SCRIPT}" >"${WORK}/stdout" 2>&1
RC=$?

# Пути песочницы и репозитория попадают в argv (ключ ssh в HOME, файлы
# mktemp) и в каждом прогоне разные — в эталоне они заменены метками.
ACTUAL="${WORK}/actual"
{
    echo "=== exit: ${RC}"
    echo "=== argv"
    cat "${ARGV_LOG}"
    echo "=== github_output"
    cat "${GITHUB_OUTPUT}"
    echo "=== github_env"
    cat "${GITHUB_ENV}"
    for f in "${RESULT_FILES[@]+"${RESULT_FILES[@]}"}"; do
        echo "=== file: ${f}"
        cat "${SANDBOX}/${f}" 2>&1
    done
} | sed -e "s#${WORK}#<work>#g" -e "s#${REPO_DIR}#<repo>#g" >"${ACTUAL}"

if [ ! -f "${GOLDEN}" ]; then
    if [ "${UPDATE_GOLDEN:-}" = "1" ]; then
        cp "${ACTUAL}" "${GOLDEN}"
        echo "📝 UPDATED: created ${NAME}.expected"
        exit 0
    fi
    echo "❌ FAILED: reference file ${NAME}.expected is missing" >&2
    cat "${ACTUAL}" >&2
    exit 1
fi

if diff -u "${GOLDEN}" "${ACTUAL}"; then
    echo "✅ PASSED: ${NAME}"
    exit 0
fi
echo "❌ FAILED: ${NAME} does not match its golden" >&2
echo "--- stdout шага:" >&2
cat "${WORK}/stdout" >&2
exit 1
