# Remnawave SelfSteal Multi-Protocol Setup

Автоматическая настройка ноды Remnawave:

- домен из `SELF_STEAL_DOMAIN` / LE / Caddy
- Reality SelfSteal: `target=/dev/shm/nginx.sock`, `xver=1`
- `serverNames` = ваш домен
- HY2 certs = реальные файлы в `/dev/shm` + persist/cron
- UFW порты
- готовый Config Profile JSON
- шаблон **Hosts** для панели (flow пустой!)
- автотесты (socket, certs, SelfSteal 200, keys)

## Установка

```bash
bash <(curl -fsSL https://cdn.jsdelivr.net/gh/lurk200/remnanode-selfsteal-setup@main/setup.sh) --yes --all
```

По умолчанию **переиспользует** старые Reality keys (если есть hints/JSON), чтобы не ломать клиентов.  
Новые ключи только с `--new-keys`.

## После скрипта

1. Вставь `/opt/remnanode/config-profile-selfsteal.json` в Config Profile  
2. Node → все Active Inbounds  
3. Hosts → по файлу `/opt/remnanode/HOSTS-FOR-PANEL.txt`  
   **VLESS flow = пусто** (не `xtls-rprx-vision`)  
4. Клиенты → обновить подписку  

## Только тесты

```bash
bash <(curl -fsSL https://cdn.jsdelivr.net/gh/lurk200/remnanode-selfsteal-setup@main/setup.sh) --test-only
```

## Опции

| Флаг | Описание |
|------|----------|
| `--yes --all` | без вопросов |
| `--domain` / `--prefix` | явный домен/префикс |
| `--new-keys` | новые Reality keys |
| `--test-only` | диагностика |

## Файлы на ноде

- `/opt/remnanode/config-profile-selfsteal.json`
- `/opt/remnanode/HOSTS-FOR-PANEL.txt`
- `/opt/remnanode/example-client-uris.txt`
- `/opt/remnanode/reality-client-hints.txt`

## License

MIT
