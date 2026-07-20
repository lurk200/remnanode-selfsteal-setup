# Remnawave SelfSteal Multi-Protocol Setup

Автоматическая настройка ноды Remnawave + перебор российских SNI/dest.

## Возможности

- домен, certs, UFW, Reality keys (reuse по умолчанию)
- SelfSteal VLESS: `target=/dev/shm/nginx.sock`
- **перебор ~40 российских сайтов** (TLS с ноды) → лучший `dest` для gRPC/XHTTP
- JSON + Hosts-шаблон + URI + автотесты

## Запуск

```bash
bash <(curl -fsSL https://cdn.jsdelivr.net/gh/lurk200/remnanode-selfsteal-setup@main/setup.sh) --yes --all
```

Отчёт SNI: `/opt/remnanode/RU-SNI-REPORT.txt`

```bash
# только тесты + перебор SNI
bash <(curl -fsSL https://cdn.jsdelivr.net/gh/lurk200/remnanode-selfsteal-setup@main/setup.sh) --test-only

# без перебора
... --yes --all --skip-ru-sni

# больше кандидатов
... --yes --all --ru-sni-limit 40
```

## Важно

- Client **SNI** для SelfSteal = ваш домен, не RU-сайт
- RU-сайт идёт в Reality **`dest`** (сервер → сайт для fingerprint)
- VLESS **flow пустой** (не vision)

## License

MIT
