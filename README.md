# Remnawave SelfSteal Multi-Protocol Setup v1.3

Авто-настройка Remnawave Node + SelfSteal + **RU whitelist SNI probe** + проверка WL IP.

## v1.3 новое

- Whitelist с [hxehex/russia-mobile-internet-whitelist](https://github.com/hxehex/russia-mobile-internet-whitelist) (jsDelivr CDN)
- TLS probe со скорингом: TLS1.3 + H2 + latency → TOP3 dest/SNI
- Проверка IP ноды в `cidrwhitelist.txt` → `WL-IP-CHECK.txt`
- `fingerprint=randomized` по умолчанию (не `chrome` на LTE)
- XHTTP `mode=stream-one` (рекомендация Xray 2026)
- Опционально `--cdn-domain` → шаблон Cloudflare+WS

## Запуск

```bash
bash <(curl -fsSL "https://cdn.jsdelivr.net/gh/lurk200/remnanode-selfsteal-setup@main/setup.sh") --yes --all
```

```bash
# только probe + WL check + тесты
bash <(curl -fsSL "https://cdn.jsdelivr.net/gh/lurk200/remnanode-selfsteal-setup@main/setup.sh") --test-only

# CDN fallback шаблон
bash <(curl -fsSL ".../setup.sh") --yes --all --cdn-domain cdn.example.com

# свой whitelist URL
bash <(curl -fsSL ".../setup.sh") --yes --all --ru-whitelist-source "https://cdn.jsdelivr.net/gh/hxehex/russia-mobile-internet-whitelist@main/whitelist.txt"
```

## Отчёты

| Файл | Содержимое |
|------|------------|
| `/opt/remnanode/RU-SNI-REPORT.txt` | score, TLS1.3, H2, BEST/TOP3 |
| `/opt/remnanode/WL-IP-CHECK.txt` | IP в моб. cidrwhitelist или нет |
| `/opt/remnanode/HOSTS-FOR-PANEL.txt` | шаблон Hosts с fp/SNI |
| `/opt/remnanode/CDN-WS-SETUP.txt` | если `--cdn-domain` |

## Hosts (важно)

| Inbound | Address | SNI | flow | fingerprint |
|---------|---------|-----|------|-------------|
| VLESS SelfSteal | ваш домен | ваш домен | **пусто** | randomized |
| gRPC/XHTTP | ваш домен | RU из отчёта | — | randomized |
| HY2 | ваш домен | ваш домен | — | — |

## Если IP не в WL

С LTE может не работать даже с правильным SNI. Варианты:
1. VPS с IP из [cidrwhitelist](https://github.com/hxehex/russia-mobile-internet-whitelist)
2. RU bridge → EU egress ([xray-double-hop](https://github.com/petrochen/xray-double-hop))
3. CDN Cloudflare (`--cdn-domain`)

## Подписка Россия (шаблоны)

| Файл | Тип в панели |
|------|----------------|
| [`subscription-russia-v2.json`](subscription-russia-v2.json) | XRAY_JSON |
| [`subscription-russia-mihomo.yaml`](subscription-russia-mihomo.yaml) | MIHOMO |
| [`subscription-russia-clash.yaml`](subscription-russia-clash.yaml) | CLASH |

Все: AI → DE/PL (не RU), YouTube → RU→EU, `.ru`/банки/2ip → DIRECT. Mihomo/Clash: `🔗 RU Bridge (LTE)`.

## License

MIT
