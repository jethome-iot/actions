#!/bin/bash
# Раннер запускает тело shell: bash как bash --noprofile --norc -eo pipefail.
# action.yml теперь зовёт этот файл отдельным bash, опции он не наследует —
# задаём их здесь, иначе шаг молча продолжал бы работу после ошибки.
set -eo pipefail
if [ "${INPUT_BRANCH}" == "stable" ]; then
  DEPLOYFOLDER=${INPUT_HOSTPATH}
elif [ "${INPUT_BRANCH}" == "nightly" ]; then
  DEPLOYFOLDER=${INPUT_HOSTPATH}-beta
elif [ "${INPUT_BRANCH}" == "test" ]; then
  DEPLOYFOLDER=${INPUT_HOSTPATH}-test
else
  echo 'output=not_need' >> $GITHUB_OUTPUT
  exit 0
fi
echo dist: $(echo ${INPUT_DISTRO} | sed 's/,/ /g')
for dist in $(echo ${INPUT_DISTRO} | sed 's/,/ /g'); do
  ssh -o StrictHostKeyChecking=no -i ${HOME}/.ssh/${KEY_ID} ${INPUT_USER}@${INPUT_HOSTNAME} "mkdir -p ${DEPLOYFOLDER}/${dist}"
  files=$(echo "${INPUT_FILES}" | tr '\n' ' ')
  CURDIR=$(pwd)
  cd "${INPUT_PATH}"
  echo filelist: $(ls ${files})
  for file in $(ls ${files}); do
    rsync -e "ssh -o StrictHostKeyChecking=no -i ${HOME}/.ssh/${KEY_ID}" -avr ${file} ${INPUT_USER}@${INPUT_HOSTNAME}:${DEPLOYFOLDER}/${dist}
  done
  cd ${CURDIR}
done

echo 'output=ok' >> $GITHUB_OUTPUT
exit 0

