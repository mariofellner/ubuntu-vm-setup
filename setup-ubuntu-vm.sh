#!/usr/bin/env bash
#
# setup-ubuntu-vm.sh
# Initial-Setup für eine frische Ubuntu-24.04-Desktop-VM (VMware Workstation)
# hinter einem Corporate-Proxy.
#
#   * Konfiguriert HTTP/HTTPS-Proxy für Shell, APT, wget, curl, snap
#   * Installiert open-vm-tools (+ open-vm-tools-desktop)
#   * Installiert und aktiviert den SSH-Server
#   * Öffnet ggf. Port 22 in ufw
#   * Führt am Ende Self-Tests aus
#
# Autor: Mario Fellner <mario.fellner@outlook.at>
# Lizenz: MIT
#
# Usage:
#   sudo ./setup-ubuntu-vm.sh                       # fragt interaktiv
#   sudo ./setup-ubuntu-vm.sh --host proxy.example.com --port 8080
#   sudo PROXY_HOST=proxy.example.com PROXY_PORT=8080 ./setup-ubuntu-vm.sh
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Konstanten / Defaults
# ---------------------------------------------------------------------------
SCRIPT_NAME="$(basename "$0")"
LOG_FILE="/var/log/setup-ubuntu-vm.log"

PROXY_HOST="${PROXY_HOST:-}"
PROXY_PORT="${PROXY_PORT:-}"
PROXY_USER="${PROXY_USER:-}"
PROXY_PASS="${PROXY_PASS:-}"
NO_PROXY_LIST="${NO_PROXY_LIST:-localhost,127.0.0.1,::1,.local}"
SKIP_PROXY="${SKIP_PROXY:-0}"
ASSUME_YES="${ASSUME_YES:-0}"

# ---------------------------------------------------------------------------
# Hilfsfunktionen
# ---------------------------------------------------------------------------
RED="\033[0;31m"; GREEN="\033[0;32m"; YELLOW="\033[0;33m"; BLUE="\033[0;34m"; NC="\033[0m"

log()  { echo -e "${BLUE}[INFO]${NC}  $*" | tee -a "$LOG_FILE"; }
ok()   { echo -e "${GREEN}[ OK ]${NC}  $*" | tee -a "$LOG_FILE"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*" | tee -a "$LOG_FILE"; }
err()  { echo -e "${RED}[FAIL]${NC}  $*" | tee -a "$LOG_FILE" >&2; }

usage() {
  cat <<EOF
$SCRIPT_NAME – Ubuntu-24.04-VM Erstbereitstellung hinter Proxy

Optionen:
  --host <proxy>       Proxy-Hostname oder IP (z. B. proxy.example.com)
  --port <port>        Proxy-Port (z. B. 8080)
  --user <user>        (optional) Proxy-Benutzer
  --pass <passwort>    (optional) Proxy-Passwort
  --no-proxy <liste>   Komma-Liste der NO_PROXY-Einträge
                       Default: $NO_PROXY_LIST
  --skip-proxy         Proxy-Konfiguration überspringen (direkte Verbindung)
  -y, --yes            Alle Rückfragen mit Ja beantworten
  -h, --help           Diese Hilfe anzeigen

Umgebungsvariablen:
  PROXY_HOST, PROXY_PORT, PROXY_USER, PROXY_PASS,
  NO_PROXY_LIST, SKIP_PROXY, ASSUME_YES
EOF
}

require_root() {
  if [[ $EUID -ne 0 ]]; then
    warn "Nicht als root gestartet – Re-Exec mit sudo …"
    exec sudo -E "$0" "$@"
  fi
}

url_encode() {
  # minimales URL-Encoding für Passwort-Sonderzeichen
  local s="$1" out=""
  local i c
  for (( i=0; i<${#s}; i++ )); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9._~-]) out+="$c" ;;
      *) out+=$(printf '%%%02X' "'$c") ;;
    esac
  done
  printf '%s' "$out"
}

confirm() {
  local prompt="$1"
  if [[ "$ASSUME_YES" == "1" ]]; then
    return 0
  fi
  local ans
  read -rp "$prompt [j/N] " ans
  [[ "$ans" =~ ^([jJ][aA]?|[yY]([eE][sS])?)$ ]]
}

# ---------------------------------------------------------------------------
# Arg-Parsing
# ---------------------------------------------------------------------------
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --host)       PROXY_HOST="$2"; shift 2 ;;
      --port)       PROXY_PORT="$2"; shift 2 ;;
      --user)       PROXY_USER="$2"; shift 2 ;;
      --pass)       PROXY_PASS="$2"; shift 2 ;;
      --no-proxy)   NO_PROXY_LIST="$2"; shift 2 ;;
      --skip-proxy) SKIP_PROXY=1; shift ;;
      -y|--yes)     ASSUME_YES=1; shift ;;
      -h|--help)    usage; exit 0 ;;
      *)            err "Unbekannte Option: $1"; usage; exit 2 ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Proxy-Konfiguration
# ---------------------------------------------------------------------------
collect_proxy_details() {
  if [[ "$SKIP_PROXY" == "1" ]]; then
    log "Proxy-Konfiguration wird übersprungen (--skip-proxy)."
    return 0
  fi

  if [[ -z "$PROXY_HOST" ]]; then
    read -rp "Proxy-Host (z. B. proxy.example.com): " PROXY_HOST
  fi
  if [[ -z "$PROXY_PORT" ]]; then
    read -rp "Proxy-Port  (z. B. 8080): " PROXY_PORT
  fi

  if [[ -z "$PROXY_HOST" || -z "$PROXY_PORT" ]]; then
    err "Proxy-Host oder -Port leer – Abbruch. (--skip-proxy zum Überspringen.)"
    exit 2
  fi

  if ! [[ "$PROXY_PORT" =~ ^[0-9]+$ ]] || (( PROXY_PORT < 1 || PROXY_PORT > 65535 )); then
    err "Ungültiger Port: $PROXY_PORT"
    exit 2
  fi

  # Anmeldedaten sind optional
  if [[ -n "$PROXY_USER" && -z "$PROXY_PASS" ]]; then
    read -rsp "Proxy-Passwort für $PROXY_USER: " PROXY_PASS
    echo
  fi
}

build_proxy_urls() {
  PROXY_AUTH=""
  PROXY_AUTH_DISPLAY=""
  if [[ -n "$PROXY_USER" ]]; then
    local enc_user enc_pass
    enc_user="$(url_encode "$PROXY_USER")"
    enc_pass="$(url_encode "$PROXY_PASS")"
    PROXY_AUTH="${enc_user}:${enc_pass}@"
    PROXY_AUTH_DISPLAY="${enc_user}:***@"
  fi
  HTTP_PROXY_URL="http://${PROXY_AUTH}${PROXY_HOST}:${PROXY_PORT}/"
  HTTPS_PROXY_URL="http://${PROXY_AUTH}${PROXY_HOST}:${PROXY_PORT}/"
  FTP_PROXY_URL="http://${PROXY_AUTH}${PROXY_HOST}:${PROXY_PORT}/"
  PROXY_URL_DISPLAY="http://${PROXY_AUTH_DISPLAY}${PROXY_HOST}:${PROXY_PORT}/"
  log "Verwende Proxy: $PROXY_URL_DISPLAY"
}

backup_file() {
  local f="$1"
  if [[ -f "$f" && ! -f "${f}.orig" ]]; then
    cp -a "$f" "${f}.orig"
  fi
}

write_shell_proxy() {
  local file="/etc/profile.d/99-proxy.sh"
  log "Schreibe Shell-Proxy → $file"
  cat > "$file" <<EOF
# Automatisch erzeugt von $SCRIPT_NAME – $(date -Iseconds)
# Corporate-Proxy für alle Login-Shells
export http_proxy="$HTTP_PROXY_URL"
export https_proxy="$HTTPS_PROXY_URL"
export ftp_proxy="$FTP_PROXY_URL"
export HTTP_PROXY="\$http_proxy"
export HTTPS_PROXY="\$https_proxy"
export FTP_PROXY="\$ftp_proxy"
export no_proxy="$NO_PROXY_LIST"
export NO_PROXY="\$no_proxy"
EOF
  chmod 0644 "$file"
}

write_environment_proxy() {
  local file="/etc/environment"
  backup_file "$file"
  log "Aktualisiere $file"
  # Vorherige Einträge entfernen
  sed -i -E '/^(http_proxy|https_proxy|ftp_proxy|no_proxy|HTTP_PROXY|HTTPS_PROXY|FTP_PROXY|NO_PROXY)=/d' "$file"
  {
    echo "http_proxy=\"$HTTP_PROXY_URL\""
    echo "https_proxy=\"$HTTPS_PROXY_URL\""
    echo "ftp_proxy=\"$FTP_PROXY_URL\""
    echo "no_proxy=\"$NO_PROXY_LIST\""
    echo "HTTP_PROXY=\"$HTTP_PROXY_URL\""
    echo "HTTPS_PROXY=\"$HTTPS_PROXY_URL\""
    echo "FTP_PROXY=\"$FTP_PROXY_URL\""
    echo "NO_PROXY=\"$NO_PROXY_LIST\""
  } >> "$file"
}

write_apt_proxy() {
  local file="/etc/apt/apt.conf.d/95proxy"
  log "Schreibe APT-Proxy → $file"
  cat > "$file" <<EOF
// Automatisch erzeugt von $SCRIPT_NAME – $(date -Iseconds)
Acquire::http::Proxy  "$HTTP_PROXY_URL";
Acquire::https::Proxy "$HTTPS_PROXY_URL";
Acquire::ftp::Proxy   "$FTP_PROXY_URL";
EOF
  chmod 0644 "$file"
}

write_wget_proxy() {
  local file="/etc/wgetrc"
  backup_file "$file"
  log "Aktualisiere $file"
  sed -i -E '/^\s*(http_proxy|https_proxy|ftp_proxy|use_proxy)\s*=/d' "$file"
  cat >> "$file" <<EOF

# Automatisch erzeugt von $SCRIPT_NAME
http_proxy  = $HTTP_PROXY_URL
https_proxy = $HTTPS_PROXY_URL
ftp_proxy   = $FTP_PROXY_URL
use_proxy   = on
EOF
}

write_curl_proxy() {
  # System-weit über /etc/skel und root-.curlrc wäre unsauber – wir setzen
  # deshalb global über /etc/profile.d (curl liest $https_proxy).
  # Zusätzlich: /root/.curlrc für nicht-interaktive root-Sessions.
  local file="/root/.curlrc"
  log "Schreibe $file"
  cat > "$file" <<EOF
# Automatisch erzeugt von $SCRIPT_NAME
proxy = "$HTTP_PROXY_URL"
EOF
  chmod 0600 "$file"
}

configure_snap_proxy() {
  if command -v snap >/dev/null 2>&1; then
    log "Konfiguriere snap-Proxy"
    snap set system proxy.http="$HTTP_PROXY_URL"   || warn "snap proxy.http konnte nicht gesetzt werden"
    snap set system proxy.https="$HTTPS_PROXY_URL" || warn "snap proxy.https konnte nicht gesetzt werden"
  fi
}

configure_proxy() {
  if [[ "$SKIP_PROXY" == "1" ]]; then
    return 0
  fi
  log "=== Proxy-Konfiguration ==="
  build_proxy_urls
  write_shell_proxy
  write_environment_proxy
  write_apt_proxy
  write_wget_proxy
  write_curl_proxy
  configure_snap_proxy

  # Damit die Proxy-Variablen auch in DIESER Shell sofort aktiv sind:
  export http_proxy="$HTTP_PROXY_URL"
  export https_proxy="$HTTPS_PROXY_URL"
  export ftp_proxy="$FTP_PROXY_URL"
  export HTTP_PROXY="$HTTP_PROXY_URL"
  export HTTPS_PROXY="$HTTPS_PROXY_URL"
  export FTP_PROXY="$FTP_PROXY_URL"
  export no_proxy="$NO_PROXY_LIST"
  export NO_PROXY="$NO_PROXY_LIST"

  ok "Proxy-Konfiguration abgeschlossen."
}

# ---------------------------------------------------------------------------
# Paket-Installation
# ---------------------------------------------------------------------------
apt_update() {
  log "apt update ..."
  if ! apt-get update; then
    err "apt update fehlgeschlagen. Proxy-Einstellungen prüfen!"
    return 1
  fi
  ok "apt-Paketlisten aktualisiert."
}

install_packages() {
  log "=== Pakete installieren ==="
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y --no-install-recommends \
    open-vm-tools \
    open-vm-tools-desktop \
    openssh-server \
    ca-certificates \
    curl \
    wget \
    net-tools
  ok "Pakete installiert."
}

# ---------------------------------------------------------------------------
# Dienste aktivieren
# ---------------------------------------------------------------------------
enable_services() {
  log "=== Dienste aktivieren ==="
  systemctl enable --now open-vm-tools.service || warn "open-vm-tools.service konnte nicht aktiviert werden"

  # Ubuntu 24.04 nutzt Socket-Activation: ssh.socket lauscht auf Port 22
  # und startet ssh.service on-demand. Wir enablen beides explizit, damit
  # die Reihenfolge robust ist – egal welches systemd-Default aktiv ist.
  if systemctl list-unit-files ssh.socket >/dev/null 2>&1; then
    systemctl enable --now ssh.socket  || warn "ssh.socket konnte nicht aktiviert werden"
  fi
  systemctl enable --now ssh.service   || warn "ssh.service konnte nicht aktiviert werden"

  ok "Dienste aktiviert."
}

# ---------------------------------------------------------------------------
# Firewall (UFW)
# ---------------------------------------------------------------------------
configure_firewall() {
  if command -v ufw >/dev/null 2>&1; then
    if ufw status 2>/dev/null | grep -q "Status: active"; then
      log "UFW ist aktiv – öffne Port 22/tcp"
      ufw allow OpenSSH || ufw allow 22/tcp || warn "UFW-Regel konnte nicht gesetzt werden"
    else
      log "UFW inaktiv – überspringe Firewall-Konfiguration."
    fi
  fi
}

# ---------------------------------------------------------------------------
# Self-Tests
# ---------------------------------------------------------------------------
run_tests() {
  log "=== Self-Tests ==="
  local rc=0

  # 1) SSH-Dienst läuft?
  #    Auf Ubuntu 24.04 kann entweder ssh.service direkt aktiv sein ODER
  #    nur ssh.socket (Socket-Activation, Service startet on-demand).
  if systemctl is-active --quiet ssh.service \
     || systemctl is-active --quiet ssh.socket; then
    ok "SSH-Dienst aktiv (ssh.service oder ssh.socket)."
  else
    err "Weder ssh.service noch ssh.socket läuft."
    rc=1
  fi

  # 2) SSH-Port lauscht?
  if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE '(^|:)22$'; then
    ok "Port 22 lauscht."
  else
    err "Port 22 lauscht nicht."
    rc=1
  fi

  # 2b) SSH-Handshake mit localhost: banner abholen ohne Login
  #     (beweist, dass sshd tatsächlich antwortet)
  if command -v nc >/dev/null 2>&1; then
    if timeout 5 bash -c 'exec 3<>/dev/tcp/127.0.0.1/22; head -c 4 <&3' 2>/dev/null | grep -q "SSH-"; then
      ok "SSH-Banner auf Port 22 erkannt – sshd antwortet."
    else
      warn "Kein SSH-Banner auf 127.0.0.1:22 – prüfe sshd-Log."
    fi
  fi

  # 2c) Passwort-Authentifizierung überhaupt erlaubt?
  local pw_auth
  pw_auth="$(sshd -T 2>/dev/null | awk '/^passwordauthentication/ {print $2}')"
  case "$pw_auth" in
    yes) ok "PasswordAuthentication ist aktiv." ;;
    no)  warn "PasswordAuthentication=no – Login nur mit SSH-Key möglich." ;;
    *)   warn "PasswordAuthentication-Status unbekannt." ;;
  esac

  # 3) open-vm-tools läuft?
  if systemctl is-active --quiet open-vm-tools.service; then
    ok "open-vm-tools.service läuft."
  else
    warn "open-vm-tools.service läuft nicht (evtl. keine VMware-Umgebung)."
  fi

  # 4) APT-Proxy funktioniert?
  #    APT::Update::Error-Mode=any sorgt dafür, dass auch partielle Fehler
  #    (z. B. unerreichbarer Proxy) einen Exit-Code != 0 erzeugen.
  if [[ "$SKIP_PROXY" != "1" ]]; then
    if apt-get \
         -o Acquire::http::Timeout=10 \
         -o Acquire::https::Timeout=10 \
         -o APT::Update::Error-Mode=any \
         update >/dev/null 2>&1; then
      ok "apt update über Proxy erfolgreich."
    else
      err "apt update über Proxy fehlgeschlagen."
      rc=1
    fi
  fi

  # 5) IP-Adresse ermitteln
  local ipv4
  ipv4="$(hostname -I 2>/dev/null | awk '{print $1}')"
  if [[ -n "$ipv4" ]]; then
    ok "Diese VM ist per SSH erreichbar unter: ssh <user>@$ipv4"
  fi

  return $rc
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"
  require_root "$@"

  # Log-Datei initialisieren (nach require_root, weil /var/log root-only)
  : > "$LOG_FILE"
  chmod 0640 "$LOG_FILE"
  log "=== $SCRIPT_NAME gestartet am $(date -Iseconds) ==="

  # OS-Check
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    log "Erkannt: $PRETTY_NAME"
    if [[ "${ID:-}" != "ubuntu" ]]; then
      warn "Dieses Script wurde für Ubuntu geschrieben – fahre trotzdem fort."
    fi
  fi

  collect_proxy_details
  configure_proxy
  apt_update
  install_packages
  enable_services
  configure_firewall

  if run_tests; then
    ok "=== Setup erfolgreich abgeschlossen ==="
  else
    err "=== Setup mit Fehlern abgeschlossen – siehe $LOG_FILE ==="
    exit 1
  fi
}

main "$@"