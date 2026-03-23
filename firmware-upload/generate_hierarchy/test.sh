#!/bin/bash

set -uo pipefail

check_main() {
    local FULLSLUG="$1"
    local OUTFILE="$2"

    local ARGS
    ARGS=$(echo "${FULLSLUG}" | sed 's/\./ /g' | sed 's/\//-/g')

    local TMPFILE
    TMPFILE=$(mktemp)
    echo "${FULLSLUG}" >"${TMPFILE}"
    python3 ./main.py ${ARGS} >>"${TMPFILE}"

    if [ -f "${OUTFILE}" ]; then
        if ! diff -u "${OUTFILE}" "${TMPFILE}"; then
            echo "❌ FAILED: ${FULLSLUG} does not match ${OUTFILE}" >&2
            rm -f "${TMPFILE}"
            return 1
        else
            echo "✅ PASSED: ${FULLSLUG} matches ${OUTFILE}"
        fi
    else
        echo "⚠️  No reference file ${OUTFILE}; output below:"
        cat "${TMPFILE}"
    fi

    rm -f "${TMPFILE}"
}

# Примеры вызова:
# check_main "JetHome.j100.Armbian.release.bookworm.edge" "test1.out"
# check_main "Another.Fullslug.Value" "another_test.out"

# Для тестов:
check_main "JetHome.j100.Armbian.release.bookworm.edge" "test1.out"
check_main "JetHome.j100.Armbian.release.bookworm.cli.edge" "test1cli.out"

# old
#check_main "JetHome.jxd.espjhome.release" "test3.out"

check_main "JetHome.jxd.firmware.espjhome.stand" "test2.out"

check_main "JetHome.j100.ArmbianHA.nightly" "test3.out"

check_main "JetHome.j100.magicos.release" "test4.out"

check_main "JetHome.j80.jhaos.release" "test5.out"

check_main "JetHome.j80.BurnTools" "test6.out"

check_main "JetHome.j100.magicos.nightly" "test7.out"

check_main "JetHome.jxd.firmware.espjhome.jxd-r6-e1eth-lcd.stand" "test8.out"

check_main "JetHome.jxd.firmware.jespfw.stand" "test9.out"
