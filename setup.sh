#!/bin/bash
#
# Remnawave SelfSteal Multi-Protocol Setup v1.2.1
# Авто: домен, certs, UFW, Reality keys, RU-SNI probe, JSON, Hosts, тесты
#
# bash <(curl -fsSL https://cdn.jsdelivr.net/gh/lurk200/remnanode-selfsteal-setup@main/setup.sh) --yes --all
#
set -euo pipefail

VERSION="1.2.1-selfsteal"
OUT_DIR="/opt/remnanode"
JSON_OUT="${OUT_DIR}/config-profile-selfsteal.json"
HINTS_OUT="${OUT_DIR}/reality-client-hints.txt"
HOSTS_OUT="${OUT_DIR}/HOSTS-FOR-PANEL.txt"
URIS_OUT="${OUT_DIR}/example-client-uris.txt"
CERT_PERSIST="${OUT_DIR}/certs"
REPORT_OUT="${OUT_DIR}/setup-report.txt"
RU_SNI_OUT="${OUT_DIR}/RU-SNI-REPORT.txt"

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
RU_SNI_LIMIT=25
BEST_RU_DEST="www.cloudflare.com:443"
BEST_RU_HOST="www.cloudflare.com"
PASS=0
FAIL=0

# Популярные российские (и дружественные к РФ) dest/SNI для Reality
RU_SNI_CANDIDATES=(
  www.gazprom.ru
  www.sberbank.ru
  www.vtb.ru
  www.tbank.ru
  www.tinkoff.ru
  www.rzd.ru
  www.gosuslugi.ru
  www.mos.ru
  www.nalog.gov.ru
  www.cbr.ru
  www.vk.com
  m.vk.com
  www.ok.ru
  www.mail.ru
  www.yandex.ru
  ya.ru
  music.yandex.ru
  disk.yandex.ru
  www.wildberries.ru
  www.ozon.ru
  www.avito.ru
  www.dns-shop.ru
  www.mvideo.ru
  www.citilink.ru
  www.eldorado.ru
  www.mts.ru
  www.megafon.ru
  www.beeline.ru
  www.rt.ru
  www.ivi.ru
  www.kinopoisk.ru
  hh.ru
  www.cian.ru
  www.auto.ru
  www.drom.ru
  www.pikabu.ru
  www.rutube.ru
  www.2gis.ru
  www.gu.spb.ru
)

usage() {
  cat <<'USAGE'
Usage: setup.sh [options]

  --yes, -y          без вопросов, все протоколы
  --all              hy2 + grpc + xhttp
  --domain NAME      selfsteal домен
  --prefix TAG       префикс тегов (ger/pl/yt/www)
  --new-keys         новые Reality keys
  --private-key / --public-key / --short-id
  --test-only        только диагностика
  --skip-ru-sni      не перебирать российские SNI/dest
  --ru-sni-limit N   сколько кандидатов проверить (default 25)
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
    -h|--help) usage; exit 0 ;;
    *) fatal "Неизвестный аргумент: $1" ;;
  esac
done

show_logo() {
  cat <<EOF
╔══════════════════════════════════════════════════════════════════╗
║       Remnawave SelfSteal Multi-Protocol Setup  v${VERSION}    ║
║  auto · certs · keys · RU-SNI probe · JSON · Hosts · self-tests  ║
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
  local priv="$1" out pub
  local xb
  xb=$(xray_bin)
  out=$(docker exec remnanode "$xb" x25519 -i "$priv" 2>&1 || true)
  pub=$(printf '%s\n' "$out" | awk -F': *' 'BEGIN{IGNORECASE=1} /PublicKey/ {gsub(/\r/,"",$2); gsub(/^ +| +$/,"",$2); print $2; exit}')
  echo "$pub"
}

# Перебор российских dest/SNI: TCP+TLS с ноды (Reality dest ходит с сервера)
probe_ru_snis() {
  BEST_RU_DEST="www.cloudflare.com:443"
  BEST_RU_HOST="www.cloudflare.com"

  if [[ "$SKIP_RU_SNI" == "true" ]]; then
    log_warn "Пропуск перебора RU SNI (--skip-ru-sni), dest=${BEST_RU_DEST}"
    return
  fi

  log_info "Перебор российских SNI/dest (лимит ${RU_SNI_LIMIT})..."
  need_cmd python3
  mkdir -p "$OUT_DIR"

  local list=("${RU_SNI_CANDIDATES[@]:0:${RU_SNI_LIMIT}}")
  local list_file best
  list_file=$(mktemp)
  printf '%s\n' "${list[@]}" > "$list_file"

  # hosts через файл: нельзя pipe+heredoc (stdin занят скриптом → SIGPIPE + set -e)
  set +e
  best=$(
    RU_SNI_OUT="$RU_SNI_OUT" RU_SNI_LIST="$list_file" python3 <<'PY'
import os, sys, time, socket, ssl

out_path = os.environ.get("RU_SNI_OUT", "/opt/remnanode/RU-SNI-REPORT.txt")
list_path = os.environ["RU_SNI_LIST"]
with open(list_path, encoding="utf-8") as fh:
    hosts = [h.strip() for h in fh if h.strip()]
rows = []

def probe(host, port=443, timeout=3.0):
    t0 = time.time()
    try:
        raw = socket.create_connection((host, port), timeout=timeout)
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        with ctx.wrap_socket(raw, server_hostname=host) as ssock:
            ms = int((time.time() - t0) * 1000)
            cipher = ssock.cipher()[0] if ssock.cipher() else ""
            return True, ms, cipher, ""
    except Exception as e:
        ms = int((time.time() - t0) * 1000)
        return False, ms, "", str(e)[:120]

for h in hosts:
    ok, ms, cipher, err = probe(h)
    rows.append((ok, ms, h, cipher, err))
    status = "OK" if ok else "FAIL"
    print(f"  [{status}] {h:28s} {ms:4d}ms  {err}", file=sys.stderr, flush=True)

ok_rows = [r for r in rows if r[0]]
ok_rows.sort(key=lambda r: r[1])
os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
with open(out_path, "w", encoding="utf-8") as f:
    f.write("# RU SNI/dest probe from this node\n")
    f.write("# Reality dest dials FROM the server — must be reachable here\n")
    f.write("# Client SNI for SelfSteal VLESS stays your steal domain\n")
    f.write("# dest below is used for gRPC/XHTTP Reality fingerprint\n\n")
    f.write("rank\tms\thost\tcipher\n")
    for i, (ok, ms, h, cipher, err) in enumerate(ok_rows, 1):
        f.write(f"{i}\t{ms}\t{h}\t{cipher}\n")
    f.write("\n# FAILED\n")
    for ok, ms, h, cipher, err in rows:
        if not ok:
            f.write(f"FAIL\t{ms}\t{h}\t{err}\n")
    if ok_rows:
        f.write(f"\nBEST={ok_rows[0][2]}:443\n")
        f.write("TOP3=" + ",".join(r[2] for r in ok_rows[:3]) + "\n")
        sys.stdout.write(ok_rows[0][2])
    else:
        f.write("\nBEST=\n")
PY
  )
  local probe_rc=$?
  set -e
  rm -f "$list_file"

  if [[ $probe_rc -ne 0 ]]; then
    log_warn "RU SNI probe завершился с ошибкой (rc=${probe_rc}) — fallback ${BEST_RU_DEST}"
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

  UFW_ACTIVE=false
  if command -v ufw &>/dev/null && ufw status 2>/dev/null | head -1 | grep -qi active; then
    UFW_ACTIVE=true
  fi

  log_ok "domain=${DOMAIN} prefix=${PREFIX}"
  log_ok "cert=${CERT_PATH}"
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

  # всегда пересчитать public из private
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
  export JSON_OUT HINTS_OUT HOSTS_OUT URIS_OUT
  export BEST_RU_DEST BEST_RU_HOST

  python3 <<'PY'
import json, os

domain = os.environ["DOMAIN"]
prefix = os.environ["PREFIX"]
priv = os.environ["PRIVATE_KEY"]
pub = os.environ["PUBLIC_KEY"]
short = os.environ["SHORT_ID"]
selected = os.environ.get("SELECTED", "hy2 grpc xhttp").split()
json_out = os.environ["JSON_OUT"]
hints = os.environ["HINTS_OUT"]
hosts = os.environ["HOSTS_OUT"]
uris = os.environ["URIS_OUT"]
ru_dest = os.environ.get("BEST_RU_DEST", "www.cloudflare.com:443")
ru_host = os.environ.get("BEST_RU_HOST", "www.cloudflare.com")

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
        "mode": "auto",
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
  f.write(f"sni={domain}\naddress={domain}\nvless_port=443\nhy2_port=443/udp\n")
  f.write(f"grpc_port=8443\ngrpc_service={svc}\nxhttp_port=4443\n")
  f.write("vless_flow=\nfingerprint=chrome\n")
  f.write(f"reality_dest={ru_dest}\nru_sni_best={ru_host}\n")

with open(hosts, "w", encoding="utf-8") as f:
  f.write(f"""# HOSTS / подписка Remnawave
# VLESS SelfSteal: SNI = ваш домен, flow ПУСТОЙ
# gRPC/XHTTP Reality: Address = нода/домен, SNI = RU-сайт ({ru_host})
#   (совпадает с dest/serverNames; сервер dial'ит {ru_dest})

Address (клиент→нода)  = {domain}
publicKey (pbk)        = {pub}
shortId (sid)          = {short}
fingerprint            = chrome
reality_dest           = {ru_dest}

## {tag_vless}
inbound   = {tag_vless}
port      = 443
type      = tcp
security  = reality
flow      = <EMPTY>
sni       = {domain}
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
pbk         = {pub}
sid         = {short}

## {tag_xhttp}
inbound = {tag_xhttp}
port    = 4443
type    = xhttp
path    = /
mode    = auto
sni     = {ru_host}
pbk     = {pub}
sid     = {short}
""")

uuid = "00000000-0000-0000-0000-000000000000"
with open(uris, "w", encoding="utf-8") as f:
  f.write("# Пример URI (подставь UUID пользователя). flow НЕ использовать.\n")
  f.write(f"vless://{uuid}@{domain}:443?encryption=none&type=tcp&security=reality&sni={domain}&fp=chrome&pbk={pub}&sid={short}#{prefix}-vless\n")
  f.write(f"vless://{uuid}@{domain}:8443?encryption=none&type=grpc&serviceName={svc}&mode=gun&security=reality&sni={ru_host}&fp=chrome&pbk={pub}&sid={short}#{prefix}-grpc\n")
  f.write(f"vless://{uuid}@{domain}:4443?encryption=none&type=xhttp&path=%2F&mode=auto&security=reality&sni={ru_host}&fp=chrome&pbk={pub}&sid={short}#{prefix}-xhttp\n")
  f.write(f"hysteria2://{uuid}@{domain}:443/?sni={domain}#{prefix}-hy2\n")

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
    record 0 "SelfSteal https://${DOMAIN}/ → HTTP $code (после Save профиля в панели должно стать 200)"
  fi

  local srv
  srv=$(curl -skI --connect-timeout 8 --max-time 12 "https://${DOMAIN}/" 2>/dev/null | grep -i '^server:' | head -1 | tr -d '\r' || true)
  if echo "$srv" | grep -qi caddy; then
    record 1 "SelfSteal Server: Caddy (не ok.ru/apache)"
  else
    record 0 "SelfSteal Server странный: ${srv:-empty}"
  fi

  ss -tulpn 2>/dev/null | grep -q ':443 ' && record 1 "listen :443" || record 0 "нет listen :443"
  ss -tulpn 2>/dev/null | grep -q ':8443' && record 1 "listen :8443" || log_warn "нет :8443 (ожидаемо до Save профиля)"
  ss -tulpn 2>/dev/null | grep -q ':4443' && record 1 "listen :4443" || log_warn "нет :4443 (ожидаемо до Save профиля)"
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
ok=False
for ib in c.get("inbounds",[]):
  ss=ib.get("streamSettings") or {}
  rs=ss.get("realitySettings") or {}
  if ib.get("protocol")=="vless" and ib.get("port")==443 and ss.get("network") in ("raw","tcp"):
    if rs.get("target")=="/dev/shm/nginx.sock" and int(rs.get("xver") or 0)==1:
      ok=True
print("yes" if ok else "no")
PY
)
    if [[ "$v" == "yes" ]]; then
      record 1 "JSON: Reality SelfSteal target+xver OK"
    else
      record 0 "JSON: SelfSteal target/xver неверные"
    fi
  fi

  echo ""
  echo "Тесты: ${PASS} OK, ${FAIL} FAIL" | tee "$REPORT_OUT"
  echo "domain=$DOMAIN prefix=$PREFIX publicKey=${PUBLIC_KEY:-?} shortId=${SHORT_ID:-?}" >> "$REPORT_OUT"
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

 Параметры клиентов:
   SNI/Address = $DOMAIN
   publicKey   = $PUBLIC_KEY
   shortId     = $SHORT_ID
   gRPC svc    = ${PREFIX}_grpc
   VLESS flow  = <ПУСТО>  ← не xtls-rprx-vision
   Reality dest (gRPC/XHTTP) = ${BEST_RU_DEST}

 Файлы ещё:
   $RU_SNI_OUT

 Что сделать в панели (обязательно):
   1. Config Profiles → вставь $JSON_OUT
   2. Node → включи Active Inbounds: ${PREFIX}-vless/hy2/grpc/xhttp
   3. Hosts → по файлу $HOSTS_OUT (flow пустой!)
   4. Клиенты → обновить подписку
═══════════════════════════════════════════════════════════
EOF
  echo ""
  echo "----- HOSTS (кратко) -----"
  grep -E 'DOMAIN|publicKey|shortId|flow|serviceName|reality_dest|## ' "$HOSTS_OUT" | head -40
  echo ""
  echo "----- TOP RU SNI -----"
  grep -E '^(BEST|TOP3|[0-9]+\t)' "$RU_SNI_OUT" 2>/dev/null | head -8 || true
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
  run_tests
  echo "BEST_RU_DEST=${BEST_RU_DEST}"
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
  if [[ "$DO_ALL" != "true" && "$AUTO_YES" != "true" ]]; then
    SELECTED=("hy2" "grpc" "xhttp")
  fi
  log_ok "Протоколы: vless + ${SELECTED[*]}"

  open_port 443 tcp "VLESS Reality"
  open_port 80 tcp "HTTP"
  open_port 443 udp "HY2"
  open_port 8443 tcp "gRPC"
  open_port 4443 tcp "XHTTP"

  sync_hy2_certs
  setup_cron
  resolve_keys
  probe_ru_snis
  build_outputs
  run_tests
  finalize
}

main "$@"
