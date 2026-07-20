#!/bin/bash
#
# remnanode-selfsteal-setup.sh
# Remnawave Node Multi-Protocol Setup — SelfSteal Fixed
#
# Исправляет типичные ошибки Rezzosoft/converter:
#   - Reality target → /dev/shm/nginx.sock + xver=1
#   - serverNames → SELF_STEAL_DOMAIN (не чужой сайт)
#   - HY2 certs = реальные файлы в /dev/shm (не symlink в контейнер)
#   - UFW 443/tcp+udp, 8443, 4443
#   - генерирует готовый Config Profile JSON
#
# Запуск:
#   bash <(curl -fsSL https://raw.githubusercontent.com/lurk200/remnanode-selfsteal-setup/main/setup.sh) --yes --all
#
set -euo pipefail

VERSION="1.0.2-selfsteal"
OUT_DIR="/opt/remnanode"
JSON_OUT="${OUT_DIR}/config-profile-selfsteal.json"
CERT_PERSIST="${OUT_DIR}/certs"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_ok()    { echo -e "${GREEN}[✓]${NC} $1"; }
log_info()  { echo -e "${BLUE}[•]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; }
fatal()     { log_error "$1"; [[ -n "${2:-}" ]] && log_warn "$2"; exit 1; }

AUTO_YES=false
DO_ALL=false
TAG_PREFIX=""
DOMAIN_OVERRIDE=""
REUSE_KEYS=false
PRIVATE_KEY_OPT=""
PUBLIC_KEY_OPT=""
SHORT_ID_OPT=""

usage() {
  cat <<'USAGE'
Usage: setup.sh [options]

  --yes, -y          без вопросов (все протоколы)
  --all              hy2 + grpc + xhttp
  --domain NAME      selfsteal домен
  --prefix TAG       префикс тегов (ger / pl / yt / www)
  --reuse-keys       взять ключи из /opt/remnanode/reality-client-hints.txt
  --private-key K    свой Reality privateKey
  --public-key K     соответствующий publicKey
  --short-id HEX     shortId
  -h, --help         help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y) AUTO_YES=true; shift ;;
    --all) DO_ALL=true; shift ;;
    --domain) DOMAIN_OVERRIDE="$2"; shift 2 ;;
    --prefix) TAG_PREFIX="$2"; shift 2 ;;
    --reuse-keys) REUSE_KEYS=true; shift ;;
    --private-key) PRIVATE_KEY_OPT="$2"; shift 2 ;;
    --public-key) PUBLIC_KEY_OPT="$2"; shift 2 ;;
    --short-id) SHORT_ID_OPT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) fatal "Неизвестный аргумент: $1" ;;
  esac
done

show_logo() {
  cat <<'EOF'
╔══════════════════════════════════════════════════════════════════╗
║          Remnawave SelfSteal Multi-Protocol Setup                ║
║                     fixed · auto JSON · v1.0.2                   ║
╚══════════════════════════════════════════════════════════════════╝
EOF
}

need_cmd() { command -v "$1" &>/dev/null || fatal "Нужна команда: $1"; }

detect_domain() {
  if [[ -n "$DOMAIN_OVERRIDE" ]]; then
    DOMAIN="$DOMAIN_OVERRIDE"
    return
  fi

  if [[ -f /opt/remnanode/docker-compose.yml ]]; then
    DOMAIN=$(grep -E 'SELF_STEAL_DOMAIN=' /opt/remnanode/docker-compose.yml 2>/dev/null \
      | head -1 | sed -E 's/.*SELF_STEAL_DOMAIN=//;s/["'\'']//g' | tr -d '[:space:]' || true)
    [[ -n "${DOMAIN:-}" ]] && return
  fi

  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'caddy-remnawave'; then
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
  if [[ -n "$crt" ]]; then
    DOMAIN=$(basename "$crt" .crt)
    return
  fi

  fatal "Не удалось определить SELF_STEAL_DOMAIN" "Запустите с --domain ger.lurk-vpn.online"
}

detect_prefix() {
  if [[ -n "$TAG_PREFIX" ]]; then
    PREFIX="$TAG_PREFIX"
    return
  fi
  local sub
  sub=$(echo "$DOMAIN" | cut -d. -f1)
  case "$sub" in
    ger|pl|yt|ru|de|nl|fi|www) PREFIX="$sub" ;;
    *) PREFIX="www" ;;
  esac
}

find_certs() {
  CERT_PATH=""
  KEY_PATH=""

  if [[ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]]; then
    CERT_PATH="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
    KEY_PATH="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
    return
  fi

  local crt key
  crt=$(find /var/lib/docker/volumes/caddy_data/_data -name "${DOMAIN}.crt" 2>/dev/null | head -1 || true)
  key=$(find /var/lib/docker/volumes/caddy_data/_data -name "${DOMAIN}.key" 2>/dev/null | head -1 || true)
  if [[ -n "$crt" && -n "$key" ]]; then
    CERT_PATH="$crt"
    KEY_PATH="$key"
    return
  fi

  fatal "Сертификат для ${DOMAIN} не найден" "Нужен LE live/ или Caddy volume caddy_data"
}

preflight() {
  log_info "Проверки окружения..."
  [[ "$EUID" -eq 0 ]] || fatal "Нужен root" "sudo bash $0"
  log_ok "root"

  need_cmd docker
  docker info &>/dev/null || fatal "Docker daemon не запущен"
  log_ok "Docker"

  docker inspect remnanode &>/dev/null || fatal "Контейнер remnanode не найден"
  local st
  st=$(docker inspect remnanode --format '{{.State.Status}}')
  [[ "$st" == "running" ]] || fatal "remnanode не running ($st)"
  log_ok "remnanode running"

  docker inspect remnanode --format '{{json .Mounts}}' | grep -q '/dev/shm' \
    || fatal "/dev/shm не примонтирован в remnanode"
  log_ok "/dev/shm mounted"

  if [[ -S /dev/shm/nginx.sock ]]; then
    log_ok "nginx.sock есть"
  else
    log_warn "/dev/shm/nginx.sock нет — Caddy SelfSteal должен создать socket"
  fi

  detect_domain
  detect_prefix
  find_certs
  log_ok "Домен: ${DOMAIN}"
  log_ok "Префикс тегов: ${PREFIX}"
  log_ok "Cert: ${CERT_PATH}"

  UFW_ACTIVE=false
  if command -v ufw &>/dev/null; then
    if ufw status 2>/dev/null | head -1 | grep -qi active; then
      UFW_ACTIVE=true
      log_ok "UFW active"
    else
      log_warn "UFW не active"
    fi
  fi
  echo ""
}

open_port() {
  local port="$1" proto="$2" desc="$3"
  [[ "$UFW_ACTIVE" != "true" ]] && return 0
  if ufw status 2>/dev/null | grep -qE "^${port}/${proto}[[:space:]]+ALLOW"; then
    log_ok "UFW ${port}/${proto} уже открыт ($desc)"
    return 0
  fi
  ufw allow "${port}/${proto}" comment "$desc" >/dev/null
  log_ok "UFW ${port}/${proto} открыт ($desc)"
}

sync_hy2_certs() {
  log_info "HY2 certs → /dev/shm (реальные файлы, не symlink)..."

  if [[ -L /dev/shm/hysteria_cert.pem ]]; then rm -f /dev/shm/hysteria_cert.pem; fi
  if [[ -L /dev/shm/hysteria_key.pem ]]; then rm -f /dev/shm/hysteria_key.pem; fi

  cp -L "$CERT_PATH" /dev/shm/hysteria_cert.pem
  cp -L "$KEY_PATH"  /dev/shm/hysteria_key.pem
  chmod 644 /dev/shm/hysteria_cert.pem
  chmod 600 /dev/shm/hysteria_key.pem

  mkdir -p "$CERT_PERSIST"
  cp -f /dev/shm/hysteria_cert.pem "$CERT_PERSIST/"
  cp -f /dev/shm/hysteria_key.pem  "$CERT_PERSIST/"
  chmod 600 "$CERT_PERSIST/hysteria_key.pem"

  # Не делаем ln сам на себя, если cert уже в LE live/
  local le_full="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
  if [[ "$CERT_PATH" == "$le_full" ]]; then
    log_ok "Let's Encrypt live/ уже на месте — symlink не нужен"
  else
    mkdir -p "/etc/letsencrypt/live/${DOMAIN}"
    ln -sfn "$CERT_PATH" "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
    ln -sfn "$KEY_PATH"  "/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
    ln -sfn "$CERT_PATH" "/etc/letsencrypt/live/${DOMAIN}/cert.pem"
    ln -sfn "$CERT_PATH" "/etc/letsencrypt/live/${DOMAIN}/chain.pem"
    log_ok "LE live/ symlink → источник certs"
  fi

  if ! docker exec remnanode openssl x509 -in /dev/shm/hysteria_cert.pem -noout -subject &>/dev/null; then
    fatal "Контейнер не читает /dev/shm/hysteria_cert.pem"
  fi
  local subj
  subj=$(docker exec remnanode openssl x509 -in /dev/shm/hysteria_cert.pem -noout -subject 2>/dev/null || true)
  log_ok "HY2 cert OK ($subj)"
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

  if crontab -l 2>/dev/null | grep -q 'restore-hy2-certs'; then
    log_ok "Cron restore уже есть"
  else
    (
      crontab -l 2>/dev/null | grep -v hysteria_cert || true
      echo "@reboot /opt/remnanode/restore-hy2-certs.sh"
      echo "15 4 * * * /opt/remnanode/restore-hy2-certs.sh"
    ) | crontab -
    log_ok "Cron @reboot + daily restore добавлен"
  fi
}

gen_reality_keys() {
  if [[ -n "$PRIVATE_KEY_OPT" ]]; then
    PRIVATE_KEY="$PRIVATE_KEY_OPT"
    PUBLIC_KEY="${PUBLIC_KEY_OPT:-}"
    SHORT_ID="${SHORT_ID_OPT:-$(openssl rand -hex 4)}"
    [[ -n "$PUBLIC_KEY" ]] || log_warn "publicKey не задан — возьми из панели/старого клиента"
    log_ok "Используем переданные Reality keys (shortId=${SHORT_ID})"
    return
  fi

  if [[ "$REUSE_KEYS" == "true" && -f "${OUT_DIR}/reality-client-hints.txt" ]]; then
    PRIVATE_KEY=$(grep '^privateKey=' "${OUT_DIR}/reality-client-hints.txt" | cut -d= -f2-)
    PUBLIC_KEY=$(grep '^publicKey=' "${OUT_DIR}/reality-client-hints.txt" | cut -d= -f2-)
    SHORT_ID=$(grep '^shortId=' "${OUT_DIR}/reality-client-hints.txt" | cut -d= -f2-)
    if [[ -n "$PRIVATE_KEY" && -n "$SHORT_ID" ]]; then
      log_ok "Reuse keys из reality-client-hints.txt (shortId=${SHORT_ID})"
      return
    fi
    log_warn "hints файл есть, но ключи пустые — генерируем новые"
  fi

  log_info "Генерация НОВЫХ Reality ключей (клиентов нужно обновить)..."
  local out=""
  if out=$(docker exec remnanode /usr/local/bin/xray x25519 2>/dev/null); then
    :
  elif out=$(docker exec remnanode xray x25519 2>/dev/null); then
    :
  else
    fatal "Не удалось выполнить xray x25519 в remnanode"
  fi

  PRIVATE_KEY=$(echo "$out" | grep -iE 'Private( key)?:' | head -1 | awk '{print $NF}' | tr -d '\r')
  PUBLIC_KEY=$(echo "$out" | grep -iE 'Public( key)?:' | head -1 | awk '{print $NF}' | tr -d '\r')
  [[ -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" ]] || fatal "Не распарсил x25519 вывод: $out"

  SHORT_ID=$(openssl rand -hex 4)
  log_ok "Reality keys готовы (shortId=${SHORT_ID})"
}

select_protos() {
  SELECTED=("hy2" "grpc" "xhttp")
  if [[ "$DO_ALL" == "true" || "$AUTO_YES" == "true" ]]; then
    log_ok "Протоколы: hy2 grpc xhttp (+ базовый vless/reality)"
    return
  fi

  echo ""
  log_info "Доп. протоколы (базовый VLESS Reality :443 всегда):"
  echo "  [1] Hysteria2  443/udp"
  echo "  [2] gRPC       8443/tcp"
  echo "  [3] XHTTP      4443/tcp"
  echo "  [4] Все"
  echo -n "Выбор [4]: "
  read -r user_input || true
  user_input=${user_input:-4}
  SELECTED=()
  case "$user_input" in
    *4*|all|ALL) SELECTED=("hy2" "grpc" "xhttp") ;;
    *)
      [[ "$user_input" == *1* ]] && SELECTED+=("hy2")
      [[ "$user_input" == *2* ]] && SELECTED+=("grpc")
      [[ "$user_input" == *3* ]] && SELECTED+=("xhttp")
      [[ ${#SELECTED[@]} -eq 0 ]] && SELECTED=("hy2" "grpc" "xhttp")
      ;;
  esac
  log_ok "Выбрано: ${SELECTED[*]}"
}

build_json() {
  local tag_vless="${PREFIX}-vless-443"
  local tag_hy2="${PREFIX}-hy2-443"
  local tag_grpc="${PREFIX}-grpc-8443"
  local tag_xhttp="${PREFIX}-xhttp-4443"
  local svc_grpc="${PREFIX}_grpc"

  python3 - "$JSON_OUT" <<'PY' || fatal "python3 нужен для сборки JSON"
import json, os, sys

out = sys.argv[1]
domain = os.environ["DOMAIN"]
prefix = os.environ["PREFIX"]
priv = os.environ["PRIVATE_KEY"]
pub = os.environ.get("PUBLIC_KEY", "")
short = os.environ["SHORT_ID"]
selected = os.environ.get("SELECTED", "hy2 grpc xhttp").split()

tag_vless = f"{prefix}-vless-443"
tag_hy2 = f"{prefix}-hy2-443"
tag_grpc = f"{prefix}-grpc-8443"
tag_xhttp = f"{prefix}-xhttp-4443"
svc_grpc = f"{prefix}_grpc"

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
      "grpcSettings": {"multiMode": False, "serviceName": svc_grpc},
      "realitySettings": {
        "dest": "www.apple.com:443",
        "show": False,
        "xver": 0,
        "spiderX": "",
        "shortIds": [short],
        "privateKey": priv,
        "serverNames": [domain],
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
        "dest": "www.apple.com:443",
        "show": False,
        "xver": 0,
        "spiderX": "",
        "shortIds": [short],
        "privateKey": priv,
        "serverNames": [domain],
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
  "routing": {
    "rules": [
      {"ip": ["geoip:private"], "outboundTag": "BLOCK"},
      {"domain": ["geosite:private"], "outboundTag": "BLOCK"},
      {"protocol": ["bittorrent"], "outboundTag": "BLOCK"},
    ]
  },
}

with open(out, "w", encoding="utf-8") as f:
  json.dump(cfg, f, indent=2, ensure_ascii=False)
  f.write("\n")

hints = os.path.join(os.path.dirname(out), "reality-client-hints.txt")
with open(hints, "w", encoding="utf-8") as f:
  f.write(f"domain={domain}\n")
  f.write(f"publicKey={pub}\n")
  f.write(f"shortId={short}\n")
  f.write(f"privateKey={priv}\n")
  f.write(f"sni={domain}\n")
  f.write(f"address={domain}\n")
  f.write("vless_port=443\n")
  f.write("hy2_port=443/udp\n")
  f.write("grpc_port=8443\n")
  f.write(f"grpc_service={svc_grpc}\n")
  f.write("xhttp_port=4443\n")
PY

  log_ok "JSON: ${JSON_OUT}"
  log_ok "Client hints: ${OUT_DIR}/reality-client-hints.txt"
}

apply_firewall() {
  open_port 443 tcp "VLESS Reality"
  open_port 80 tcp "HTTP/ACME"
  for p in "${SELECTED[@]}"; do
    case "$p" in
      hy2)   open_port 443 udp "Hysteria2" ;;
      grpc)  open_port 8443 tcp "gRPC" ;;
      xhttp) open_port 4443 tcp "XHTTP" ;;
    esac
  done
}

verify() {
  echo ""
  log_info "Проверки..."
  ss -tulpn 2>/dev/null | grep -E ':443|:8443|:4443|:2222' || true

  if curl -skI --connect-timeout 8 --max-time 12 "https://${DOMAIN}/" 2>/dev/null | head -1 | grep -qE '200|HTTP'; then
    local srv
    srv=$(curl -skI --connect-timeout 8 --max-time 12 "https://${DOMAIN}/" 2>/dev/null | grep -i '^server:' | head -1 || true)
    log_ok "SelfSteal https://${DOMAIN}/ отвечает (${srv//$'\r'/})"
  else
    log_warn "SelfSteal HTTPS пока не 200 — после Save профиля в панели проверь снова"
  fi
}

finalize() {
  echo ""
  echo "═══════════════════════════════════════════════════════════"
  echo -e "${GREEN}✓ Готово${NC}"
  echo "═══════════════════════════════════════════════════════════"
  echo " Домен:        ${DOMAIN}"
  echo " PublicKey:    ${PUBLIC_KEY}"
  echo " ShortId:      ${SHORT_ID}"
  echo " JSON:         ${JSON_OUT}"
  echo ""
  echo -e "${BLUE}Что сделать в панели:${NC}"
  echo " 1. Config Profiles → вставь JSON из файла выше"
  echo " 2. Nodes → нода → выбери этот профиль"
  echo " 3. Включи ВСЕ Active Inbounds (${PREFIX}-vless/hy2/grpc/xhttp)"
  echo " 4. Save"
  echo ""
  echo -e "${YELLOW}Важно:${NC} клиентам SNI/Address = ${DOMAIN} (не чужой сайт)"
  echo " Public key для клиентов: ${PUBLIC_KEY}"
  echo "═══════════════════════════════════════════════════════════"
  if [[ "$AUTO_YES" != "true" ]]; then
    echo ""
    echo "Показать JSON? [y/N]"
    read -r show || true
    if [[ "${show:-}" =~ ^[Yy]$ ]]; then
      cat "$JSON_OUT"
    fi
  else
    echo "(auto) JSON сохранён в файл"
  fi
}

main() {
  clear
  show_logo
  echo " v${VERSION}"
  echo ""
  mkdir -p "$OUT_DIR"
  preflight
  select_protos
  apply_firewall
  sync_hy2_certs
  setup_cron
  gen_reality_keys

  export DOMAIN PREFIX PRIVATE_KEY PUBLIC_KEY SHORT_ID
  export SELECTED="${SELECTED[*]}"
  need_cmd python3
  build_json
  verify
  finalize
}

main "$@"
