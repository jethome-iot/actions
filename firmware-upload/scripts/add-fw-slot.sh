#!/bin/bash
# Раннер запускает тело shell: bash как bash --noprofile --norc -eo pipefail.
# action.yml теперь зовёт этот файл отдельным bash, опции он не наследует —
# задаём их здесь, иначе шаг молча продолжал бы работу после ошибки.
set -eo pipefail
# Необязательные поля curl — массив: каждый элемент отдельный аргумент.
# Строка с кавычками, раскрытая без кавычек, ломалась на пробеле в значении.
# Значение из одних пробелов считается пустым, как и при прежней проверке
# [ -z ${X} ] без кавычек.
EXTRA_ARGS=()
if [ -n "${INPUT_SUPPORTED_DEVICES//[[:space:]]/}" ] ; then
  EXTRA_ARGS+=(-F "supported_devices=\"${INPUT_SUPPORTED_DEVICES}\"")
fi
echo "Create firmware slot ${CHECKVARS_VENDOR}.${CHECKVARS_PLATFORM}.${CHECKVARS_SLUG} ${EXTRA_ARGS[*]}"
if [ -n "${INPUT_CHANGELOG_FILE//[[:space:]]/}" ] ; then
  EXTRA_ARGS+=(-F "changelog_file=@${INPUT_CHANGELOG_FILE}")
fi

if [ "${INPUT_GENERATEFIRMWARESLOT}" == "true" ]; then
  RESPONSE=$(curl -s -H "Authorization: Bearer ${INPUT_FWUPLOAD}" \
      -F "vendor=\"${CHECKVARS_VENDOR}\"" \
      -F "platform=\"${CHECKVARS_PLATFORM}\"" \
      -F "firmware_type=\"${CHECKVARS_SLUG}\"" \
      -F "version=\"${CHECKVARS_VERSION}\"" \
      -F "release_date=\"${CHECKVARS_DATE}\"" \
      -F "update_latest_ref=${INPUT_UPDATE_LATEST}" \
      -F "force_overwrite=true" \
      "${EXTRA_ARGS[@]}" \
      "${INPUT_URL}/api/create_firmware/")
  echo -n "Create firmware slot: "
  if [ "$(echo "${RESPONSE}" | jq .success)" == "true" ]; then
    echo "Success"
  else
    echo "Error"
    echo "${RESPONSE}"
  fi
fi
