#!/usr/bin/env bash
set -u

Domain="example.com"
Verbose=0
DNSCRYPT_BIN="${DNSCRYPT_BIN:-/usr/sbin/dnscrypt-proxy}"
DNSCRYPT_CONF="${DNSCRYPT_CONF:-/etc/dnscrypt-proxy/dnscrypt-proxy.toml}"
DNSCRYPT_CACHE_DIR="${DNSCRYPT_CACHE_DIR:-/var/cache/dnscrypt-proxy}"

while (($#)); do
  case $1 in
    -v) Verbose=1 ;;
    -d) Domain=$2; shift ;;
    -c) DNSCRYPT_CONF=$2; shift ;;
    -*) echo "Неизвестный параметр: $1" >&2; exit 1 ;;
    *)  Domain=$1 ;;
  esac
  shift
done

[ ! -e "$DNSCRYPT_BIN" ]  && { echo "Не найден dnscrypt-proxy: $DNSCRYPT_BIN" >&2; exit 1; }
[ ! -f "$DNSCRYPT_CONF" ] && { echo "Не найден конфиг: $DNSCRYPT_CONF" >&2; exit 1; }

RunDir="$DNSCRYPT_CACHE_DIR"
[ -d "$RunDir" ] || RunDir="$(dirname "$DNSCRYPT_CONF")"

TempDir="$(mktemp -d "${TMPDIR:-/tmp}/dnscrypt-test.XXXXXX")"
Process=""
ConfigPath=""

cleanup() {
  [ -n "$Process" ] && kill -0 "$Process" 2>/dev/null &&
    { kill "$Process" 2>/dev/null; wait "$Process" 2>/dev/null; }
  [ -f "$ConfigPath" ] && rm -f "$ConfigPath"
  [ -d "$TempDir" ]    && rm -rf "$TempDir"
  return 0
}
trap cleanup EXIT

port_in_use() {
  if command -v ss >/dev/null 2>&1; then
    ss -H -anltu 2>/dev/null | grep -qE "[:.]$1[[:space:]]"
  elif command -v netstat >/dev/null 2>&1; then
    netstat -anltu 2>/dev/null | grep -qE "[:.]$1[[:space:]]"
  else
    return 1
  fi
}

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

ListOut="$(cd "$RunDir" && timeout 30 "$DNSCRYPT_BIN" -config "$DNSCRYPT_CONF" -list 2>/dev/null || true)"
[ -z "$ListOut" ] && ListOut="$(cd "$RunDir" && timeout 30 "$DNSCRYPT_BIN" -config "$DNSCRYPT_CONF" -list 2>/dev/null || true)"

mapfile -t Resolvers < <(printf '%s\n' "$ListOut" | tr -d '\r' \
  | grep -E '^[A-Za-z0-9][A-Za-z0-9._-]*$' | sort -u)
[ ${#Resolvers[@]} -eq 0 ] && Resolvers=(google yandex cloudflare)

BadResolvers=()
Total=${#Resolvers[@]}
Index=0

for Resolver in "${Resolvers[@]}"; do
  Index=$((Index+1))
  [ "$Verbose" -eq 0 ] && printf "\rПроверка: %d/%d %-30s" "$Index" "$Total" "$Resolver" >&2

  Process=""; ConfigPath=""

  Port="$(get_free_port)"
  if [ -z "$Port" ]; then
    [ "$Verbose" -eq 1 ] && printf "%-25s нет свободного порта\n" "$Resolver"
    BadResolvers+=("$Resolver"); continue
  fi

  ConfigPath="$TempDir/${Resolver//[^A-Za-z0-9._-]/_}.toml"

  awk -v res="$Resolver" -v port="$Port" -v q="'" '
    BEGIN { fs=fc=fl=fi6=0 }
    /^[[:space:]]*#*[[:space:]]*server_names[[:space:]]*=/     { if(!fs){printf "server_names = [%s%s%s]\n", q, res, q; fs=1} next }
    /^[[:space:]]*#*[[:space:]]*cache[[:space:]]*=/            { if(!fc){print "cache = false"; fc=1} next }
    /^[[:space:]]*#*[[:space:]]*listen_addresses[[:space:]]*=/ { if(!fl){printf "listen_addresses = [%s127.0.0.1:%s%s]\n", q, port, q; fl=1} next }
    /^[[:space:]]*#*[[:space:]]*ipv6_servers[[:space:]]*=/     { if(!fi6){print "ipv6_servers = true"; fi6=1} next }
    { print }
    END {
      if(!fs)  printf "server_names = [%s%s%s]\n", q, res, q
      if(!fc)  print "cache = false"
      if(!fl)  printf "listen_addresses = [%s127.0.0.1:%s%s]\n", q, port, q
      if(!fi6) print "ipv6_servers = true"
    }
  ' "$DNSCRYPT_CONF" > "$ConfigPath"

  if ! CheckOut=$(cd "$RunDir" && timeout 20 "$DNSCRYPT_BIN" -check -config "$ConfigPath" 2>&1); then
    if [ "$Verbose" -eq 1 ]; then
      ErrLine=$(printf '%s\n' "$CheckOut" | grep -aE '\[(FATAL|CRITICAL|ERROR)\]|Fatal error|error:' | head -n1)
      [ -z "$ErrLine" ] && ErrLine=$(printf '%s\n' "$CheckOut" | grep -avE '\[NOTICE\]' | grep -av '^[[:space:]]*$' | tail -n1)
      [ -z "$ErrLine" ] && ErrLine="(no diagnostic)"
      printf "%-25s check failed: %s\n" "$Resolver" "${ErrLine:0:140}"
    fi
    BadResolvers+=("$Resolver"); continue
  fi

  ( cd "$RunDir" && exec "$DNSCRYPT_BIN" -config "$ConfigPath" >/dev/null 2>&1 ) &
  Process=$!
  sleep 2

  if ! kill -0 "$Process" 2>/dev/null; then
    [ "$Verbose" -eq 1 ] && printf "%-25s process exited\n" "$Resolver"
    BadResolvers+=("$Resolver"); wait "$Process" 2>/dev/null; continue
  fi

  start_ns=$(now_ns)
  if command -v nslookup >/dev/null 2>&1; then
    Output=$(timeout 6 nslookup -type=A -timeout=5 -retry=1 -port="$Port" "$Domain" 127.0.0.1 2>&1 || true)
  elif command -v dig >/dev/null 2>&1; then
    Output=$(timeout 6 dig +short +time=5 +tries=1 @127.0.0.1 -p "$Port" A "$Domain" 2>&1 || true)
  else
    Output=""
  fi
  elapsed_ms=$(( ($(now_ns) - start_ns) / 1000000 ))

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

  kill -0 "$Process" 2>/dev/null && { kill "$Process" 2>/dev/null; wait "$Process" 2>/dev/null; }
  rm -f "$ConfigPath"; ConfigPath=""
done

[ "$Verbose" -eq 0 ] && printf "\n" >&2

echo ""
echo "Проблемные резолверы:"
if [ ${#BadResolvers[@]} -gt 0 ]; then
  printf "['"
  for i in "${!BadResolvers[@]}"; do
    [ "$i" -gt 0 ] && printf "', '"
    printf "%s" "${BadResolvers[$i]}"
  done
  printf "']\n"
else
  echo "[]"
fi