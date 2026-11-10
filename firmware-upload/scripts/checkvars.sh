#!/bin/bash
# Раннер запускает тело shell: bash как bash --noprofile --norc -eo pipefail.
# action.yml теперь зовёт этот файл отдельным bash, опции он не наследует —
# задаём их здесь, иначе шаг молча продолжал бы работу после ошибки.
set -eo pipefail
# Check date & version specified
# Check date specified or use current date
if [ -z ${INPUT_DATE} ] ; then
  DATE="$(date -Iseconds)"
else
  DATE="${INPUT_DATE}"
fi
# Check version specified or use date as version
if [ -z ${INPUT_VERSION} ] ; then
  VERSION="${DATE}"
else
  VERSION="${INPUT_VERSION}"
  # change all non-alpabet characters from VERSION to '-'
  VERSION="$(echo ${VERSION} | sed 's/[^a-zA-Z0-9._-]/-/g')"
fi

#          vendor.platform.project.channel.release.branch
#default: 'JetHome.j100.Armbian.nightly.jammy.edge'
read VENDOR SLUGWOVENDOR   <<<"$(echo ${INPUT_FULLSLUG} | sed 's/\./ /')"
read PLATFORM SLUG <<<"$(echo ${SLUGWOVENDOR} | sed 's/\./ /')"
echo "vendor=${VENDOR}" >> $GITHUB_OUTPUT
echo "platform=${PLATFORM}" >> $GITHUB_OUTPUT
echo "slug=${SLUG}" >> $GITHUB_OUTPUT

echo "date=${DATE}" >> $GITHUB_OUTPUT
echo "version=${VERSION}" >> $GITHUB_OUTPUT
echo "checkvars ok"


