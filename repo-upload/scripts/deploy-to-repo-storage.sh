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
  echo 'output=not_need' >> "${GITHUB_OUTPUT}"
  exit 0
fi
# distro — список через запятую или пробел.
read -r -d '' -a DISTS <<<"${INPUT_DISTRO//,/ }" || true
# files — шаблоны имён через перевод строки или пробел.
read -r -d '' -a PATTERNS <<<"${INPUT_FILES}" || true
echo "dist: ${DISTS[*]}"
for dist in "${DISTS[@]}"; do
  ssh -o StrictHostKeyChecking=no -i "${HOME}/.ssh/${KEY_ID}" "${INPUT_USER}@${INPUT_HOSTNAME}" "mkdir -p ${DEPLOYFOLDER}/${dist}"
  CURDIR=$(pwd)
  cd "${INPUT_PATH}"
  # Совпадения всех шаблонов одним отсортированным списком, как их выдавал
  # ls; шаблон без совпадений ничего не добавляет.
  mapfile -t FILELIST < <(
    for pattern in "${PATTERNS[@]}"; do
      compgen -G "${pattern}" || true
    done | sort
  )
  echo "filelist: ${FILELIST[*]}"
  for file in "${FILELIST[@]}"; do
    rsync -e "ssh -o StrictHostKeyChecking=no -i ${HOME}/.ssh/${KEY_ID}" -avr "${file}" "${INPUT_USER}@${INPUT_HOSTNAME}:${DEPLOYFOLDER}/${dist}"
  done
  cd "${CURDIR}"
done

echo 'output=ok' >> "${GITHUB_OUTPUT}"
exit 0
