#!/usr/bin/env bash
set -u

Domain="example.com"
Verbose=0
ResolversArg=""
# which внутри $(...) при отсутствии бинарника вернёт пустую строку — ниже это отдельно проверяется.
DNSCRYPT_BIN="${DNSCRYPT_BIN:-$(which dnscrypt-proxy)}"
DNSCRYPT_CONF="${DNSCRYPT_CONF:-/etc/dnscrypt-proxy/dnscrypt-proxy.toml}"
DNSCRYPT_CACHE_DIR="${DNSCRYPT_CACHE_DIR:-/var/cache/dnscrypt-proxy}"

# Парсер без getopts: -d/-c/-r забирают следующий аргумент, любой другой
# свободный аргумент трактуется как домен (так `script example.org` работает).
while (($#)); do
  case $1 in
    -v) Verbose=1 ;;
    -d) Domain=$2; shift ;;
    -c) DNSCRYPT_CONF=$2; shift ;;
    -r) ResolversArg=$2; shift ;;
    -*) echo "Неизвестный параметр: $1" >&2; exit 1 ;;
    *)  Domain=$1 ;;
  esac
  shift
done

[ ! -e "$DNSCRYPT_BIN" ]  && { echo "Не найден dnscrypt-proxy: $DNSCRYPT_BIN" >&2; exit 1; }
[ ! -f "$DNSCRYPT_CONF" ] && { echo "Не найден конфиг: $DNSCRYPT_CONF" >&2; exit 1; }

# dnscrypt-proxy открывает относительные пути из конфига (cache_file, blocked-names и т.п.)
# относительно текущего каталога, поэтому запускаем его из cache-директории,
# а если её нет — из каталога конфига.
RunDir="$DNSCRYPT_CACHE_DIR"
[ -d "$RunDir" ] || RunDir="$(dirname "$DNSCRYPT_CONF")"

TempDir="$(mktemp -d "${TMPDIR:-/tmp}/dnscrypt-test.XXXXXX")"
Process=""
ConfigPath=""

# ConfigPath может быть пустым — [ -f "" ] спокойно вернёт false, так что проверки достаточно.
# wait после kill нужен, чтобы не оставлять зомби и не гоняться с самим процессом за сокет.
cleanup() {
  [ -n "$Process" ] && kill -0 "$Process" 2>/dev/null &&
    { kill "$Process" 2>/dev/null; wait "$Process" 2>/dev/null; }
  [ -f "$ConfigPath" ] && rm -f "$ConfigPath"
  [ -d "$TempDir" ]    && rm -rf "$TempDir"
  return 0
}
trap cleanup EXIT

# Проверяем и TCP, и UDP (-anltu), т.к. DNS-прокси слушает оба; регулярка
# покрывает и IPv4 (:53000), и IPv6 ([::]:53000 / *.53000) представление ss/netstat.
port_in_use() {
  if command -v ss >/dev/null 2>&1; then
    ss -H -anltu 2>/dev/null | grep -qE "[:.]$1[[:space:]]"
  elif command -v netstat >/dev/null 2>&1; then
    netstat -anltu 2>/dev/null | grep -qE "[:.]$1[[:space:]]"
  else
    return 1
  fi
}

# Диапазон 53000-59999 выбран заведомо выше привилегированных портов и типичных
# «чужих» сервисов, чтобы не пересечься с уже запущенным экземпляром dnscrypt-proxy на 53/5353.
get_free_port() {
  for ((port=53000; port<=59999; port++)); do
    port_in_use "$port" || { echo "$port"; return 0; }
  done
  return 1
}

now_ns() {
  local v; v=$(date +%s%N 2>/dev/null || true)
  [[ $v =~ ^[0-9]+$ ]] && printf '%s' "$v" || printf '%s000000000' "$(date +%s)"
}

if [ -n "${ResolversArg:-}" ]; then
  # tr -s '[:space:]' '\n' — список может прийти через пробелы, запятые пользователь не вводит;
  # grep отсекает всё, что не похоже на имя резолвера (защита от мусора в TOML-строке ниже).
  mapfile -t Resolvers < <(printf '%s\n' "$ResolversArg" \
    | tr -s '[:space:]' '\n' \
    | grep -E '^[A-Za-z0-9][A-Za-z0-9._-]*$' | sort -u)
else
  ListOut="$(cd "$RunDir" && timeout 30 "$DNSCRYPT_BIN" -config "$DNSCRYPT_CONF" -list 2>/dev/null || true)"
  [ -z "$ListOut" ] && ListOut="$(cd "$RunDir" && timeout 30 "$DNSCRYPT_BIN" -config "$DNSCRYPT_CONF" -list 2>/dev/null || true)"

  mapfile -t Resolvers < <(printf '%s\n' "$ListOut" | tr -d '\r' \
    | grep -E '^[A-Za-z0-9][A-Za-z0-9._-]*$' | sort -u)
fi

[ ${#Resolvers[@]} -eq 0 ] && Resolvers=(google yandex cloudflare)

BadResolvers=()
Total=${#Resolvers[@]}
Index=0

for Resolver in "${Resolvers[@]}"; do
  Index=$((Index+1))
  # Прогресс — в stderr, чтобы stdout оставался чистым для парсинга итогового списка.
  [ "$Verbose" -eq 0 ] && printf "\rПроверка: %d/%d %-30s" "$Index" "$Total" "$Resolver" >&2

  Process=""; ConfigPath=""

  Port="$(get_free_port)"
  if [ -z "$Port" ]; then
    [ "$Verbose" -eq 1 ] && printf "%-25s нет свободного порта\n" "$Resolver"
    BadResolvers+=("$Resolver"); continue
  fi

  ConfigPath="$TempDir/${Resolver//[^A-Za-z0-9._-]/_}.toml"

  # awk не «дописывает» конфиг, а подменяет нужные ключи по месту:
  #   - `#*` в шаблоне ловит и закомментированные варианты (`# server_names = ...`);
  #   - `next` не даёт оригинальной строке попасть в вывод;
  #   - если ключа в файле нет вообще — дописываем его в END.
  # Порядок ключей в TOML на верхнем уровне не важен, поэтому дописывание в конец безопасно.
  # q="'" — одиночные кавычки TOML; имя резолвера уже отфильтровано регуляркой выше, кавычек в нём быть не может.
  awk -v res="$Resolver" -v port="$Port" -v q="'" '
    BEGIN { fs=fc=fl=fi6=0 }
    # server_names — ограничиваем проверяемый инстанс одним резолвером.
    /^[[:space:]]*#*[[:space:]]*server_names[[:space:]]*=/     { if(!fs){printf "server_names = [%s%s%s]\n", q, res, q; fs=1} next }
    # cache = false — иначе кэш из основного каталога может «подсунуть» ответ и проверка станет фиктивной,
    # плюс несколько параллельных инстансов подерутся за один файл кэша.
    /^[[:space:]]*#*[[:space:]]*cache[[:space:]]*=/            { if(!fc){print "cache = false"; fc=1} next }
    # Слушаем на свободном порту, чтобы не занять 53/5353 работающего у пользователя прокси.
    /^[[:space:]]*#*[[:space:]]*listen_addresses[[:space:]]*=/ { if(!fl){printf "listen_addresses = [%s127.0.0.1:%s%s]\n", q, port, q; fl=1} next }
    # Часть резолверов (и часть сетей) работает только по IPv6 — без этого их нельзя проверить.
    /^[[:space:]]*#*[[:space:]]*ipv6_servers[[:space:]]*=/     { if(!fi6){print "ipv6_servers = true"; fi6=1} next }
    { print }
    END {
      if(!fs)  printf "server_names = [%s%s%s]\n", q, res, q
      if(!fc)  print "cache = false"
      if(!fl)  printf "listen_addresses = [%s127.0.0.1:%s%s]\n", q, port, q
      if(!fi6) print "ipv6_servers = true"
    }
  ' "$DNSCRYPT_CONF" > "$ConfigPath"

  # -check валидирует конфиг и резолвер без запуска сервиса: ловит опечатки в имени,
  # недоступный source списков и т.п. Из вывода достаём только одну строку-диагностику.
  if ! CheckOut=$(cd "$RunDir" && timeout 20 "$DNSCRYPT_BIN" -check -config "$ConfigPath" 2>&1); then
    if [ "$Verbose" -eq 1 ]; then
      ErrLine=$(printf '%s\n' "$CheckOut" | grep -aE '\[(FATAL|CRITICAL|ERROR)\]|Fatal error|error:' | head -n1)
      [ -z "$ErrLine" ] && ErrLine=$(printf '%s\n' "$CheckOut" | grep -avE '\[NOTICE\]' | grep -av '^[[:space:]]*$' | tail -n1)
      [ -z "$ErrLine" ] && ErrLine="(no diagnostic)"
      printf "%-25s check failed: %s\n" "$Resolver" "${ErrLine:0:140}"
    fi
    BadResolvers+=("$Resolver"); continue
  fi

  # Запускаем в фоновом подоболочном процессе (cd в RunDir наследуется), pid — это pid самого dnscrypt-proxy.
  ( cd "$RunDir" && exec "$DNSCRYPT_BIN" -config "$ConfigPath" >/dev/null 2>&1 ) &
  Process=$!

  sleep 1

  if ! kill -0 "$Process" 2>/dev/null; then
    [ "$Verbose" -eq 1 ] && printf "%-25s process exited\n" "$Resolver"
    BadResolvers+=("$Resolver"); wait "$Process" 2>/dev/null; continue
  fi

  start_ns=$(now_ns)
  # nslookup предпочтительнее (есть почти везде), dig — запасной вариант;
  # если нет ни того, ни другого, Output останется пустым и резолвер уйдёт в Bad.
  if command -v nslookup >/dev/null 2>&1; then
    Output=$(timeout 6 nslookup -type=A -timeout=1 -retry=1 -port="$Port" "$Domain" 127.0.0.1 2>&1 || true)
  elif command -v dig >/dev/null 2>&1; then
    Output=$(timeout 6 dig +short +time=1 +tries=1 @127.0.0.1 -p "$Port" A "$Domain" 2>&1 || true)
  else
    Output=""
  fi
  elapsed_ms=$(( ($(now_ns) - start_ns) / 1000000 ))

  # nslookup печатает адрес самого сервера (127.0.0.1) в шапке вывода — его надо отбросить,
  # иначе любой резолвер будет выглядеть «ответившим». Ноль (0.0.0.0) — типичная заглушка-блокировка.
  Addresses=$(printf '%s\n' "$Output" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' \
    | grep -v '^127\.0\.0\.1$' | sort -u)

  Bad=0
  { [ -z "$Addresses" ] || printf '%s\n' "$Addresses" | grep -q '^0\.0\.0\.0$'; } && Bad=1

  if [ "$Verbose" -eq 1 ]; then
    Ips=$(printf '%s' "$Addresses" | tr '\n' ',' | sed 's/,$//')
    [ -z "$Ips" ] && Ips="-"
    if [ "$Bad" -eq 1 ]; then
      printf "%-25s %-30s %5d ms   \033[33mBAD\033[0m\n" "$Resolver" "$Ips" "$elapsed_ms"
    else
      printf "%-25s %-30s %5d ms   \033[32mOK\033[0m\n"  "$Resolver" "$Ips" "$elapsed_ms"
    fi
  fi

  [ "$Bad" -eq 1 ] && BadResolvers+=("$Resolver")

  # Гасим инстанс сразу после проверки, не дожидаясь финального cleanup —
  # иначе на длинном списке накопятся десятки живых процессов и сокетов.
  kill -0 "$Process" 2>/dev/null && { kill "$Process" 2>/dev/null; wait "$Process" 2>/dev/null; }
  rm -f "$ConfigPath"; ConfigPath=""
done

[ "$Verbose" -eq 0 ] && printf "\n" >&2

if [ ${#BadResolvers[@]} -gt 0 ]; then
  echo ""
  echo "Проблемные резолверы:"
  printf "['"
  for i in "${!BadResolvers[@]}"; do
    [ "$i" -gt 0 ] && printf "', '"
    printf "%s" "${BadResolvers[$i]}"
  done
  printf "']\n"
else
  echo ""
  echo "Нет проблем"
fi