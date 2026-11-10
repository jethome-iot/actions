#!/bin/bash
# Раннер запускает тело shell: bash как bash --noprofile --norc -eo pipefail.
# action.yml теперь зовёт этот файл отдельным bash, опции он не наследует —
# задаём их здесь, иначе шаг молча продолжал бы работу после ошибки.
set -eo pipefail

temp=$(mktemp)

if [ -z "${INPUT_OVERRIDE}" ]; then
  VERMAJ="$(jq -r '.version' "${INPUT_FILE}" | cut -d '.' -f 1)"
  VERMIN="$(jq -r '.version' "${INPUT_FILE}" | cut -d '.' -f 2)"
  if [ "${INPUT_TYPE}" == "major" ]; then
    field=${VERMAJ}
  else
    field=${VERMIN}
  fi

  if [ "${INPUT_DO}" == "inc" ]; then
    field=$((field+1))
  else 
    if [ "${INPUT_DO}" == "dec" ]; then
      field=$((field-1))
    else
      field=0
    fi
  fi
  if [ "${INPUT_TYPE}" == "major" ]; then
    VERMAJ=${field}
  else
    VERMIN=${field}
  fi

  VER="${VERMAJ}.${VERMIN}"

else
  VER=${INPUT_OVERRIDE}

fi

cat "${INPUT_FILE}" | jq ".version |= \"${VER}\"" > "${temp}"
mv "${temp}" "${INPUT_FILE}"
rm -f "${temp}"

echo "Set version ${VER} cat file $(cat "${INPUT_FILE}")"
# Одинарные кавычки — известный дефект: в output уходит литерал, а не
# значение. Он заморожен эталоном и исправляется отдельным изменением.
# shellcheck disable=SC2016
echo 'output=${VER}' >> "${GITHUB_OUTPUT}"
exit 0

