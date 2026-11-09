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
    # Перевод строки в ключе превратил бы его хвост в отдельную директиву
    # конфига curl ('user = …' и прочее), молча подменив опции запроса
    case "${TSA_API_KEY}" in
        *$'\n'*|*$'\r'*)
            echo "error: TSA_API_KEY contains a newline, refusing to build curl config" >&2
            return 1
            ;;
    esac
    # Значение в конфиге curl берётся в двойные кавычки, внутри которых
    # '\' и '"' — escape-символы: экранируем их, иначе ключ приедет искажённым
    local escaped="${TSA_API_KEY//\\/\\\\}"
    escaped="${escaped//\"/\\\"}"
    # umask в подоболочке, чтобы не менять его вызывающему шагу. Файл
    # предварительно удаляем: umask не сужает права уже существующего
    (
        umask 077
        rm -f "${target}"
        printf 'header = "X-API-Key: %s"\n' "${escaped}" > "${target}"
    )
}
