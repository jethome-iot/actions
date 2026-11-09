#!/bin/bash
# Тесты tsa-publish без сервера: разбор входа artifacts, сборка release-info.json,
# разбор ответов сервера и поведение curl при возобновлении заливки.
#
# Раскладка:
#   golden/            — по файлу на случай, ожидаемый вывод
#   fixtures/          — только входы длиннее трёх строк, которые так читаемее
#   поддельное дерево сборки и короткие входы готовит сам этот скрипт в
#   mktemp -d и убирает по trap: держать в репозитории текстовые файлы с
#   расширением .bin незачем, да и имя врало бы про содержимое
#
# Перегенерация golden-файлов: UPDATE_GOLDEN=1 bash tsa-publish/tests/test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "${SCRIPT_DIR}")"
RELEASE_INFO="${BASE_DIR}/release_info.py"
GOLDEN_DIR="${SCRIPT_DIR}/golden"

# Пути к оставшимся фикстурам должны быть относительными, иначе golden-файлы
# зависели бы от каталога проверки
cd "${SCRIPT_DIR}" || exit 1

FAILED=0

# Рабочий каталог: поддельное дерево сборки и короткие входы.
# В golden его путь заменяется на <tmp>, чтобы не зависеть от mktemp
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tsa-publish-tests-XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT

# --- поддельное дерево сборки -------------------------------------------------

# Содержимое важно: golden-файлы держат sha256 и размеры этих файлов
mkdir -p "${WORK}/build" "${WORK}/tools"
printf 'factory image: jxd-r6-e1eth-test-selftest\n' \
    >"${WORK}/build/jxd-r6-e1eth-test-selftest.factory.bin"
printf 'ram image: jxd-r6-e1eth-test-selftest\n' \
    >"${WORK}/build/jxd-r6-e1eth-test-selftest-ram.bin"
printf 'factory image: eeprom-programmer\n' \
    >"${WORK}/build/eeprom-programmer.factory.bin"
printf 'ram image: eeprom-programmer\n' \
    >"${WORK}/build/eeprom-programmer-ram.bin"
printf 'factory image: jxd-pm380-e1eth-powermeter\n' \
    >"${WORK}/build/jxd-pm380-e1eth-powermeter.factory.bin"
printf 'ram image: jxd-pm380-e1eth-powermeter\n' \
    >"${WORK}/build/jxd-pm380-e1eth-powermeter-ram.bin"
printf 'internal selftest log\n' >"${WORK}/build/selftest-debug.log"
printf '#!/usr/bin/env python3\n# RAM loader stub used by tests\n' \
    >"${WORK}/tools/ram_load.py"
# Нулевой артефакт: сервер такой не принимает, проверяем локальный отказ
: >"${WORK}/build/empty.bin"

# --- короткие входы -----------------------------------------------------------

# write_input <имя> — содержимое со stdin
write_input() {
    cat >"${WORK}/$1"
}

write_input minimal.artifacts <<'EOF'
eeprom-programmer  factory  build/eeprom-programmer.factory.bin
EOF

write_input audience.artifacts <<'EOF'
# четвёртое поле — audience: такой файл не попадает в публичное дерево
jxd-r6-e1eth-test-selftest  factory  build/jxd-r6-e1eth-test-selftest.factory.bin
jxd-r6-e1eth-test-selftest  debuglog  build/selftest-debug.log  internal
EOF

write_input bad-arity.artifacts <<'EOF'
eeprom-programmer  factory
EOF

write_input bad-slug.artifacts <<'EOF'
eeprom-programmer  factory?raw  build/eeprom-programmer.factory.bin
EOF

write_input missing-file.artifacts <<'EOF'
eeprom-programmer  factory  build/eeprom-programmer.factory.bin
eeprom-programmer  ram  build/does-not-exist.bin
EOF

write_input dup-kind.artifacts <<'EOF'
# один и тот же (stream, kind) дважды — шаг заливки не различит артефакты
eeprom-programmer,jxd-r6-e1eth-test-selftest  loader  tools/ram_load.py
jxd-r6-e1eth-test-selftest  loader  build/eeprom-programmer-ram.bin
EOF

write_input dup-stream.artifacts <<'EOF'
eeprom-programmer,eeprom-programmer  loader  tools/ram_load.py
EOF

write_input empty.artifacts <<'EOF'
# только комментарий и пустая строка

EOF

write_input empty-artifact.artifacts <<'EOF'
# нулевой артефакт: сервер отвергает size 0, падаем до сети
eeprom-programmer  blankfs  build/empty.bin
EOF

write_input space-path.artifacts <<'EOF'
eeprom-programmer  factory  build/my file.bin
EOF

# Табуляция и не-UTF-8 — через printf: в heredoc такой байт не записать
printf 'eeprom-programmer\tfactory\tbuild/eeprom-programmer.factory.bin\n' \
    >"${WORK}/tab.artifacts"
printf 'eeprom-programmer  factory  build/\xff\xfe.bin\n' \
    >"${WORK}/nonutf8.artifacts"

# Короткие ответы сервера на запрос состояния артефакта
write_input resp-artifact-uploading.json <<'EOF'
{"streams": ["eeprom-programmer"], "kind": "ram", "status": "uploading", "size": 131072, "received": 65536}
EOF

write_input resp-artifact-published.json <<'EOF'
{"streams": ["eeprom-programmer"], "kind": "loader", "status": "published", "size": 4096, "received": 4096}
EOF

write_input resp-artifact-full.json <<'EOF'
{"streams": ["eeprom-programmer"], "kind": "ram", "status": "uploading", "size": 131072, "received": 131072}
EOF

write_input resp-artifact-over.json <<'EOF'
{"streams": ["eeprom-programmer"], "kind": "ram", "status": "uploading", "size": 65536, "received": 70000}
EOF

write_input resp-artifact-badreceived.json <<'EOF'
{"streams": ["eeprom-programmer"], "kind": "ram", "status": "uploading", "size": 131072, "received": "64 KiB"}
EOF

write_input resp-artifact-nostatus.json <<'EOF'
{"streams": ["eeprom-programmer"], "kind": "ram", "size": 131072, "received": 0}
EOF

write_input resp-broken.html <<'EOF'
<html><head><title>502 Bad Gateway</title></head></html>
EOF

# --- сверка с golden ----------------------------------------------------------

compare() {
    local OUTFILE="${GOLDEN_DIR}/$1"
    local TMPFILE="$2"
    local LABEL="$3"

    # UPDATE_GOLDEN=1 обновляет и отличающийся файл, а не только отсутствующий:
    # иначе после осознанной смены поведения золотые приходится удалять руками
    if [ "${UPDATE_GOLDEN:-}" = "1" ]; then
        mkdir -p "${GOLDEN_DIR}"
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
        echo "❌ FAILED: reference file golden/$1 is missing for ${LABEL}" >&2
        rm -f "${TMPFILE}"
        FAILED=1
        return 1
    fi
    if ! diff -u "${OUTFILE}" "${TMPFILE}"; then
        echo "❌ FAILED: ${LABEL} does not match golden/$1" >&2
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

    local RAW TMPERR TMPFILE CODE
    RAW=$(mktemp)
    TMPERR=$(mktemp)
    TMPFILE=$(mktemp)

    echo "\$ release_info.py $*" >"${RAW}"
    python3 -I "${RELEASE_INFO}" "$@" >>"${RAW}" 2>"${TMPERR}"
    CODE=$?
    if [ -s "${TMPERR}" ]; then
        echo "=== stderr ===" >>"${RAW}"
        cat "${TMPERR}" >>"${RAW}"
    fi
    echo "=== exit ${CODE} ===" >>"${RAW}"

    # Путь рабочего каталога в golden попадать не должен
    sed "s|${WORK}|<tmp>|g" "${RAW}" >"${TMPFILE}"
    rm -f "${RAW}" "${TMPERR}"

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

COMMON=(--base-dir "${WORK}" --vendor jethome --product tst-firmware-esp
        --version v1.16 --git-commit abc1234 --built-at 2026-10-22T08:00:00Z)

# --- сборка release-info.json ------------------------------------------------

# матрица прошивок ESP32: первый реальный потребитель действия
check_info "esp.json.out" build "${COMMON[@]}" \
    --artifacts-file fixtures/esp.artifacts --publish release --public
check_info "esp.plan.out" plan --base-dir "${WORK}" \
    --artifacts-file fixtures/esp.artifacts
# audience internal + несколько каналов автопубликации
check_info "audience.json.out" build "${COMMON[@]}" \
    --artifacts-file "${WORK}/audience.artifacts" \
    --publish "internal/nightly release"
# минимум: один артефакт, без publish и public — внутренняя сборка
check_info "minimal.json.out" build "${COMMON[@]}" \
    --artifacts-file "${WORK}/minimal.artifacts"

# --- ошибки во входных данных ------------------------------------------------

check_info "err-arity.out" build "${COMMON[@]}" \
    --artifacts-file "${WORK}/bad-arity.artifacts"
check_info "err-missing-file.out" build "${COMMON[@]}" \
    --artifacts-file "${WORK}/missing-file.artifacts"
check_info "err-dup-kind.out" build "${COMMON[@]}" \
    --artifacts-file "${WORK}/dup-kind.artifacts"
check_info "err-dup-stream.out" build "${COMMON[@]}" \
    --artifacts-file "${WORK}/dup-stream.artifacts"
check_info "err-empty.out" build "${COMMON[@]}" \
    --artifacts-file "${WORK}/empty.artifacts"
# нулевой артефакт сервер не принимает ('size must be greater than zero'),
# поэтому отвергаем до сети — и в build, и в plan
check_info "err-empty-artifact.out" build "${COMMON[@]}" \
    --artifacts-file "${WORK}/empty-artifact.artifacts"
check_info "err-empty-artifact-plan.out" plan --base-dir "${WORK}" \
    --artifacts-file "${WORK}/empty-artifact.artifacts"
# путь с пробелом неотличим от пути + audience: ошибка должна объяснять разбор
check_info "err-space-path.out" build "${COMMON[@]}" \
    --artifacts-file "${WORK}/space-path.artifacts"
# файл со списком артефактов не в UTF-8 — внятная ошибка, не трейсбек
check_info "err-nonutf8.out" build "${COMMON[@]}" \
    --artifacts-file "${WORK}/nonutf8.artifacts"
check_info "err-tab.out" build "${COMMON[@]}" \
    --artifacts-file "${WORK}/tab.artifacts"
check_info "err-bad-slug.out" build "${COMMON[@]}" \
    --artifacts-file "${WORK}/bad-slug.artifacts"
# версия едет в путь URL: символы вне безопасного набора отвергаем
check_info "err-bad-version.out" build --base-dir "${WORK}" --vendor jethome \
    --product tst-firmware-esp --version "v1.16/../v1.15" --git-commit abc1234 \
    --built-at 2026-10-22T08:00:00Z --artifacts-file "${WORK}/minimal.artifacts"
# версией бывает ISO-таймштамп: '+' и ':' сервер принимает, и в пути URL
# они легальны — такая версия должна проходить
check_info "iso-version.json.out" build --base-dir "${WORK}" --vendor jethome \
    --product tst-firmware-mcu --version "2025-12-23T07:05:42+00:00" \
    --git-commit abc1234 --built-at 2026-10-22T08:00:00Z \
    --artifacts-file "${WORK}/minimal.artifacts"
# версия из одних точек — это сегмент относительного пути, не релиз
check_info "err-dot-version.out" build --base-dir "${WORK}" --vendor jethome \
    --product tst-firmware-esp --version ".." --git-commit abc1234 \
    --built-at 2026-10-22T08:00:00Z --artifacts-file "${WORK}/minimal.artifacts"
check_info "err-built-at.out" build --base-dir "${WORK}" --vendor jethome \
    --product tst-firmware-esp --version v1.16 --git-commit abc1234 \
    --built-at "2026-10-22 08:00:00" --artifacts-file "${WORK}/minimal.artifacts"
check_info "err-no-vendor.out" build --base-dir "${WORK}" --vendor "" \
    --product tst-firmware-esp --version v1.16 --git-commit abc1234 \
    --built-at 2026-10-22T08:00:00Z --artifacts-file "${WORK}/minimal.artifacts"

# --- разбор ответов сервера --------------------------------------------------

check_info "publish-auto.out" publish-summary fixtures/resp-create-auto.json
check_info "publish-none.out" publish-summary fixtures/resp-create-nopublish.json

check_info "limit-ok.out" limit-check --base-dir "${WORK}" \
    --artifacts-file fixtures/esp.artifacts fixtures/resp-create-auto.json
check_info "limit-oversize.out" limit-check --base-dir "${WORK}" \
    --artifacts-file "${WORK}/minimal.artifacts" \
    fixtures/resp-create-smalllimit.json
check_info "limit-absent.out" limit-check --base-dir "${WORK}" \
    --artifacts-file "${WORK}/minimal.artifacts" \
    fixtures/resp-create-nopublish.json

check_info "verify-complete.out" verify fixtures/resp-release-complete.json
check_info "verify-incomplete.out" verify fixtures/resp-release-incomplete.json

# poll-state решает за шаг заливки: досылать, пропустить или подождать
check_info "poll-send.out" poll-state \
    "${WORK}/resp-artifact-uploading.json" --size 131072
check_info "poll-skip.out" poll-state \
    "${WORK}/resp-artifact-published.json" --size 4096
# все байты на сервере, но статус не принятый: досылать нечего — curl -T с
# -C >= размера вышел бы с кодом 18, не послав ни байта
check_info "poll-wait.out" poll-state \
    "${WORK}/resp-artifact-full.json" --size 131072
# сервер держит больше, чем объявлено — тоже не повод досылать
check_info "poll-over.out" poll-state \
    "${WORK}/resp-artifact-over.json" --size 65536
# received, который curl отвергнет как параметр -C
check_info "err-poll-received.out" poll-state \
    "${WORK}/resp-artifact-badreceived.json" --size 131072
check_info "err-poll-status.out" poll-state \
    "${WORK}/resp-artifact-nostatus.json" --size 131072
# нечитаемое тело: падение с кодом, который цикл обрабатывает повтором
check_info "err-poll-broken.out" poll-state "${WORK}/resp-broken.html" --size 1

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
