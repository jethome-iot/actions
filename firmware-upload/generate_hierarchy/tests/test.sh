#!/bin/bash

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "${SCRIPT_DIR}")"

FAILED=0

check_main() {
    local FULLSLUG="$1"
    local OUTFILE="${SCRIPT_DIR}/$2"

    local ARGS
    ARGS=$(echo "${FULLSLUG}" | sed 's/\./ /g' | sed 's/\//-/g')

    local TMPFILE
    TMPFILE=$(mktemp)
    echo "${FULLSLUG}" >"${TMPFILE}"
    python3 "${BASE_DIR}/main.py" ${ARGS} >>"${TMPFILE}"

    if [ -f "${OUTFILE}" ]; then
        if ! diff -u "${OUTFILE}" "${TMPFILE}"; then
            echo "❌ FAILED: ${FULLSLUG} does not match $2" >&2
            rm -f "${TMPFILE}"
            FAILED=1
            return 1
        else
            echo "✅ PASSED: ${FULLSLUG} matches $2"
        fi
    else
        if [ "${UPDATE_GOLDEN:-}" = "1" ]; then
            mv "${TMPFILE}" "${OUTFILE}"
            echo "📝 UPDATED: created reference file $2 for ${FULLSLUG}"
            return 0
        else
            echo "❌ FAILED: reference file $2 is missing for ${FULLSLUG}" >&2
            rm -f "${TMPFILE}"
            FAILED=1
            return 1
        fi
    fi

    rm -f "${TMPFILE}"
}

check_main "JetHome.j100.Armbian.release.bookworm.edge" "test1.out"
check_main "JetHome.j100.Armbian.release.bookworm.cli.edge" "test1cli.out"
check_main "JetHome.jxd.firmware.espjhome.stand" "test2.out"
check_main "JetHome.j100.ArmbianHA.nightly" "test3.out"
check_main "JetHome.j100.magicos.release" "test4.out"
check_main "JetHome.j80.jhaos.release" "test5.out"
check_main "JetHome.j80.BurnTools" "test6.out"
check_main "JetHome.j100.magicos.nightly" "test7.out"
check_main "JetHome.jxd.firmware.espjhome.jxd-r6-e1eth-lcd.stand" "test8.out"
check_main "JetHome.jxd.firmware.jespfw.stand" "test9.out"
check_main "JetHome.j100.jhrescueos.release" "test10.out"
check_main "JetHome.j100.jhrescueos.nightly" "test11.out"
check_main "JetHome.j100.Armbian.release.bookworm.kde-plasma.edge" "test12.out"
check_main "JetHome.j100.Armbian.nightly.trixie.gnome.current" "test13.out"
check_main "JetHome.jxd.firmware.esphome.release" "test14.out"
check_main "JetHome.jxd.firmware.esphome.nightly" "test15.out"

exit ${FAILED}
