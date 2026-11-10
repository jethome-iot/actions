#!/bin/bash
# Раннер запускает тело shell: bash как bash --noprofile --norc -eo pipefail.
# action.yml теперь зовёт этот файл отдельным bash, опции он не наследует —
# задаём их здесь, иначе шаг молча продолжал бы работу после ошибки.
set -eo pipefail
# Check date & version specified
# Check date specified or use current date
# Значение из одних пробелов считается пустым, как и при прежней проверке
# [ -z ${X} ] без кавычек.
if [ -z "${INPUT_DATE//[[:space:]]/}" ] ; then
  DATE="$(date -Iseconds)"
else
  DATE="${INPUT_DATE}"
fi
# Check version specified or use date as version
if [ -z "${INPUT_VERSION//[[:space:]]/}" ] ; then
  VERSION="${DATE}"
else
  # Пробелы по краям срезаются, серии пробелов сжимаются до одного — как
  # раньше при echo без кавычек.
  read -r -d '' -a VERSION_WORDS <<<"${INPUT_VERSION}" || true
  # change all non-alpabet characters from VERSION to '-'
  VERSION="$(echo "${VERSION_WORDS[*]}" | sed 's/[^a-zA-Z0-9._-]/-/g')"
fi

#          vendor.platform.project.channel.release.branch
#default: 'JetHome.j100.Armbian.nightly.jammy.edge'
read -r VENDOR SLUGWOVENDOR   <<<"$(echo "${INPUT_FULLSLUG}" | sed 's/\./ /')"
read -r PLATFORM SLUG <<<"$(echo "${SLUGWOVENDOR}" | sed 's/\./ /')"
echo "vendor=${VENDOR}" >> "${GITHUB_OUTPUT}"
echo "platform=${PLATFORM}" >> "${GITHUB_OUTPUT}"
echo "slug=${SLUG}" >> "${GITHUB_OUTPUT}"

echo "date=${DATE}" >> "${GITHUB_OUTPUT}"
echo "version=${VERSION}" >> "${GITHUB_OUTPUT}"
echo "checkvars ok"

