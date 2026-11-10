#!/bin/bash
# Раннер запускает тело shell: bash как bash --noprofile --norc -eo pipefail.
# action.yml теперь зовёт этот файл отдельным bash, опции он не наследует —
# задаём их здесь, иначе шаг молча продолжал бы работу после ошибки.
set -eo pipefail
# Apply fw template
TMPJSON=$(mktemp)
cd "${GITHUB_ACTION_PATH}/generate_hierarchy"
ARGS=$(echo ${INPUT_FULLSLUG}| sed 's/\./ /g'| sed 's/\//-/g')
echo "=== ARGS: ${ARGS} ==="
python3 main.py ${ARGS}
HIERARCHY=$(python3 main.py ${ARGS})
echo "hier generated"

echo "|+++++++++++++++++++++++++++++++++++++++++|"
echo ${HIERARCHY}
echo "|+++++++++++++++++++++++++++++++++++++++++|"
echo ${HIERARCHY} > ${TMPJSON}
echo Add category to fw
RESPONSE=$(curl -s -H "Authorization: Bearer ${INPUT_FWUPLOAD}" \
    -F "import_file=@${TMPJSON}" \
    -F 'commit="true"' \
    "${INPUT_URL}/api/import_hierarchy/")
rm -rf ${TMPJSON}
if [ "$(echo ${RESPONSE} | jq .success)" == "true" ]; then
  echo "Category add to storage: Success"
else
  echo "Category add to storage: Error"
  echo ${RESPONSE}
  exit 1
fi

