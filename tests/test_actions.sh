#!/bin/bash
# Прогоняет все сценарии экшенов.

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAILED=0

for scenario in "${TESTS_DIR}"/scenarios/*.env; do
    bash "${TESTS_DIR}/run_action.sh" "${scenario}" || FAILED=1
done

exit ${FAILED}
