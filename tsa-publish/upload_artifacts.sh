#!/bin/bash
# Заливка артефактов релиза с возобновлением.
#
# Вынесено из action.yml отдельным скриптом, чтобы цикл повторов можно было
# прогнать тестом против заглушки сервера: именно здесь живут границы, которые
# по ответам сервера не угадываются (см. tests/upload_loop_probe.py).
#
# Ожидает в окружении:
#   TSA_BASE         базовый адрес API
#   TSA_VERSION      версия релиза
#   TSA_RUN_DIR      рабочий каталог (там же пишется ответ сервера и счётчик)
#   TSA_HELPER       путь к release_info.py
#   TSA_CURL_CFG     конфиг curl с ключом API
#   TSA_RETRY_DELAY  пауза между повторами, секунды
#   TSA_MAX_FAILURES бюджет неудач подряд на артефакт (по умолчанию 5)
# Аргумент: файл плана заливки (вывод `release_info.py plan`).

set -euo pipefail

PLAN="$1"
MAX_FAILURES="${TSA_MAX_FAILURES:-5}"
BODY="${TSA_RUN_DIR}/artifact-response.json"
ACCEPTED=0

# Таймауты обязательны: без них полуоткрытое соединение или встающая на
# гигабайте заливка висят до таймаута всего задания, и цикл возобновления —
# ради которого всё это написано — не получает шанса сработать.
# --max-time здесь не годится: законная заливка 1.5 ГБ идёт долго. Обрыв
# ловим по скорости: меньше 1 байта в секунду на протяжении минуты.
CURL_COMMON=(--config "${TSA_CURL_CFG}" -sS --no-progress-meter
             --connect-timeout 30 --speed-limit 1 --speed-time 60)

# Короткие запросы состояния ограничиваем и по общему времени
CURL_POLL=("${CURL_COMMON[@]}" --max-time 120)

# curl не обнуляет файл из -o, если упал до передачи: без этого в лог уехал бы
# предыдущий ответ сервера как будто это ответ на текущий запрос
blank_body() {
    : > "${BODY}"
}

# ARTIFACT_PATH, а не PATH: затирать PATH нельзя.
# План читаем с дескриптора 3, чтобы curl не дотянулся до него через stdin.
while IFS=$'\t' read -r STREAM KIND ARTIFACT_PATH FILE SIZE <&3; do
    [ -n "${STREAM:-}" ] || continue
    if ! [[ "${SIZE:-}" =~ ^[0-9]+$ ]]; then
        echo "error: upload plan line for ${FILE:-?} has no usable size field"
        exit 1
    fi
    ART_URL="${TSA_BASE}/releases/${TSA_VERSION}/artifact?stream=${STREAM}&kind=${KIND}"
    echo "--- ${FILE} (stream ${STREAM}, kind ${KIND}, ${SIZE} bytes)"

    OK=0
    FAILURES=0
    LAST_RECEIVED=-1
    # Понадобятся в итоговом сообщении, даже если ни один опрос не удался
    STATUS="unknown"
    while [ "${FAILURES}" -lt "${MAX_FAILURES}" ]; do
        # Пауза перед повтором, а не после последней попытки
        if [ "${FAILURES}" -gt 0 ]; then
            sleep "${TSA_RETRY_DELAY}"
        fi

        # Состояние перечитываем перед каждой попыткой: сервер отдаёт
        # фактический received, и только от него можно продолжать — часть с
        # разрывом последовательности он отклоняет
        blank_body
        CODE="$(curl "${CURL_POLL[@]}" -o "${BODY}" -w '%{http_code}' \
            "${ART_URL}")" || CODE="000"
        if [ "${CODE}" != "200" ]; then
            echo "  artifact status request returned HTTP ${CODE}"
            cat "${BODY}" || true
            FAILURES=$((FAILURES + 1))
            continue
        fi

        # Нечитаемое тело с кодом 200 (страница ошибки от прокси или CDN) —
        # это повод повторить, а не обрушить шаг: подстановка в присваивании
        # под set -e убила бы оболочку в обход всего цикла повторов
        if ! STATE="$(python3 -I "${TSA_HELPER}" poll-state "${BODY}" \
                --size "${SIZE}")"; then
            echo "  cannot read artifact state from the response"
            FAILURES=$((FAILURES + 1))
            continue
        fi
        read -r ACTION RECEIVED STATUS <<<"${STATE}"

        if [ "${ACTION}" = "skip" ]; then
            # Такой статус приходит и сразу после создания релиза, если файл
            # с тем же sha256 у сервера уже есть (дедупликация)
            echo "  already ${STATUS} on the server, upload skipped"
            OK=1
            break
        fi

        # Прогресс обнуляет бюджет неудач: файл, который сервер принимает
        # больше чем за MAX_FAILURES частей, иначе не дозалился бы никогда
        if [ "${RECEIVED}" -gt "${LAST_RECEIVED}" ]; then
            FAILURES=0
        else
            FAILURES=$((FAILURES + 1))
        fi
        LAST_RECEIVED="${RECEIVED}"

        if [ "${ACTION}" = "wait" ]; then
            # Сервер держит все байты, но статус ещё не принятый: он считает
            # sha256 при приёме последней части. Досылать нечего — curl -T с
            # -C >= размера вышел бы с кодом 18, не послав ни байта
            echo "  server holds all ${RECEIVED} byte(s), waiting for it to settle (status ${STATUS})"
            continue
        fi

        echo "  status ${STATUS}, ${RECEIVED} byte(s) on the server, sending from there"
        # -C 0 curl трактует как «файл целиком» и Content-Range не ставит,
        # поэтому отдельная ветка для пустого артефакта не нужна
        blank_body
        CODE="$(curl "${CURL_COMMON[@]}" -o "${BODY}" -w '%{http_code}' \
            -H 'Content-Type: application/octet-stream' \
            -T "${ARTIFACT_PATH}" -C "${RECEIVED}" "${ART_URL}")" || CODE="000"

        case "${CODE}" in
            201)
                echo "  accepted in full, sha256 confirmed by the server"
                OK=1
                break
                ;;
            202)
                echo "  part accepted, continuing"
                ;;
            409)
                echo "  server reports the artifact as already accepted, rechecking"
                ;;
            416)
                echo "  offset rejected as out of sequence, re-reading server state"
                ;;
            422)
                echo "error: ${FILE} rejected: size or sha256 does not match the declared value."
                echo "The uploaded data was dropped on the server. The file differs from what"
                echo "release-info.json declares, retrying would not help."
                cat "${BODY}" || true
                exit 1
                ;;
            *)
                echo "  upload returned HTTP ${CODE}"
                cat "${BODY}" || true
                FAILURES=$((FAILURES + 1))
                ;;
        esac
    done

    if [ "${OK}" != "1" ]; then
        if [ "${LAST_RECEIVED}" -ge "${SIZE}" ] && [ "${SIZE}" -gt 0 ]; then
            echo "error: the server holds all ${SIZE} byte(s) of ${FILE} but has not"
            echo "accepted the artifact after ${MAX_FAILURES} checks. Its status stayed '${STATUS}'."
        else
            echo "error: ${FILE} was not accepted, ${MAX_FAILURES} attempt(s) failed in a row"
        fi
        exit 1
    fi
    ACCEPTED=$((ACCEPTED + 1))
done 3< "${PLAN}"

echo "${ACCEPTED} artifact(s) accepted"
printf '%s\n' "${ACCEPTED}" > "${TSA_RUN_DIR}/accepted"
