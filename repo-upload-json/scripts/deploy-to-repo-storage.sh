#!/bin/bash
# Раннер запускает тело shell: bash как bash --noprofile --norc -eo pipefail.
# action.yml теперь зовёт этот файл отдельным bash, опции он не наследует —
# задаём их здесь, иначе шаг молча продолжал бы работу после ошибки.
set -eo pipefail
if [ "${INPUT_NIGHTLY}" == "yes" ]; then
  DEBSDIR=debs-beta
else
  DEBSDIR=debs
fi
#if [ "${INPUT_STABLE}" == "no" ]; then
#  DEPLOYFOLDER=${INPUT_HOSTPATH}
#elif [ "${INPUT_BRANCH}" == "yes" ]; then
#  DEPLOYFOLDER=${INPUT_HOSTPATH}-beta
#elif [ "${INPUT_BRANCH}" == "test" ]; then
#  DEPLOYFOLDER=${INPUT_HOSTPATH}-test
#else
#  echo 'output=not_need' >> $GITHUB_OUTPUT
#  exit 0
#fi
DEPLOYFOLDER=${INPUT_HOSTPATH}/${INPUT_TARGET}

# Process all artifacts - relative_deb_path already contains correct subpath
# Examples:
#   armbian -> linux-image.deb (no subpath)
#   armbian-extra/noble-utils -> extra/noble-utils/base-files.deb (has subpath)
for row in $(cat "${INPUT_JSON}" | jq -r '.[] | @base64'); do
  _jq() {
    echo "${row}" | base64 --decode | jq -r "${1}"
  }
  for file in $(_jq '.debs' | jq -r '.[] | @base64'); do
    _jqq() {
      echo "${file}" | base64 --decode | jq -r "${1}"
    }
    FF=$(_jqq '.relative_deb_path')
    if [ -f "output/${DEBSDIR}/${FF}" ]; then
      # Create target directory if path contains subdirectory
      SUBDIR=$(dirname "${FF}")
      if [[ "${SUBDIR}" != "." ]]; then
        ssh -o StrictHostKeyChecking=no -i "${HOME}/.ssh/${KEY_ID}" "${INPUT_USER}@${INPUT_HOSTNAME}" "mkdir -p ${DEPLOYFOLDER}/${SUBDIR}"
      fi
      # Upload file preserving relative path structure
      rsync -e "ssh -o StrictHostKeyChecking=no -i ${HOME}/.ssh/${KEY_ID}" -avr "output/${DEBSDIR}/${FF}" "${INPUT_USER}@${INPUT_HOSTNAME}:${DEPLOYFOLDER}/${FF}"
    fi
  done
done

echo 'output=ok' >> "${GITHUB_OUTPUT}"
exit 0

