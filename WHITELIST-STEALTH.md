# Белые списки (БС) и скрытность SelfSteal — 2026

## Почему при БС не открывается `https://yt.lurk-vpn.online/`

Это **не** поломка SelfSteal/Caddy.

DNS `yt.lurk-vpn.online` → `217.60.186.242` (RocketCloud, AS64439, Москва).  
На мобильном БС оператор пускает TCP только на IP из **cidrwhitelist**.  
«Сервер в РФ» ≠ «IP в белом списке».

Проверка (телефон LTE, VPN **выкл**):

```text
https://yt.lurk-vpn.online/   → timeout  = IP не в БС → как bridge для LTE не годится
https://ya.ru/                → 200      = сеть жива, режет именно ваш IP
```

Пока IP не в БС, **никакой** красивый домен/SNI не поможет: пакеты до `217.60.186.242:443` не доходят.

### Что делать для LTE+БС

1. Взять VPS (Yandex Cloud / Timeweb / Selectel / VDSina), поставить nginx/Caddy на `:443`.
2. С LTE без VPN открыть `https://IP/` или домен на этот IP.
3. Если открылось — IP в БС → ставить Remnawave **bridge** (только `:443`, Reality/XHTTP, SNI RU-донор).
4. Клиент: `🔗 RU Bridge` (Mihomo) → exit PL/GER.
5. `yt` оставить как обычную РФ-ноду для Wi‑Fi / без БС, либо переехать на WL-IP.

---

## Скрытность и необнаружение `yt.lurk-vpn.online`

Два разных риска:

| Риск | Что видит система | Защита |
|------|-------------------|--------|
| Банк/Госуслуги | exit IP EU в API «кто я» | **DIRECT** на `.ru`, банки, 2ip/ipify |
| ТСПУ / сканер | странный TLS к домену | SelfSteal 200+Caddy, Reality target=socket, flow пустой, fp=randomized |
| Утечка подписки | домен в remarks/чатах | не светить домен публично; Hosts Hidden где можно |

В шаблонах подписки:

- `geosite:category-ru` + банки + Госуслуги → **DIRECT**
- `2ip.ru`, `ipify`, `whoer`, … → **DIRECT** (не светить EU IP)
- сами SelfSteal-домены (`yt/pl/ger…`) → **DIRECT** в браузере клиента (не гонять сайт маскировки через VPN)

Пользователям **не нужно** открывать `https://yt.lurk-vpn.online/` «для проверки VPN» — это демаскирует и при БС всё равно не откроется.

---

## Итог для Lurk

| Сценарий | Путь |
|----------|------|
| Домашний Wi‑Fi / без БС | PL/GER/yt напрямую (наши Xray/Mihomo шаблоны) |
| LTE + БС | Нужен **другой** RU IP из WL → chain → PL/GER |
| Банки / Госуслуги | Всегда DIRECT (уже в v2 шаблонах) |
