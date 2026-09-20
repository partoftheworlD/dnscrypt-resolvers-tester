Скрипт для проверки DNS-резолверов через локальный `dnscrypt-proxy` на наличие тех, которые вызывают проблемы при подключении к определенным ресурсам для последующего их исключения из списка доступных.

Пути по умолчанию для `.sh`:

- `/usr/sbin/dnscrypt-proxy`
- `/etc/dnscrypt-proxy/dnscrypt-proxy.toml`
- `/var/cache/dnscrypt-proxy`

Их можно переопределить переменными:

- `DNSCRYPT_BIN`
- `DNSCRYPT_CONF`
- `DNSCRYPT_CACHE_DIR`

## Использование Linux

```bash
chmod +x check-resolvers.sh

# Проверить example.com всеми резолверами
./check-resolvers.sh

# Подробный вывод: IP, время, OK/BAD
./check-resolvers.sh -v

# Пользовательский домен
./check-resolvers.sh -d example.org

# Пользовательский конфиг
./check-resolvers.sh -c /path/to/dnscrypt-proxy.toml -v

# Через переменные окружения
DNSCRYPT_BIN=/usr/local/bin/dnscrypt-proxy \
DNSCRYPT_CONF=/etc/dnscrypt-proxy/dnscrypt-proxy.toml \
./check-resolvers.sh -v
```

Параметры `.sh`:

- `-v` — подробный вывод.
- `-d DOMAIN` — домен для проверки.
- `-c CONFIG` — путь к `dnscrypt-proxy.toml`.
- Первый позиционный аргумент также может задать домен:
  `./check-resolvers.sh example.net`

## Использование Windows

Положить `check-resolvers.ps1` к `dnscrypt-proxy.exe` и `dnscrypt-proxy.toml`
в одну папку.

```powershell
# Разрешить выполнение скрипта в текущей сессии
Set-ExecutionPolicy -Scope Process Bypass

# Пользовательский домен
.\check-resolvers.ps1 example.org -v
```

## Проблемы в работе скрипта

1. Наличие включеных в конфиге dnscrypt-proxy cloaking_rules и blocked_names_file. Достаточно закоментировать их на время проверки.
2. Наличие включеной службы dnscrypt-proxy. Решается остановкой служб как в Windows, так и Linux.
