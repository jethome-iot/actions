#!/bin/bash
# Общий помощник для стабов: пишет имя программы и её argv в $ARGV_LOG.
# Формат намеренно простой и построчный — так diff эталона читаем глазами.
log_argv() {
    local prog="$1"
    shift
    {
        echo "${prog}"
        local a
        for a in "$@"; do
            printf '  [%s]\n' "${a}"
        done
    } >>"${ARGV_LOG}"
}
