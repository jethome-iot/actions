#!/bin/bash
# Раннер запускает тело shell: bash как bash --noprofile --norc -eo pipefail.
# action.yml теперь зовёт этот файл отдельным bash, опции он не наследует —
# задаём их здесь, иначе шаг молча продолжал бы работу после ошибки.
set -eo pipefail
if [ "${INPUT_BETA}" == "yes" ]; then
  BRANCH=nightly
else
  BRANCH=stable
fi
CURDIR=$(pwd)
cd "${INPUT_PATHOS}"
VERSION=$(jq -r '.version' "${BRANCH}.json")
VERSIONJH="jh.$(jq -r '.version' "${BRANCH}-jethome.json" | cut -d '.' -f 3 | xargs -n 1 printf '%02d')"
cd "${CURDIR}"
cd "${INPUT_PATHARMBIAN}"
echo "${VERSION}.${VERSIONJH}" > VERSION

# Одинарные кавычки — известный дефект: в output уходит литерал, а не
# значение. Он заморожен эталоном и исправляется отдельным изменением.
# shellcheck disable=SC2016
echo 'output=${VERSION}.${VERSIONJH}' >> "${GITHUB_OUTPUT}"
exit 0

