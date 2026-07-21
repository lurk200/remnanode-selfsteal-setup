#!/bin/bash
#
# Remnawave SelfSteal Multi-Protocol Setup v1.3.0
# SelfSteal + RU whitelist SNI probe + WL IP check + CDN template
#
# bash <(curl -fsSL https://cdn.jsdelivr.net/gh/lurk200/remnanode-selfsteal-setup@main/setup.sh) --yes --all
#
set -euo pipefail

VERSION="1.3.0-selfsteal"
OUT_DIR="/opt/remnanode"
JSON_OUT="${OUT_DIR}/config-profile-selfsteal.json"
HINTS_OUT="${OUT_DIR}/reality-client-hints.txt"
HOSTS_OUT="${OUT_DIR}/HOSTS-FOR-PANEL.txt"
URIS_OUT="${OUT_DIR}/example-client-uris.txt"
CERT_PERSIST="${OUT_DIR}/certs"
REPORT_OUT="${OUT_DIR}/setup-report.txt"
RU_SNI_OUT="${OUT_DIR}/RU-SNI-REPORT.txt"
WL_IP_OUT="${OUT_DIR}/WL-IP-CHECK.txt"
CDN_SETUP_OUT="${OUT_DIR}/CDN-WS-SETUP.txt"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'

log_ok()    { echo -e "${GREEN}[✓]${NC} $1"; }
log_info()  { echo -e "${BLUE}[•]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; }
fatal()     { log_error "$1"; [[ -n "${2:-}" ]] && log_warn "$2"; exit 1; }

AUTO_YES=false
DO_ALL=false
TAG_PREFIX=""
DOMAIN_OVERRIDE=""
FORCE_NEW_KEYS=false
PRIVATE_KEY_OPT=""
PUBLIC_KEY_OPT=""
SHORT_ID_OPT=""
TEST_ONLY=false
SKIP_RU_SNI=false
CHECK_WL_IP=true
RU_SNI_LIMIT=30
CDN_DOMAIN=""
CDN_WS_PATH=""
FINGERPRINT="randomized"
XHTTP_MODE="stream-one"
RU_WHITELIST_URL="https://cdn.jsdelivr.net/gh/hxehex/russia-mobile-internet-whitelist@main/whitelist.txt"
RU_CIDR_URL="https://cdn.jsdelivr.net/gh/hxehex/russia-mobile-internet-whitelist@main/cidrwhitelist.txt"
BEST_RU_DEST="eh.vk.com:443"
BEST_RU_HOST="eh.vk.com"
SERVER_IP=""
WL_IP_MATCH=false
PASS=0
FAIL=0

# Приоритетные apex/www (пересечение с моб. whitelist, июнь 2026)
RU_SNI_PRIORITY=(
  ya.ru
  eh.vk.com
  www.vk.com
  www.avito.ru
  www.ozon.ru
  www.wildberries.ru
  www.sberbank.ru
  www.vtb.ru
  www.gosuslugi.ru
  gosuslugi.ru
  www.mail.ru
  www.ok.ru
  www.rzd.ru
  2gis.ru
  dzen.ru
  rutube.ru
  max.ru
  alfabank.ru
  www.dns-shop.ru
  www.citilink.ru
  id.tbank.ru
  cdn.tbank.ru
)

usage() {
  cat <<'USAGE'
Usage: setup.sh [options]

  --yes, -y              без вопросов, все протоколы
  --all                  hy2 + grpc + xhttp
  --domain NAME          selfsteal домен
  --prefix TAG           префикс тегов (ger/pl/yt/www)
  --new-keys             новые Reality keys
  --private-key / --public-key / --short-id
  --test-only            только диагностика
  --skip-ru-sni          не перебирать RU SNI/dest
  --ru-sni-limit N       сколько кандидатов проверить (default 30)
  --ru-whitelist-source URL   whitelist.txt (default: hxehex via jsDelivr)
  --no-check-wl-ip       не проверять IP в cidrwhitelist
  --fingerprint FP       uTLS для клиентов (default: randomized)
  --cdn-domain NAME      шаблон Cloudflare+WS (второй домен, orange cloud)
  --cdn-ws-path PATH     WS path для CDN (default: /api/v1/update)
  -h, --help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y) AUTO_YES=true; DO_ALL=true; shift ;;
    --all) DO_ALL=true; shift ;;
    --domain) DOMAIN_OVERRIDE="$2"; shift 2 ;;
    --prefix) TAG_PREFIX="$2"; shift 2 ;;
    --new-keys) FORCE_NEW_KEYS=true; shift ;;
    --private-key) PRIVATE_KEY_OPT="$2"; shift 2 ;;
    --public-key) PUBLIC_KEY_OPT="$2"; shift 2 ;;
    --short-id) SHORT_ID_OPT="$2"; shift 2 ;;
    --test-only) TEST_ONLY=true; shift ;;
    --skip-ru-sni) SKIP_RU_SNI=true; shift ;;
    --ru-sni-limit) RU_SNI_LIMIT="$2"; shift 2 ;;
    --ru-whitelist-source) RU_WHITELIST_URL="$2"; shift 2 ;;
    --no-check-wl-ip) CHECK_WL_IP=false; shift ;;
    --fingerprint) FINGERPRINT="$2"; shift 2 ;;
    --cdn-domain) CDN_DOMAIN="$2"; shift 2 ;;
    --cdn-ws-path) CDN_WS_PATH="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) fatal "Неизвестный аргумент: $1" ;;
  esac
done

[[ -z "$CDN_WS_PATH" ]] && CDN_WS_PATH="/api/v1/update"

show_logo() {
  cat <<EOF
╔══════════════════════════════════════════════════════════════════╗
║       Remnawave SelfSteal Multi-Protocol Setup  v${VERSION}    ║
║  whitelist · TLS probe · WL-IP · randomized fp · XHTTP stream-one ║
╚══════════════════════════════════════════════════════════════════╝
EOF
}

need_cmd() { command -v "$1" &>/dev/null || fatal "Нужна команда: $1"; }

record() {
  local ok="$1"; shift
  if [[ "$ok" == "1" ]]; then
    log_ok "$*"
    PASS=$((PASS + 1))
  else
    log_error "$*"
    FAIL=$((FAIL + 1))
  fi
}

xray_bin() {
  if docker exec remnanode test -x /usr/local/bin/xray 2>/dev/null; then
    echo /usr/local/bin/xray
  else
    echo xray
  fi
}

derive_public() {
  local priv="$1" out pub xb
  xb=$(xray_bin)
  out=$(docker exec remnanode "$xb" x25519 -i "$priv" 2>&1 || true)
  pub=$(printf '%s\n' "$out" | awk -F': *' 'BEGIN{IGNORECASE=1} /PublicKey/ {gsub(/\r/,"",$2); gsub(/^ +| +$/,"",$2); print $2; exit}')
  echo "$pub"
}

detect_server_ip() {
  SERVER_IP=$(curl -4fsS --connect-timeout 5 ifconfig.me 2>/dev/null \
    || curl -4fsS --connect-timeout 5 icanhazip.com 2>/dev/null \
    || hostname -I 2>/dev/null | awk '{print $1}' || true)
  SERVER_IP=$(echo "${SERVER_IP:-}" | tr -d '[:space:]')
}

# Скачать whitelist + отфильтровать apex/www, затем TLS probe со скорингом
probe_ru_snis() {
  BEST_RU_DEST="eh.vk.com:443"
  BEST_RU_HOST="eh.vk.com"

  if [[ "$SKIP_RU_SNI" == "true" ]]; then
    log_warn "Пропуск перебора RU SNI (--skip-ru-sni), dest=${BEST_RU_DEST}"
    return
  fi

  log_info "RU SNI: whitelist + TLS1.3/H2 probe (лимит ${RU_SNI_LIMIT})..."
  need_cmd python3
  mkdir -p "$OUT_DIR"

  local wl_file pri_file best
  wl_file=$(mktemp)
  pri_file=$(mktemp)
  printf '%s\n' "${RU_SNI_PRIORITY[@]}" > "$pri_file"

  if curl -fsSL --connect-timeout 15 --max-time 45 "$RU_WHITELIST_URL" -o "$wl_file" 2>/dev/null; then
    log_ok "Whitelist: ${RU_WHITELIST_URL}"
  else
    log_warn "Whitelist недоступен — только встроенный priority-лист"
    : > "$wl_file"
  fi

  set +e
  best=$(
    RU_SNI_OUT="$RU_SNI_OUT" RU_SNI_LIMIT="$RU_SNI_LIMIT" \
    RU_WHITELIST_FILE="$wl_file" RU_PRIORITY_FILE="$pri_file" python3 <<'PY'
import os, sys, time, socket, ssl, re

out_path = os.environ.get("RU_SNI_OUT", "/opt/remnanode/RU-SNI-REPORT.txt")
limit = int(os.environ.get("RU_SNI_LIMIT", "30"))
wl_path = os.environ["RU_WHITELIST_FILE"]
pri_path = os.environ["RU_PRIORITY_FILE"]

SKIP_PREFIX = re.compile(
    r"^(?:\d+\.|img\.|cdn\.|static\.|st\.|sun\d|tile\d|cloudcdn|ams\d|pptest\.|staging-)",
    re.I,
)

def good_host(h: str) -> bool:
    h = h.strip().lower()
    if not h or " " in h or len(h) > 64:
        return False
    parts = h.split(".")
    if len(parts) < 2 or len(parts) > 3:
        return False
    if SKIP_PREFIX.match(h):
        return False
    if len(parts) == 2:
        return True
    # 3 labels: www.*, eh.*, ads.*, m.* (limited)
    head = parts[0]
    if head == "www":
        return True
    if head in ("eh", "ads") and parts[1] in ("vk", "vk.com", "x5"):
        return True
    if head == "m" and parts[1] == "vk":
        return True
    return False

def load_lines(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return [ln.strip().lower() for ln in fh if ln.strip() and not ln.startswith("#")]
    except OSError:
        return []

wl = {h for h in load_lines(wl_path) if good_host(h)}
pri = [h for h in load_lines(pri_path) if good_host(h)]

ordered = []
seen = set()
for h in pri:
    if h not in seen:
        ordered.append(h); seen.add(h)
for h in sorted(wl):
    if h not in seen:
        ordered.append(h); seen.add(h)
hosts = ordered[:limit]

def probe(host, port=443, timeout=3.0):
    t0 = time.time()
    score = 0
    tls_ver = alpn = cipher = curve = ""
    try:
        raw = socket.create_connection((host, port), timeout=timeout)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        ctx.minimum_version = ssl.TLSVersion.TLSv1_2
        with ctx.wrap_socket(raw, server_hostname=host) as ssock:
            ms = int((time.time() - t0) * 1000)
            tls_ver = ssock.version() or ""
            alpn = ssock.selected_alpn_protocol() or ""
            ci = ssock.cipher() or ("", "", 0)
            cipher = ci[0]
            if tls_ver == "TLSv1.3":
                score += 30
            if alpn == "h2":
                score += 25
            elif alpn == "http/1.1":
                score += 10
            if cipher and "TLS_AES" in cipher:
                score += 10
            try:
                shared = ssock.shared_ciphers() or []
                if any("X25519" in str(c) for c in shared):
                    score += 5
            except Exception:
                pass
            if ms < 100:
                score += 10
            elif ms < 250:
                score += 5
            return True, ms, score, tls_ver, alpn, cipher, ""
    except Exception as e:
        ms = int((time.time() - t0) * 1000)
        return False, ms, 0, "", "", "", str(e)[:120]

rows = []
for h in hosts:
    ok, ms, score, tls_ver, alpn, cipher, err = probe(h)
    rows.append((ok, score, ms, h, tls_ver, alpn, cipher, err))
    tag = "OK" if ok else "FAIL"
    extra = f"score={score} {tls_ver} {alpn}" if ok else err
    print(f"  [{tag}] {h:28s} {ms:4d}ms  {extra}", file=sys.stderr, flush=True)

ok_rows = [r for r in rows if r[0]]
ok_rows.sort(key=lambda r: (-r[1], r[2]))

os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
with open(out_path, "w", encoding="utf-8") as f:
    f.write("# RU SNI/dest probe v1.3 (from this node)\n")
    f.write(f"# whitelist: {os.environ.get('RU_WHITELIST_URL', 'builtin')}\n")
    f.write("# Score: TLS1.3 +30, H2 +25, TLS_AES +10, fast RTT +5..10\n")
    f.write("# SelfSteal VLESS SNI = your steal domain (not below)\n")
    f.write("# gRPC/XHTTP: dest + serverNames + client SNI = same RU host\n\n")
    f.write("rank\tscore\tms\thost\ttls\talpn\tcipher\n")
    for i, (ok, score, ms, h, tls_ver, alpn, cipher, err) in enumerate(ok_rows, 1):
        f.write(f"{i}\t{score}\t{ms}\t{h}\t{tls_ver}\t{alpn}\t{cipher}\n")
    f.write("\n# FAILED\n")
    for ok, score, ms, h, tls_ver, alpn, cipher, err in rows:
        if not ok:
            f.write(f"FAIL\t{ms}\t{h}\t{err}\n")
    if ok_rows:
        best_h = ok_rows[0][3]
        top3 = ",".join(r[3] for r in ok_rows[:3])
        f.write(f"\nBEST={best_h}:443\n")
        f.write(f"TOP3={top3}\n")
        f.write(f"FINGERPRINT=recommended:randomized|qq|firefox\n")
        sys.stdout.write(best_h)
    else:
        f.write("\nBEST=\n")

print(f"# tested {len(hosts)} candidates ({len(wl)} from whitelist)", file=sys.stderr)
PY
  )
  local probe_rc=$?
  set -e
  rm -f "$wl_file" "$pri_file"

  if [[ $probe_rc -ne 0 ]]; then
    log_warn "RU SNI probe ошибка (rc=${probe_rc}) — fallback ${BEST_RU_DEST}"
    return
  fi

  if [[ -n "${best:-}" ]]; then
    BEST_RU_HOST="$best"
    BEST_RU_DEST="${best}:443"
    log_ok "Лучший RU dest: ${BEST_RU_DEST} (отчёт: ${RU_SNI_OUT})"
  else
    log_warn "Ни один RU SNI не ответил — fallback ${BEST_RU_DEST}"
  fi
}

check_wl_ip() {
  if [[ "$CHECK_WL_IP" != "true" ]]; then
    log_warn "Пропуск WL IP check (--no-check-wl-ip)"
    return
  fi

  detect_server_ip
  [[ -n "$SERVER_IP" ]] || { log_warn "Не удалось определить публичный IP"; return; }

  log_info "WL IP check: ${SERVER_IP} vs cidrwhitelist..."
  need_cmd python3

  local cidr_file
  cidr_file=$(mktemp)
  if ! curl -fsSL --connect-timeout 15 --max-time 45 "$RU_CIDR_URL" -o "$cidr_file" 2>/dev/null; then
  log_warn "cidrwhitelist недоступен — пропуск WL IP check"
    rm -f "$cidr_file"
    return
  fi

  local result
  result=$(
    SERVER_IP="$SERVER_IP" WL_IP_OUT="$WL_IP_OUT" WL_CIDR_FILE="$cidr_file" python3 <<'PY'
import ipaddress, os, sys

ip_s = os.environ.get("SERVER_IP", "").strip()
out = os.environ.get("WL_IP_OUT", "/opt/remnanode/WL-IP-CHECK.txt")
cidr_path = os.environ["WL_CIDR_FILE"]

try:
    ip = ipaddress.ip_address(ip_s)
except ValueError:
    print("invalid"); sys.exit(0)

nets = []
with open(cidr_path, encoding="utf-8") as fh:
    for ln in fh:
        ln = ln.strip()
        if not ln or ln.startswith("#"):
            continue
        try:
            nets.append(ipaddress.ip_network(ln, strict=False))
        except ValueError:
            pass

matched = [str(n) for n in nets if ip in n]
status = "WHITELISTED" if matched else "NOT_WHITELISTED"

with open(out, "w", encoding="utf-8") as f:
    f.write("# Mobile RU IP+SNI whitelist check\n")
    f.write(f"# source: hxehex/russia-mobile-internet-whitelist cidrwhitelist.txt\n")
    f.write(f"server_ip={ip_s}\n")
    f.write(f"status={status}\n")
    f.write(f"matched_cidrs={len(matched)}\n")
    if matched:
        f.write("\n# Matching subnets (first 20):\n")
        for c in matched[:20]:
            f.write(f"{c}\n")
    else:
        f.write("\n# IP NOT in mobile whitelist subnets.\n")
        f.write("# For RU mobile: use RU bridge (Yandex Cloud WL IP) or CDN (Cloudflare).\n")
        f.write("# Test: open https://YOUR_IP:443 from LTE without VPN.\n")

print(status)
PY
  )
  rm -f "$cidr_file"

  if [[ "$result" == "WHITELISTED" ]]; then
    WL_IP_MATCH=true
    log_ok "IP ${SERVER_IP} в cidrwhitelist (моб. WL)"
  elif [[ "$result" == "NOT_WHITELISTED" ]]; then
    WL_IP_MATCH=false
    log_warn "IP ${SERVER_IP} НЕ в cidrwhitelist — с LTE может не работать"
    log_warn "Отчёт: ${WL_IP_OUT}"
  fi
}

write_cdn_template() {
  [[ -n "$CDN_DOMAIN" ]] || return 0
  log_info "CDN шаблон для ${CDN_DOMAIN}..."

  local ws_port
  ws_port=$((10000 + RANDOM % 40000))

  cat > "$CDN_SETUP_OUT" <<EOF
# Cloudflare + WebSocket fallback (v1.3)
# Источник: nozikov/vless-relay-setup — обход ISP domain whitelisting
#
# SelfSteal домен: ${DOMAIN}  → A record DIRECT (grey cloud) → ${SERVER_IP:-YOUR_IP}
# CDN домен:        ${CDN_DOMAIN} → A record PROXY (orange cloud) → тот же IP
#
# Cloudflare панель (${CDN_DOMAIN}):
#   SSL/TLS → Full
#   Network → WebSockets: ON
#   Порт 80 открыт (ACME / redirect)
#
# Caddy (добавить вручную в Caddyfile caddy-remnawave):
# ${CDN_DOMAIN} {
#   reverse_proxy /${CDN_WS_PATH#/} 127.0.0.1:${ws_port}
#   # остальной трафик → тот же сайт что SelfSteal
# }
#
# Xray inbound (добавить в профиль или отдельный WS inbound):
#   listen 127.0.0.1:${ws_port}
#   network: ws, path: ${CDN_WS_PATH}
#   clients → через Cloudflare к ${CDN_DOMAIN}
#
# Клиент:
#   Address: ${CDN_DOMAIN}
#   Port: 443
#   Type: ws
#   Path: ${CDN_WS_PATH}
#   TLS: ON (SNI=${CDN_DOMAIN})
#   fingerprint: ${FINGERPRINT}
#
# Reality SelfSteal на ${DOMAIN} остаётся основным путём (DPI).
# CDN — запасной при блокировке кастомного домена оператором.
EOF
  log_ok "CDN шаблон: ${CDN_SETUP_OUT}"
}

detect_domain() {
  if [[ -n "$DOMAIN_OVERRIDE" ]]; then DOMAIN="$DOMAIN_OVERRIDE"; return; fi
  if [[ -f /opt/remnanode/docker-compose.yml ]]; then
    DOMAIN=$(grep -E 'SELF_STEAL_DOMAIN=' /opt/remnanode/docker-compose.yml 2>/dev/null \
      | head -1 | sed -E 's/.*SELF_STEAL_DOMAIN=//;s/["'\'']//g' | tr -d '[:space:]' || true)
    [[ -n "${DOMAIN:-}" ]] && return
  fi
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx caddy-remnawave; then
    DOMAIN=$(docker inspect caddy-remnawave --format '{{range .Config.Env}}{{println .}}{{end}}' \
      | grep '^SELF_STEAL_DOMAIN=' | cut -d= -f2- | head -1 || true)
    [[ -n "${DOMAIN:-}" ]] && return
  fi
  if [[ -d /etc/letsencrypt/live ]]; then
    DOMAIN=$(ls /etc/letsencrypt/live 2>/dev/null | grep -v README | head -1 || true)
    [[ -n "${DOMAIN:-}" ]] && return
  fi
  local crt
  crt=$(find /var/lib/docker/volumes/caddy_data/_data/caddy/certificates -name '*.crt' 2>/dev/null | head -1 || true)
  [[ -n "$crt" ]] && { DOMAIN=$(basename "$crt" .crt); return; }
  fatal "Не найден SELF_STEAL_DOMAIN" "Укажи --domain"
}

detect_prefix() {
  if [[ -n "$TAG_PREFIX" ]]; then PREFIX="$TAG_PREFIX"; return; fi
  local sub; sub=$(echo "$DOMAIN" | cut -d. -f1)
  case "$sub" in
    ger|pl|yt|ru|de|nl|fi|www) PREFIX="$sub" ;;
    *) PREFIX="www" ;;
  esac
}

find_certs() {
  CERT_PATH=""; KEY_PATH=""
  if [[ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]]; then
    CERT_PATH="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
    KEY_PATH="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
    return
  fi
  local crt key
  crt=$(find /var/lib/docker/volumes/caddy_data/_data -name "${DOMAIN}.crt" 2>/dev/null | head -1 || true)
  key=$(find /var/lib/docker/volumes/caddy_data/_data -name "${DOMAIN}.key" 2>/dev/null | head -1 || true)
  [[ -n "$crt" && -n "$key" ]] || fatal "Нет сертификата для ${DOMAIN}"
  CERT_PATH="$crt"; KEY_PATH="$key"
}

preflight() {
  log_info "Автоопределение окружения..."
  [[ "$EUID" -eq 0 ]] || fatal "Нужен root"
  need_cmd docker; need_cmd python3; need_cmd curl; need_cmd openssl
  docker info &>/dev/null || fatal "Docker не запущен"
  docker inspect remnanode &>/dev/null || fatal "Нет контейнера remnanode"
  [[ "$(docker inspect remnanode --format '{{.State.Status}}')" == "running" ]] || fatal "remnanode не running"
  docker inspect remnanode --format '{{json .Mounts}}' | grep -q '/dev/shm' || fatal "/dev/shm не смонтирован"

  detect_domain
  detect_prefix
  find_certs
  detect_server_ip

  UFW_ACTIVE=false
  if command -v ufw &>/dev/null && ufw status 2>/dev/null | head -1 | grep -qi active; then
    UFW_ACTIVE=true
  fi

  log_ok "domain=${DOMAIN} prefix=${PREFIX}"
  log_ok "cert=${CERT_PATH}"
  [[ -n "$SERVER_IP" ]] && log_ok "public_ip=${SERVER_IP}"
}

open_port() {
  local port="$1" proto="$2" desc="$3"
  [[ "$UFW_ACTIVE" != "true" ]] && return 0
  if ufw status 2>/dev/null | grep -qE "^${port}/${proto}[[:space:]]+ALLOW"; then
    return 0
  fi
  ufw allow "${port}/${proto}" comment "$desc" >/dev/null
  log_ok "UFW ${port}/${proto} ($desc)"
}

sync_hy2_certs() {
  log_info "HY2 certs → /dev/shm (файлы, не symlink)..."
  [[ -L /dev/shm/hysteria_cert.pem ]] && rm -f /dev/shm/hysteria_cert.pem
  [[ -L /dev/shm/hysteria_key.pem ]] && rm -f /dev/shm/hysteria_key.pem
  cp -L "$CERT_PATH" /dev/shm/hysteria_cert.pem
  cp -L "$KEY_PATH"  /dev/shm/hysteria_key.pem
  chmod 644 /dev/shm/hysteria_cert.pem
  chmod 600 /dev/shm/hysteria_key.pem
  mkdir -p "$CERT_PERSIST"
  cp -f /dev/shm/hysteria_*.pem "$CERT_PERSIST/"
  chmod 600 "$CERT_PERSIST/hysteria_key.pem"

  if [[ "$CERT_PATH" != "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]]; then
    mkdir -p "/etc/letsencrypt/live/${DOMAIN}"
    ln -sfn "$CERT_PATH" "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
    ln -sfn "$KEY_PATH"  "/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
    ln -sfn "$CERT_PATH" "/etc/letsencrypt/live/${DOMAIN}/cert.pem"
    ln -sfn "$CERT_PATH" "/etc/letsencrypt/live/${DOMAIN}/chain.pem"
  fi

  docker exec remnanode openssl x509 -in /dev/shm/hysteria_cert.pem -noout -subject &>/dev/null \
    || fatal "Контейнер не читает hysteria_cert.pem"
  log_ok "HY2 certs OK"
}

setup_cron() {
  cat > /opt/remnanode/restore-hy2-certs.sh <<'EOF'
#!/bin/bash
set -euo pipefail
SRC=/opt/remnanode/certs
[[ -f $SRC/hysteria_cert.pem && -f $SRC/hysteria_key.pem ]] || exit 0
cp -f "$SRC/hysteria_cert.pem" /dev/shm/hysteria_cert.pem
cp -f "$SRC/hysteria_key.pem"  /dev/shm/hysteria_key.pem
chmod 644 /dev/shm/hysteria_cert.pem
chmod 600 /dev/shm/hysteria_key.pem
EOF
  chmod +x /opt/remnanode/restore-hy2-certs.sh
  if ! crontab -l 2>/dev/null | grep -q restore-hy2-certs; then
    (crontab -l 2>/dev/null | grep -v hysteria_cert || true
     echo "@reboot /opt/remnanode/restore-hy2-certs.sh"
     echo "15 4 * * * /opt/remnanode/restore-hy2-certs.sh"
    ) | crontab -
    log_ok "Cron restore добавлен"
  else
    log_ok "Cron restore уже есть"
  fi
}

load_keys_from_file() {
  local f="$1"
  [[ -f "$f" ]] || return 1
  if [[ "$f" == *.json ]]; then
    PRIVATE_KEY=$(python3 - "$f" <<'PY'
import json,sys
c=json.load(open(sys.argv[1]))
for ib in c.get("inbounds",[]):
  rs=(ib.get("streamSettings") or {}).get("realitySettings") or {}
  if rs.get("privateKey"):
    print(rs["privateKey"]); break
PY
)
    SHORT_ID=$(python3 - "$f" <<'PY'
import json,sys
c=json.load(open(sys.argv[1]))
for ib in c.get("inbounds",[]):
  rs=(ib.get("streamSettings") or {}).get("realitySettings") or {}
  ids=rs.get("shortIds") or []
  if ids: print(ids[0]); break
PY
)
  else
    PRIVATE_KEY=$(grep '^privateKey=' "$f" 2>/dev/null | cut -d= -f2- || true)
    PUBLIC_KEY=$(grep '^publicKey=' "$f" 2>/dev/null | cut -d= -f2- || true)
    SHORT_ID=$(grep '^shortId=' "$f" 2>/dev/null | cut -d= -f2- || true)
  fi
  [[ -n "${PRIVATE_KEY:-}" && -n "${SHORT_ID:-}" ]]
}

resolve_keys() {
  if [[ -n "$PRIVATE_KEY_OPT" ]]; then
    PRIVATE_KEY="$PRIVATE_KEY_OPT"
    PUBLIC_KEY="${PUBLIC_KEY_OPT:-}"
    SHORT_ID="${SHORT_ID_OPT:-$(openssl rand -hex 4)}"
    log_ok "Keys из аргументов (shortId=${SHORT_ID})"
  elif [[ "$FORCE_NEW_KEYS" != "true" ]] && load_keys_from_file "$HINTS_OUT"; then
    log_ok "Keys reuse из hints (shortId=${SHORT_ID})"
  elif [[ "$FORCE_NEW_KEYS" != "true" ]] && load_keys_from_file "$JSON_OUT"; then
    log_ok "Keys reuse из предыдущего JSON (shortId=${SHORT_ID})"
  else
    if [[ "$FORCE_NEW_KEYS" == "true" ]]; then
      log_warn "Принудительная генерация НОВЫХ keys (--new-keys)"
    else
      log_info "Старых keys нет — генерируем новые"
    fi
    local xb out
    xb=$(xray_bin)
    set +e
    out=$(docker exec remnanode "$xb" x25519 2>&1)
    set -e
    PRIVATE_KEY=$(printf '%s\n' "$out" | awk -F': *' 'BEGIN{IGNORECASE=1} /^PrivateKey/ || /^Private key/ {gsub(/\r/,"",$2); gsub(/^ +| +$/,"",$2); print $2; exit}')
    PUBLIC_KEY=$(printf '%s\n' "$out" | awk -F': *' 'BEGIN{IGNORECASE=1} /PublicKey/ {gsub(/\r/,"",$2); gsub(/^ +| +$/,"",$2); print $2; exit}')
    [[ -n "${PRIVATE_KEY:-}" && -n "${PUBLIC_KEY:-}" ]] || fatal "x25519 parse failed" "$out"
    SHORT_ID=$(openssl rand -hex 4)
    log_ok "Новые Reality keys (shortId=${SHORT_ID})"
    log_warn "Клиентам нужна новая подписка (новый publicKey)"
  fi

  local derived
  derived=$(derive_public "$PRIVATE_KEY")
  if [[ -n "$derived" ]]; then
    if [[ -n "${PUBLIC_KEY:-}" && "$PUBLIC_KEY" != "$derived" ]]; then
      log_warn "publicKey в hints не совпал с private — исправляю на derived"
    fi
    PUBLIC_KEY="$derived"
  fi
  [[ -n "${PUBLIC_KEY:-}" ]] || fatal "Не удалось получить publicKey"
  log_ok "publicKey=${PUBLIC_KEY}"
}

build_outputs() {
  log_info "Сборка Config Profile + Hosts шаблона..."
  export DOMAIN PREFIX PRIVATE_KEY PUBLIC_KEY SHORT_ID
  export SELECTED="${SELECTED[*]}"
  export JSON_OUT HINTS_OUT HOSTS_OUT URIS_OUT CDN_SETUP_OUT
  export BEST_RU_DEST BEST_RU_HOST FINGERPRINT XHTTP_MODE CDN_DOMAIN CDN_WS_PATH SERVER_IP

  python3 <<'PY'
import json, os

domain = os.environ["DOMAIN"]
prefix = os.environ["PREFIX"]
priv = os.environ["PRIVATE_KEY"]
pub = os.environ["PUBLIC_KEY"]
short = os.environ["SHORT_ID"]
fp = os.environ.get("FINGERPRINT", "randomized")
xhttp_mode = os.environ.get("XHTTP_MODE", "stream-one")
selected = os.environ.get("SELECTED", "hy2 grpc xhttp").split()
json_out = os.environ["JSON_OUT"]
hints = os.environ["HINTS_OUT"]
hosts = os.environ["HOSTS_OUT"]
uris = os.environ["URIS_OUT"]
ru_dest = os.environ.get("BEST_RU_DEST", "eh.vk.com:443")
ru_host = os.environ.get("BEST_RU_HOST", "eh.vk.com")
cdn_domain = os.environ.get("CDN_DOMAIN", "")
cdn_path = os.environ.get("CDN_WS_PATH", "/api/v1/update")
server_ip = os.environ.get("SERVER_IP", "")

tag_vless = f"{prefix}-vless-443"
tag_hy2 = f"{prefix}-hy2-443"
tag_grpc = f"{prefix}-grpc-8443"
tag_xhttp = f"{prefix}-xhttp-4443"
svc = f"{prefix}_grpc"

inbounds = [{
  "tag": tag_vless,
  "port": 443,
  "listen": "0.0.0.0",
  "protocol": "vless",
  "settings": {"clients": [], "decryption": "none"},
  "sniffing": {"enabled": True, "destOverride": ["http", "tls", "quic"]},
  "streamSettings": {
    "network": "raw",
    "security": "reality",
    "realitySettings": {
      "xver": 1,
      "target": "/dev/shm/nginx.sock",
      "shortIds": [short],
      "privateKey": priv,
      "serverNames": [domain],
    },
  },
}]

if "hy2" in selected:
  inbounds.append({
    "tag": tag_hy2,
    "port": 443,
    "listen": "0.0.0.0",
    "protocol": "hysteria",
    "settings": {"clients": [], "version": 2},
    "streamSettings": {
      "network": "hysteria",
      "security": "tls",
      "finalmask": {"quicParams": {"debug": False, "congestion": "bbr"}},
      "tlsSettings": {
        "alpn": ["h3"],
        "certificates": [{
          "keyFile": "/dev/shm/hysteria_key.pem",
          "certificateFile": "/dev/shm/hysteria_cert.pem",
        }],
      },
      "hysteriaSettings": {"version": 2},
    },
  })

if "grpc" in selected:
  inbounds.append({
    "tag": tag_grpc,
    "port": 8443,
    "listen": "0.0.0.0",
    "protocol": "vless",
    "settings": {"clients": [], "decryption": "none"},
    "sniffing": {"enabled": True, "destOverride": ["http", "tls", "quic"]},
    "streamSettings": {
      "network": "grpc",
      "security": "reality",
      "grpcSettings": {"multiMode": False, "serviceName": svc},
      "realitySettings": {
        "dest": ru_dest,
        "show": False,
        "xver": 0,
        "spiderX": "",
        "shortIds": [short],
        "privateKey": priv,
        "serverNames": [ru_host],
      },
    },
  })

if "xhttp" in selected:
  inbounds.append({
    "tag": tag_xhttp,
    "port": 4443,
    "listen": "0.0.0.0",
    "protocol": "vless",
    "settings": {"clients": [], "decryption": "none"},
    "sniffing": {"enabled": True, "destOverride": ["http", "tls", "quic"]},
    "streamSettings": {
      "network": "xhttp",
      "security": "reality",
      "xhttpSettings": {
        "mode": xhttp_mode,
        "path": "/",
        "noGRPCHeader": False,
        "xPaddingBytes": "100-1000",
        "scMaxBufferedPosts": 30,
        "scMaxEachPostBytes": "1000000",
      },
      "realitySettings": {
        "dest": ru_dest,
        "show": False,
        "xver": 0,
        "spiderX": "",
        "shortIds": [short],
        "privateKey": priv,
        "serverNames": [ru_host],
      },
    },
  })

cfg = {
  "log": {"loglevel": "none"},
  "inbounds": inbounds,
  "outbounds": [
    {"tag": "DIRECT", "protocol": "freedom"},
    {"tag": "BLOCK", "protocol": "blackhole"},
  ],
  "routing": {"rules": [
    {"ip": ["geoip:private"], "outboundTag": "BLOCK"},
    {"domain": ["geosite:private"], "outboundTag": "BLOCK"},
    {"protocol": ["bittorrent"], "outboundTag": "BLOCK"},
  ]},
}

with open(json_out, "w", encoding="utf-8") as f:
  json.dump(cfg, f, indent=2, ensure_ascii=False)
  f.write("\n")

with open(hints, "w", encoding="utf-8") as f:
  f.write(f"domain={domain}\npublicKey={pub}\nshortId={short}\nprivateKey={priv}\n")
  f.write(f"sni={domain}\naddress={domain}\nserver_ip={server_ip}\n")
  f.write(f"vless_port=443\nhy2_port=443/udp\ngrpc_port=8443\ngrpc_service={svc}\n")
  f.write(f"xhttp_port=4443\nxhttp_mode={xhttp_mode}\n")
  f.write(f"vless_flow=\nfingerprint={fp}\n")
  f.write(f"reality_dest={ru_dest}\nru_sni_best={ru_host}\n")
  if cdn_domain:
    f.write(f"cdn_domain={cdn_domain}\ncdn_ws_path={cdn_path}\n")

cdn_note = ""
if cdn_domain:
  cdn_note = f"""
## CDN fallback (WS via Cloudflare)
cdn_domain = {cdn_domain}
cdn_path   = {cdn_path}
fp         = {fp}
# см. {os.environ.get('CDN_SETUP_OUT', '/opt/remnanode/CDN-WS-SETUP.txt')}
"""

with open(hosts, "w", encoding="utf-8") as f:
  f.write(f"""# HOSTS / подписка Remnawave v1.3
# VLESS SelfSteal: SNI = {domain}, flow ПУСТОЙ, fp = {fp}
# gRPC/XHTTP: Address = {domain}, SNI = {ru_host} (dest {ru_dest})
# XHTTP mode = {xhttp_mode} (не packet-up без CDN)
# Hosts → Advanced → Fingerprint = {fp} (не chrome на LTE!)

Address (клиент→нода)  = {domain}
publicKey (pbk)        = {pub}
shortId (sid)          = {short}
fingerprint            = {fp}
reality_dest           = {ru_dest}
ru_sni_best            = {ru_host}

## {tag_vless}
inbound   = {tag_vless}
port      = 443
type      = tcp
security  = reality
flow      = <EMPTY>
sni       = {domain}
fp        = {fp}
pbk       = {pub}
sid       = {short}

## {tag_hy2}
inbound   = {tag_hy2}
port      = 443/udp
sni       = {domain}

## {tag_grpc}
inbound     = {tag_grpc}
port        = 8443
type        = grpc
serviceName = {svc}
mode        = gun
sni         = {ru_host}
fp          = {fp}
pbk         = {pub}
sid         = {short}

## {tag_xhttp}
inbound = {tag_xhttp}
port    = 4443
type    = xhttp
path    = /
mode    = {xhttp_mode}
sni     = {ru_host}
fp      = {fp}
pbk     = {pub}
sid     = {short}
{cdn_note}""")

uuid = "00000000-0000-0000-0000-000000000000"
with open(uris, "w", encoding="utf-8") as f:
  f.write(f"# v1.3 — fp={fp}, flow пустой на VLESS SelfSteal\n")
  f.write(f"vless://{uuid}@{domain}:443?encryption=none&type=tcp&security=reality&sni={domain}&fp={fp}&pbk={pub}&sid={short}#{prefix}-vless\n")
  f.write(f"vless://{uuid}@{domain}:8443?encryption=none&type=grpc&serviceName={svc}&mode=gun&security=reality&sni={ru_host}&fp={fp}&pbk={pub}&sid={short}#{prefix}-grpc\n")
  f.write(f"vless://{uuid}@{domain}:4443?encryption=none&type=xhttp&path=%2F&mode={xhttp_mode}&security=reality&sni={ru_host}&fp={fp}&pbk={pub}&sid={short}#{prefix}-xhttp\n")
  f.write(f"hysteria2://{uuid}@{domain}:443/?sni={domain}#{prefix}-hy2\n")
  if cdn_domain:
    f.write(f"# CDN WS (настроить вручную): wss://{cdn_domain}:443{cdn_path}\n")

print("ok")
PY

  log_ok "JSON:  $JSON_OUT"
  log_ok "Hosts: $HOSTS_OUT"
  log_ok "URIs:  $URIS_OUT"
}

run_tests() {
  echo ""
  log_info "Автотесты..."
  PASS=0; FAIL=0

  if [[ -S /dev/shm/nginx.sock ]]; then record 1 "nginx.sock существует"; else record 0 "нет nginx.sock"; fi

  if [[ -f /dev/shm/hysteria_cert.pem && ! -L /dev/shm/hysteria_cert.pem ]]; then
    record 1 "hysteria_cert.pem — обычный файл"
  else
    record 0 "hysteria_cert.pem отсутствует или symlink"
  fi

  if docker exec remnanode openssl x509 -in /dev/shm/hysteria_cert.pem -noout -subject &>/dev/null; then
    record 1 "cert читается внутри remnanode"
  else
    record 0 "cert НЕ читается внутри remnanode"
  fi

  local code
  code=$(curl -sk --connect-timeout 8 --max-time 12 -o /dev/null -w '%{http_code}' "https://${DOMAIN}/" || echo 000)
  if [[ "$code" == "200" ]]; then
    record 1 "SelfSteal https://${DOMAIN}/ → 200"
  else
    record 0 "SelfSteal https://${DOMAIN}/ → HTTP $code"
  fi

  local srv
  srv=$(curl -skI --connect-timeout 8 --max-time 12 "https://${DOMAIN}/" 2>/dev/null | grep -i '^server:' | head -1 | tr -d '\r' || true)
  if echo "$srv" | grep -qi caddy; then
    record 1 "SelfSteal Server: Caddy"
  else
    record 0 "SelfSteal Server странный: ${srv:-empty}"
  fi

  ss -tulpn 2>/dev/null | grep -q ':443 ' && record 1 "listen :443" || record 0 "нет listen :443"
  ss -tulpn 2>/dev/null | grep -q ':8443' && record 1 "listen :8443" || log_warn "нет :8443 (до Save профиля)"
  ss -tulpn 2>/dev/null | grep -q ':4443' && record 1 "listen :4443" || log_warn "нет :4443 (до Save профиля)"
  ss -tulpn 2>/dev/null | grep -q ':2222' && record 1 "listen :2222 API" || record 0 "нет :2222"

  if [[ -n "${PRIVATE_KEY:-}" && -n "${PUBLIC_KEY:-}" ]]; then
    local d
    d=$(derive_public "$PRIVATE_KEY")
    if [[ "$d" == "$PUBLIC_KEY" ]]; then
      record 1 "publicKey соответствует privateKey"
    else
      record 0 "publicKey НЕ соответствует privateKey"
    fi
  fi

  if [[ -f "$JSON_OUT" ]]; then
    local v
    v=$(python3 - "$JSON_OUT" <<'PY'
import json,sys
c=json.load(open(sys.argv[1]))
ok_ss=False
ok_xhttp=False
for ib in c.get("inbounds",[]):
  ss=ib.get("streamSettings") or {}
  rs=ss.get("realitySettings") or {}
  if ib.get("protocol")=="vless" and ib.get("port")==443 and ss.get("network") in ("raw","tcp"):
    if rs.get("target")=="/dev/shm/nginx.sock" and int(rs.get("xver") or 0)==1:
      ok_ss=True
  if ss.get("network")=="xhttp":
    mode=(ss.get("xhttpSettings") or {}).get("mode","")
    if mode=="stream-one":
      ok_xhttp=True
print("yes" if ok_ss and ok_xhttp else "no")
PY
)
    if [[ "$v" == "yes" ]]; then
      record 1 "JSON: SelfSteal + XHTTP stream-one OK"
    else
      record 0 "JSON: SelfSteal/XHTTP проверка не прошла"
    fi
  fi

  if [[ -f "$RU_SNI_OUT" ]] && grep -q '^BEST=' "$RU_SNI_OUT" 2>/dev/null; then
    record 1 "RU-SNI-REPORT с BEST"
  elif [[ "$SKIP_RU_SNI" == "true" ]]; then
    log_warn "RU SNI пропущен"
  else
    record 0 "нет RU-SNI-REPORT"
  fi

  if [[ "$CHECK_WL_IP" == "true" && -f "$WL_IP_OUT" ]]; then
    if [[ "$WL_IP_MATCH" == "true" ]]; then
      record 1 "WL IP: в cidrwhitelist"
    else
      log_warn "WL IP: НЕ в cidrwhitelist (LTE может не работать)"
    fi
  fi

  echo ""
  echo "Тесты: ${PASS} OK, ${FAIL} FAIL" | tee "$REPORT_OUT"
  {
    echo "domain=$DOMAIN prefix=$PREFIX publicKey=${PUBLIC_KEY:-?} shortId=${SHORT_ID:-?}"
    echo "fingerprint=$FINGERPRINT ru_dest=$BEST_RU_DEST wl_ip=${SERVER_IP:-?} wl_match=$WL_IP_MATCH"
  } >> "$REPORT_OUT"
}

finalize() {
  cat <<EOF

═══════════════════════════════════════════════════════════
 $(echo -e "${GREEN}ГОТОВО${NC}")  v${VERSION}
═══════════════════════════════════════════════════════════
 Файлы:
   $JSON_OUT
   $HOSTS_OUT
   $URIS_OUT
   $HINTS_OUT
   $RU_SNI_OUT
   $WL_IP_OUT
$([[ -n "$CDN_DOMAIN" ]] && echo "   $CDN_SETUP_OUT")

 Параметры:
   SNI SelfSteal = $DOMAIN (flow ПУСТОЙ)
   fingerprint   = $FINGERPRINT  ← в Hosts Advanced, не chrome
   RU dest/SNI   = $BEST_RU_DEST (gRPC/XHTTP)
   XHTTP mode    = $XHTTP_MODE
   publicKey     = $PUBLIC_KEY
   shortId       = $SHORT_ID
   server IP     = ${SERVER_IP:-?}  WL: $([[ "$WL_IP_MATCH" == "true" ]] && echo OK || echo NOT_IN_LIST)

 Панель:
   1. Config Profiles → $JSON_OUT
   2. Active Inbounds: ${PREFIX}-vless/hy2/grpc/xhttp
   3. Hosts → $HOSTS_OUT (fp=$FINGERPRINT, flow пустой)
   4. Обновить подписку клиентов
═══════════════════════════════════════════════════════════
EOF
  echo ""
  echo "----- TOP RU SNI -----"
  grep -E '^(BEST|TOP3|[0-9]+\t)' "$RU_SNI_OUT" 2>/dev/null | head -8 || true
  echo ""
  echo "----- WL IP -----"
  grep -E '^(server_ip|status)=' "$WL_IP_OUT" 2>/dev/null || true
}

run_test_only() {
  preflight
  [[ -f "$HINTS_OUT" ]] && load_keys_from_file "$HINTS_OUT" || true
  [[ -z "${PRIVATE_KEY:-}" && -f "$JSON_OUT" ]] && load_keys_from_file "$JSON_OUT" || true
  if [[ -n "${PRIVATE_KEY:-}" ]]; then
    PUBLIC_KEY=$(derive_public "$PRIVATE_KEY")
    SHORT_ID="${SHORT_ID:-unknown}"
  fi
  probe_ru_snis
  check_wl_ip
  run_tests
  echo "BEST_RU_DEST=${BEST_RU_DEST} FINGERPRINT=${FINGERPRINT} WL=${WL_IP_MATCH}"
  exit $([[ $FAIL -eq 0 ]] && echo 0 || echo 2)
}

main() {
  clear 2>/dev/null || true
  show_logo
  echo ""
  mkdir -p "$OUT_DIR"

  if [[ "$TEST_ONLY" == "true" ]]; then
    run_test_only
  fi

  preflight
  SELECTED=("hy2" "grpc" "xhttp")
  log_ok "Протоколы: vless + ${SELECTED[*]} | fp=${FINGERPRINT}"

  open_port 443 tcp "VLESS Reality"
  open_port 80 tcp "HTTP"
  open_port 443 udp "HY2"
  open_port 8443 tcp "gRPC"
  open_port 4443 tcp "XHTTP"

  sync_hy2_certs
  setup_cron
  resolve_keys
  probe_ru_snis
  check_wl_ip
  write_cdn_template
  build_outputs
  run_tests
  finalize
}

main "$@"
