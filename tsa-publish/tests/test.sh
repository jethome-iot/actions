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

    # UPDATE_GOLDEN=1 обновляет и отличающийся файл, а не только отсутствующий:
    # иначе после осознанной смены поведения золотые приходится удалять руками
    if [ "${UPDATE_GOLDEN:-}" = "1" ]; then
        if [ -f "${OUTFILE}" ] && diff -q "${OUTFILE}" "${TMPFILE}" >/dev/null; then
            echo "✅ PASSED: ${LABEL} matches $1"
            rm -f "${TMPFILE}"
            return 0
        fi
        local VERB="created"
        [ -f "${OUTFILE}" ] && VERB="rewrote"
        mv "${TMPFILE}" "${OUTFILE}"
        echo "📝 UPDATED: ${VERB} reference file $1 for ${LABEL}"
        return 0
    fi

    if [ ! -f "${OUTFILE}" ]; then
        echo "❌ FAILED: reference file $1 is missing for ${LABEL}" >&2
        rm -f "${TMPFILE}"
        FAILED=1
        return 1
    fi
    if ! diff -u "${OUTFILE}" "${TMPFILE}"; then
        echo "❌ FAILED: ${LABEL} does not match $1" >&2
        rm -f "${TMPFILE}"
        FAILED=1
        return 1
    fi
    echo "✅ PASSED: ${LABEL} matches $1"
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

# check_probe <script> <golden> <label> [args...] — прогнать проверку на
# заглушке из stdlib и сверить вывод с golden. Выход 77 — curl нет, проверка
# пропущена; любой другой ненулевой код — настоящая поломка, и stderr заглушки
# печатается, а не глотается: иначе сломанная проверка выглядела бы как успех.
check_probe() {
    local SCRIPT="$1"
    local OUTNAME="$2"
    local LABEL="$3"
    shift 3
    local TMPFILE TMPERR CODE
    TMPFILE=$(mktemp)
    TMPERR=$(mktemp)

    python3 -I "${SCRIPT_DIR}/${SCRIPT}" "$@" >"${TMPFILE}" 2>"${TMPERR}"
    CODE=$?
    if [ ${CODE} -eq 77 ]; then
        echo "⚠️  SKIPPED: curl not found, ${LABEL} not run"
        rm -f "${TMPFILE}" "${TMPERR}"
        return 0
    fi
    if [ ${CODE} -ne 0 ]; then
        echo "❌ FAILED: ${SCRIPT} exited ${CODE} for ${LABEL}" >&2
        cat "${TMPERR}" >&2
        cat "${TMPFILE}" >&2
        rm -f "${TMPFILE}" "${TMPERR}"
        FAILED=1
        return 1
    fi
    rm -f "${TMPERR}"
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
# нулевой артефакт сервер не принимает ('size must be greater than zero'),
# поэтому отвергаем до сети — и в build, и в plan
check_info "err-empty-artifact.out" build "${COMMON[@]}" \
    --artifacts-file fixtures/empty-artifact.artifacts
check_info "err-empty-artifact-plan.out" plan --base-dir fixtures \
    --artifacts-file fixtures/empty-artifact.artifacts
# путь с пробелом неотличим от пути + audience: ошибка должна объяснять разбор
check_info "err-space-path.out" build "${COMMON[@]}" \
    --artifacts-file fixtures/space-path.artifacts
# файл со списком артефактов не в UTF-8 — внятная ошибка, не трейсбек
check_info "err-nonutf8.out" build "${COMMON[@]}" \
    --artifacts-file fixtures/nonutf8.artifacts
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

# poll-state решает за шаг заливки: досылать, пропустить или подождать
check_info "poll-send.out" poll-state fixtures/resp-artifact-uploading.json \
    --size 131072
check_info "poll-skip.out" poll-state fixtures/resp-artifact-published.json \
    --size 4096
# все байты на сервере, но статус не принятый: досылать нечего — curl -T с
# -C >= размера вышел бы с кодом 18, не послав ни байта
check_info "poll-wait.out" poll-state fixtures/resp-artifact-full.json \
    --size 131072
# сервер держит больше, чем объявлено — тоже не повод досылать
check_info "poll-over.out" poll-state fixtures/resp-artifact-over.json \
    --size 65536
# received, который curl отвергнет как параметр -C
check_info "err-poll-received.out" poll-state \
    fixtures/resp-artifact-badreceived.json --size 131072
check_info "err-poll-status.out" poll-state \
    fixtures/resp-artifact-nostatus.json --size 131072
# нечитаемое тело: падение с кодом, который цикл обрабатывает повтором
check_info "err-poll-broken.out" poll-state fixtures/resp-broken.html --size 1

# --- допущения, на которых держатся сетевые шаги ------------------------------

# Шаг заливки полагается на Content-Range, который curl ставит сам по -C
check_probe "curl_range_probe.py" "curl-range.out" "curl resume probe"
# Ключ API уходит в curl только через конфиг-файл: проверяем экранирование
check_probe "api_key_probe.py" "api-key.out" "api key config probe"

# --- цикл заливки против заглушки протокола ----------------------------------

# Границы цикла по ответам сервера не угадываются: каждый сценарий —
# состояние, которое заглушка воспроизводит, и ожидаемое поведение скрипта
for SCENARIO in \
    fresh \
    resume \
    already-uploaded \
    rejected-422 \
    artifact-unknown \
    all-bytes-not-settled \
    all-bytes-stuck \
    broken-poll-body \
    many-parts
do
    check_probe "upload_loop_probe.py" "upload-${SCENARIO}.out" \
        "upload loop: ${SCENARIO}" "${SCENARIO}"
done

exit ${FAILED}
