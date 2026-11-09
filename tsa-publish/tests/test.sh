#!/bin/bash
# Тесты tsa-publish без сервера: разбор входа artifacts, сборка release-info.json,
# разбор ответов сервера и поведение curl при возобновлении заливки.
# Перегенерация golden-файлов: UPDATE_GOLDEN=1 bash tsa-publish/tests/test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "${SCRIPT_DIR}")"
RELEASE_INFO="${BASE_DIR}/release_info.py"

# Пути в аргументах и в сообщениях об ошибках должны быть относительными,
# иначе golden-файлы зависели бы от каталога проверки
cd "${SCRIPT_DIR}" || exit 1

FAILED=0

compare() {
    local OUTFILE="${SCRIPT_DIR}/$1"
    local TMPFILE="$2"
    local LABEL="$3"

    if [ -f "${OUTFILE}" ]; then
        if ! diff -u "${OUTFILE}" "${TMPFILE}"; then
            echo "❌ FAILED: ${LABEL} does not match $1" >&2
            rm -f "${TMPFILE}"
            FAILED=1
            return 1
        fi
        echo "✅ PASSED: ${LABEL} matches $1"
    else
        if [ "${UPDATE_GOLDEN:-}" = "1" ]; then
            mv "${TMPFILE}" "${OUTFILE}"
            echo "📝 UPDATED: created reference file $1 for ${LABEL}"
            return 0
        fi
        echo "❌ FAILED: reference file $1 is missing for ${LABEL}" >&2
        rm -f "${TMPFILE}"
        FAILED=1
        return 1
    fi
    rm -f "${TMPFILE}"
}

# check_info <golden> <args...> — запустить release_info.py и сверить
# stdout, stderr и код возврата с golden-файлом
check_info() {
    local OUTNAME="$1"
    shift

    local TMPFILE TMPERR CODE
    TMPFILE=$(mktemp)
    TMPERR=$(mktemp)

    echo "\$ release_info.py $*" >"${TMPFILE}"
    python3 -I "${RELEASE_INFO}" "$@" >>"${TMPFILE}" 2>"${TMPERR}"
    CODE=$?
    if [ -s "${TMPERR}" ]; then
        echo "=== stderr ===" >>"${TMPFILE}"
        cat "${TMPERR}" >>"${TMPFILE}"
    fi
    echo "=== exit ${CODE} ===" >>"${TMPFILE}"
    rm -f "${TMPERR}"

    compare "${OUTNAME}" "${TMPFILE}" "release_info.py $1"
}

# check_probe <script> <golden> <label> — прогнать проверку на заглушке
# из stdlib и сверить вывод с golden. Выход 77 — curl нет, проверка пропущена.
check_probe() {
    local SCRIPT="$1"
    local OUTNAME="$2"
    local LABEL="$3"
    local TMPFILE CODE
    TMPFILE=$(mktemp)

    python3 -I "${SCRIPT_DIR}/${SCRIPT}" >"${TMPFILE}" 2>/dev/null
    CODE=$?
    if [ ${CODE} -eq 77 ]; then
        echo "⚠️  SKIPPED: curl not found, ${LABEL} not run"
        rm -f "${TMPFILE}"
        return 0
    fi
    if [ ${CODE} -ne 0 ]; then
        echo "❌ FAILED: ${SCRIPT} exited ${CODE}" >&2
        cat "${TMPFILE}" >&2
        rm -f "${TMPFILE}"
        FAILED=1
        return 1
    fi
    compare "${OUTNAME}" "${TMPFILE}" "${LABEL}"
}

COMMON=(--base-dir fixtures --vendor jethome --product tst-firmware-esp
        --version v1.16 --git-commit abc1234 --built-at 2026-10-22T08:00:00Z)

# --- сборка release-info.json ------------------------------------------------

# матрица прошивок ESP32: первый реальный потребитель действия
check_info "esp.json.out" build "${COMMON[@]}" \
    --artifacts-file fixtures/esp.artifacts --publish release --public
check_info "esp.plan.out" plan --base-dir fixtures \
    --artifacts-file fixtures/esp.artifacts
# audience internal + несколько каналов автопубликации
check_info "audience.json.out" build "${COMMON[@]}" \
    --artifacts-file fixtures/audience.artifacts --publish "internal/nightly release"
# минимум: один артефакт, без publish и public — внутренняя сборка
check_info "minimal.json.out" build "${COMMON[@]}" \
    --artifacts-file fixtures/minimal.artifacts

# --- ошибки во входных данных ------------------------------------------------

check_info "err-arity.out" build "${COMMON[@]}" \
    --artifacts-file fixtures/bad-arity.artifacts
check_info "err-missing-file.out" build "${COMMON[@]}" \
    --artifacts-file fixtures/missing-file.artifacts
check_info "err-dup-kind.out" build "${COMMON[@]}" \
    --artifacts-file fixtures/dup-kind.artifacts
check_info "err-dup-stream.out" build "${COMMON[@]}" \
    --artifacts-file fixtures/dup-stream.artifacts
check_info "err-empty.out" build "${COMMON[@]}" \
    --artifacts-file fixtures/empty.artifacts
check_info "err-tab.out" build "${COMMON[@]}" \
    --artifacts-file fixtures/tab.artifacts
check_info "err-bad-slug.out" build "${COMMON[@]}" \
    --artifacts-file fixtures/bad-slug.artifacts
# версия едет в путь URL: символы вне безопасного набора отвергаем
check_info "err-bad-version.out" build --base-dir fixtures --vendor jethome \
    --product tst-firmware-esp --version "v1.16/../v1.15" --git-commit abc1234 \
    --built-at 2026-10-22T08:00:00Z --artifacts-file fixtures/minimal.artifacts
# версией бывает ISO-таймштамп: '+' и ':' сервер принимает, и в пути URL
# они легальны — такая версия должна проходить
check_info "iso-version.json.out" build --base-dir fixtures --vendor jethome \
    --product tst-firmware-mcu --version "2025-12-23T07:05:42+00:00" \
    --git-commit abc1234 --built-at 2026-10-22T08:00:00Z \
    --artifacts-file fixtures/minimal.artifacts
# версия из одних точек — это сегмент относительного пути, не релиз
check_info "err-dot-version.out" build --base-dir fixtures --vendor jethome \
    --product tst-firmware-esp --version ".." --git-commit abc1234 \
    --built-at 2026-10-22T08:00:00Z --artifacts-file fixtures/minimal.artifacts
check_info "err-built-at.out" build --base-dir fixtures --vendor jethome \
    --product tst-firmware-esp --version v1.16 --git-commit abc1234 \
    --built-at "2026-10-22 08:00:00" --artifacts-file fixtures/minimal.artifacts
check_info "err-no-vendor.out" build --base-dir fixtures --vendor "" \
    --product tst-firmware-esp --version v1.16 --git-commit abc1234 \
    --built-at 2026-10-22T08:00:00Z --artifacts-file fixtures/minimal.artifacts

# --- разбор ответов сервера --------------------------------------------------

check_info "publish-auto.out" publish-summary fixtures/resp-create-auto.json
check_info "publish-none.out" publish-summary fixtures/resp-create-nopublish.json

check_info "limit-ok.out" limit-check --base-dir fixtures \
    --artifacts-file fixtures/esp.artifacts fixtures/resp-create-auto.json
check_info "limit-oversize.out" limit-check --base-dir fixtures \
    --artifacts-file fixtures/minimal.artifacts fixtures/resp-create-smalllimit.json
check_info "limit-absent.out" limit-check --base-dir fixtures \
    --artifacts-file fixtures/minimal.artifacts fixtures/resp-create-nopublish.json

check_info "verify-complete.out" verify fixtures/resp-release-complete.json
check_info "verify-incomplete.out" verify fixtures/resp-release-incomplete.json

check_info "field-status.out" field fixtures/resp-artifact-uploading.json status
check_info "field-received.out" field fixtures/resp-artifact-uploading.json received
check_info "field-published.out" field fixtures/resp-artifact-published.json status
check_info "field-default.out" field fixtures/resp-artifact-published.json \
    received --default 0
check_info "field-absent.out" field fixtures/resp-create-nopublish.json publish \
    --default none
check_info "field-no-key.out" field fixtures/resp-create-nopublish.json publish

# --- допущения, на которых держатся сетевые шаги ------------------------------

# Шаг заливки полагается на Content-Range, который curl ставит сам по -C
check_probe "curl_range_probe.py" "curl-range.out" "curl resume probe"
# Ключ API уходит в curl только через конфиг-файл: проверяем экранирование
check_probe "api_key_probe.py" "api-key.out" "api key config probe"

exit ${FAILED}
