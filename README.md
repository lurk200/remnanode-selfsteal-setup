# Remnawave SelfSteal Multi-Protocol Setup

Автоматическая настройка Remnawave Node с **правильным SelfSteal**:

- Reality `:443` → `target: /dev/shm/nginx.sock` + `xver: 1`
- `serverNames` = ваш selfsteal-домен (не чужой сайт)
- Hysteria2 certs = **реальные файлы** в `/dev/shm` (не symlink)
- UFW: `443/tcp+udp`, `8443`, `4443`
- Готовый Config Profile JSON для панели

Исправляет типичные ошибки скриптов/converter, где Reality смотрит на `ok.ru`/`vtb.ru` и HY2 падает с `SPAWN_ERROR`.

## Требования

- Уже установлен Remnawave Node (`remnanode` + Caddy SelfSteal)
- root на сервере ноды
- Docker, UFW (опционально)

## Быстрый старт

```bash
bash <(curl -sSL https://raw.githubusercontent.com/lurk200/remnanode-selfsteal-setup/main/setup.sh) --yes --all
```

После скачивания:

```bash
curl -fsSL -o setup.sh https://raw.githubusercontent.com/lurk200/remnanode-selfsteal-setup/main/setup.sh
bash setup.sh --yes --all
```

### Опции

| Флаг | Описание |
|------|----------|
| `--yes` | без вопросов |
| `--all` | hy2 + grpc + xhttp |
| `--domain NAME` | selfsteal домен |
| `--prefix TAG` | префикс тегов (`ger`, `pl`, `yt`, `www`) |
| `--reuse-keys` | взять ключи из `/opt/remnanode/reality-client-hints.txt` |
| `--private-key` / `--public-key` / `--short-id` | не ломать существующих клиентов |

Пример для GER с текущими ключами:

```bash
bash setup.sh --yes --all --domain ger.lurk-vpn.online --prefix www \
  --private-key '...' --short-id '...' --public-key '...'
```

## После скрипта

1. Открой `/opt/remnanode/config-profile-selfsteal.json`
2. Вставь в Remnawave → Config Profiles
3. Nodes → нода → этот профиль → включи **все Active Inbounds**
4. Save
5. Клиентам: Address/SNI = ваш домен, PublicKey из `/opt/remnanode/reality-client-hints.txt`

## Проверка

```bash
curl -sI https://YOUR-DOMAIN/ | head -10
# HTTP/2 200, Server: Caddy

ss -tulpn | grep -E '443|8443|4443|2222'
docker logs --tail=30 remnanode 2>&1 | grep -aE 'SPAWN|Failed to start|Xray Core'
```

## HTML-фиксер конфигов

Открой [`fix.html`](./fix.html) в браузере — вставь JSON профиля, укажи домен, получи исправленный конфиг + one-liner для сервера.

## Важно

- `/dev/shm` очищается после reboot — скрипт ставит persist в `/opt/remnanode/certs` и cron `@reboot`
- Не используй symlink `/dev/shm/*.pem` → `/etc/letsencrypt/...` (внутри контейнера пути нет)
- После смены тегов inbound обязательно заново отметь Active Inbounds у ноды

## License

MIT — используйте на свой страх и риск.
