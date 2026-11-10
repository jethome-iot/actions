#!/bin/bash
# Прогоняет все сценарии экшенов.
#
# Раннер запускает шаг тем bash, что найдётся первым: на Linux это обычно
# /bin/bash, на macOS по PATH может стоять новый bash при системном 3.2.
# Скрипты обязаны работать под обоими, поэтому если /bin/bash другой
# старшей версии, чем bash по PATH, каждый сценарий идёт под обоими.

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAILED=0

INTERPRETERS=(bash)
# Одинарные кавычки намеренно: версию печатает проверяемый интерпретатор.
# shellcheck disable=SC2016
major() { "$1" -c 'echo "${BASH_VERSINFO[0]}"' 2>/dev/null; }
if [ -x /bin/bash ] && [ "$(major /bin/bash)" != "$(major bash)" ]; then
    INTERPRETERS+=(/bin/bash)
fi

for interpreter in "${INTERPRETERS[@]}"; do
    # shellcheck disable=SC2016
    echo "=== bash: ${interpreter} ($("${interpreter}" -c 'echo "${BASH_VERSION}"'))"
    for scenario in "${TESTS_DIR}"/scenarios/*.env; do
        ACTION_BASH="${interpreter}" bash "${TESTS_DIR}/run_action.sh" "${scenario}" || FAILED=1
    done
done

exit ${FAILED}
