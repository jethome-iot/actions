#!/bin/bash
# Раннер запускает тело shell: bash как bash --noprofile --norc -eo pipefail.
# action.yml теперь зовёт этот файл отдельным bash, опции он не наследует —
# задаём их здесь, иначе шаг молча продолжал бы работу после ошибки.
set -eo pipefail
# Deploy to fw storage
#          vendor.platform.project.channel.release.branch
#default: 'JetHome.j100.Armbian.nightly.jammy.edge'
if [ ! -e "${INPUT_HASHPGP_FILE}" ] ; then
  HASHPGP=$(sha256sum ${INPUT_FIRMWARE_FILE} | awk '{print $1}')
  echo "Generate sha256 hash ${HASHPGP}"
else
  HASHPGP="$(cat ${INPUT_HASHPGP_FILE})"
  echo "Use provided hash ${HASHPGP}"
fi
TMPHASH=$(mktemp)
echo "${HASHPGP}" >${TMPHASH}
for i in 1 2 3; do
  echo "Upload firmware_type=${INPUT_FULLSLUG} try $i"
  RESPONSE=$(curl --limit-rate 10M -s -H "Authorization: Bearer ${INPUT_FWUPLOAD}" \
      -F 'vendor="'${CHECKVARS_VENDOR}'"' \
      -F 'platform="'${CHECKVARS_PLATFORM}'"' \
      -F 'firmware_type="'${CHECKVARS_SLUG}'"' \
      -F 'version="'${CHECKVARS_VERSION}'"' \
      -F 'image_type="'${INPUT_IMAGE_TYPE}'"' \
      -F "hash_pgp=${HASHPGP}" \
      -F "firmware_file=@${INPUT_FIRMWARE_FILE}" \
      -F 'force_overwrite="'${INPUT_FORCE_OVERWRITE}'"' \
      "${INPUT_URL}/api/upload_firmware/") || true
  TESTERR="$(echo ${RESPONSE} | jq .success)" || true
  if [ "${TESTERR}" == "true" ]; then
    break
  fi
  sleep $((i*10))
done
rm -rf ${TMPHASH}
echo -n "Upload firmware ${INPUT_FIRMWARE_FILE}: "
if [ "$(echo ${RESPONSE} | jq .success)" == "true" ] ; then
  echo "Success"
else
  echo "Error"
  echo ${RESPONSE}
  exit 5
fi
echo 'hash<<EOF' >> $GITHUB_OUTPUT
echo "${HASHPGP}" >> $GITHUB_OUTPUT
echo 'EOF' >> $GITHUB_OUTPUT

