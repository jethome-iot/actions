# Запись curl-конфига с ключом API продукта. Подключается через source.
#
# Ключ берётся из переменной окружения TSA_API_KEY и никогда не передаётся
# аргументом команды: на self-hosted раннере список процессов виден всем.
# curl читает заголовок из файла (--config), в логи ключ не попадает.

write_api_config() {
    local target="$1"
    if [ -z "${TSA_API_KEY:-}" ]; then
        echo "error: TSA_API_KEY is empty, cannot build curl config" >&2
        return 1
    fi
    # Значение в конфиге curl берётся в двойные кавычки, внутри которых
    # '\' и '"' — escape-символы: экранируем их, иначе ключ приедет искажённым
    local escaped="${TSA_API_KEY//\\/\\\\}"
    escaped="${escaped//\"/\\\"}"
    # umask в подоболочке, чтобы не менять его вызывающему шагу
    (
        umask 077
        printf 'header = "X-API-Key: %s"\n' "${escaped}" > "${target}"
    )
}
