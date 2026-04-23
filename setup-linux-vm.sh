#!/usr/bin/env bash
#
# setup-linux-vm.sh
# Initial-Setup für eine frische Linux-VM (VMware Workstation) hinter einem
# Corporate-Proxy. Unterstützt Debian-Familie (Ubuntu) und RHEL-Familie
# (Rocky Linux, Fedora).
#
#   * Konfiguriert HTTP/HTTPS-Proxy für Shell, Paketmanager, wget, curl, snap
#   * Installiert open-vm-tools (+ open-vm-tools-desktop bei Desktop-Variante)
#   * Installiert und aktiviert den SSH-Server
#   * Öffnet Port 22 in der jeweiligen Firewall (ufw oder firewalld)
#   * Führt am Ende Self-Tests aus
#
# Unterstützte Distros (automatische Erkennung):
#   * Ubuntu 22.04 / 24.04 / 26.04 LTS (Desktop und Server)
#   * Rocky Linux 9.x und 10.x (Workstation und Server)
#   * Fedora 42 / 43 / 44 (Workstation und Server)
#
# Autor: Mario Fellner <mario.fellner@outlook.at>
# Lizenz: MIT
#
# Usage:
#   sudo ./setup-linux-vm.sh                       # fragt interaktiv
#   sudo ./setup-linux-vm.sh --host proxy.example.com --port 8080
#   sudo PROXY_HOST=proxy.example.com PROXY_PORT=8080 ./setup-linux-vm.sh
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Konstanten / Defaults
# ---------------------------------------------------------------------------
SCRIPT_NAME="$(basename "$0")"
LOG_FILE="/var/log/setup-linux-vm.log"

PROXY_HOST="${PROXY_HOST:-}"
PROXY_PORT="${PROXY_PORT:-}"
PROXY_USER="${PROXY_USER:-}"
PROXY_PASS="${PROXY_PASS:-}"
NO_PROXY_LIST="${NO_PROXY_LIST:-localhost,127.0.0.1,::1,.local}"
SKIP_PROXY="${SKIP_PROXY:-0}"
ASSUME_YES="${ASSUME_YES:-0}"
# VARIANT: "desktop" | "server" | "" (= autodetect)
VARIANT="${VARIANT:-}"
# DISTRO_FAMILY: "debian" | "rhel" | "" (= autodetect)
DISTRO_FAMILY="${DISTRO_FAMILY:-}"

# Unterstützte Versionen (informativ – der Code versucht trotzdem zu laufen)
SUPPORTED_UBUNTU_VERSIONS=("22.04" "24.04" "26.04")
SUPPORTED_ROCKY_MAJORS=("9" "10")
SUPPORTED_FEDORA_VERSIONS=("42" "43" "44")

# Distro-Details – werden in detect_distro() gesetzt
DISTRO_ID=""
DISTRO_VERSION_ID=""
DISTRO_PRETTY=""
PKGMGR=""            # apt-get | dnf
SSH_UNITS=""         # "ssh ssh.socket" (Ubuntu 24+), "ssh" (Ubuntu 22), "sshd" (Rocky/Fedora)
FIREWALL=""          # ufw | firewalld | none

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
$SCRIPT_NAME – Linux-VM Erstbereitstellung hinter Proxy

Unterstützte Distros (Autodetect):
  - Ubuntu       22.04 / 24.04 / 26.04 LTS
  - Rocky Linux  9.x / 10.x
  - Fedora       42 / 43 / 44
Beide Varianten (Desktop / Server) werden automatisch erkannt.

Optionen:
  --host <proxy>       Proxy-Hostname oder IP (z. B. proxy.example.com)
  --port <port>        Proxy-Port (z. B. 8080)
  --user <user>        (optional) Proxy-Benutzer
  --pass <passwort>    (optional) Proxy-Passwort
  --no-proxy <liste>   Komma-Liste der NO_PROXY-Einträge
                       Default: $NO_PROXY_LIST
  --skip-proxy         Proxy-Konfiguration überspringen (direkte Verbindung)
  --server             Als Server behandeln (kein open-vm-tools-desktop)
  --desktop            Als Desktop behandeln (mit open-vm-tools-desktop)
                       (ohne --server/--desktop wird automatisch erkannt)
  -y, --yes            Alle Rückfragen mit Ja beantworten
  -h, --help           Diese Hilfe anzeigen

Umgebungsvariablen:
  PROXY_HOST, PROXY_PORT, PROXY_USER, PROXY_PASS,
  NO_PROXY_LIST, SKIP_PROXY, ASSUME_YES, VARIANT, DISTRO_FAMILY
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

backup_file() {
  local f="$1"
  if [[ -f "$f" && ! -f "${f}.orig" ]]; then
    cp -a "$f" "${f}.orig"
  fi
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
      --server)     VARIANT="server"; shift ;;
      --desktop)    VARIANT="desktop"; shift ;;
      -y|--yes)     ASSUME_YES=1; shift ;;
      -h|--help)    usage; exit 0 ;;
      *)            err "Unbekannte Option: $1"; usage; exit 2 ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Distro- und Variant-Detection
# ---------------------------------------------------------------------------
detect_distro() {
  if [[ ! -r /etc/os-release ]]; then
    err "/etc/os-release fehlt – Distribution kann nicht erkannt werden."
    exit 3
  fi
  # shellcheck disable=SC1091
  . /etc/os-release
  DISTRO_ID="${ID:-unknown}"
  DISTRO_VERSION_ID="${VERSION_ID:-unknown}"
  DISTRO_PRETTY="${PRETTY_NAME:-$DISTRO_ID $DISTRO_VERSION_ID}"

  # DISTRO_FAMILY ableiten
  if [[ -z "$DISTRO_FAMILY" ]]; then
    case "$DISTRO_ID" in
      ubuntu|debian)       DISTRO_FAMILY="debian" ;;
      rocky|rhel|centos|almalinux|fedora|ol)  DISTRO_FAMILY="rhel" ;;
      *)
        # Fallback über ID_LIKE
        case "${ID_LIKE:-}" in
          *debian*) DISTRO_FAMILY="debian" ;;
          *rhel*|*fedora*) DISTRO_FAMILY="rhel" ;;
          *)
            err "Unbekannte Distribution: $DISTRO_ID (ID_LIKE=${ID_LIKE:-}). Mit DISTRO_FAMILY=debian|rhel überschreiben."
            exit 3
            ;;
        esac
        ;;
    esac
  fi

  # Paketmanager, SSH-Units, Firewall ableiten
  case "$DISTRO_FAMILY" in
    debian)
      PKGMGR="apt-get"
      # ssh.socket-Activation ab Ubuntu 24.04 / Debian 13
      if command -v systemctl >/dev/null 2>&1 \
         && systemctl list-unit-files 2>/dev/null | grep -q "^ssh\.socket"; then
        SSH_UNITS="ssh ssh.socket"
      else
        SSH_UNITS="ssh"
      fi
      FIREWALL="ufw"
      ;;
    rhel)
      if command -v dnf >/dev/null 2>&1; then
        PKGMGR="dnf"
      elif command -v yum >/dev/null 2>&1; then
        PKGMGR="yum"
      else
        err "Weder dnf noch yum gefunden auf RHEL-artigem System."
        exit 3
      fi
      SSH_UNITS="sshd"
      FIREWALL="firewalld"
      ;;
  esac

  log "Erkannt: $DISTRO_PRETTY  (family=$DISTRO_FAMILY, pkg=$PKGMGR, ssh=$SSH_UNITS, fw=$FIREWALL)"

  # Versions-Kompatibilitäts-Hinweis
  case "$DISTRO_ID" in
    ubuntu)
      local ok=0 v
      for v in "${SUPPORTED_UBUNTU_VERSIONS[@]}"; do
        [[ "$DISTRO_VERSION_ID" == "$v" ]] && ok=1 && break
      done
      (( ok )) || warn "Ubuntu $DISTRO_VERSION_ID ist nicht explizit getestet (getestet: ${SUPPORTED_UBUNTU_VERSIONS[*]})."
      ;;
    rocky)
      local major="${DISTRO_VERSION_ID%%.*}" ok=0 v
      for v in "${SUPPORTED_ROCKY_MAJORS[@]}"; do
        [[ "$major" == "$v" ]] && ok=1 && break
      done
      (( ok )) || warn "Rocky Linux $DISTRO_VERSION_ID ist nicht explizit getestet (getestet: ${SUPPORTED_ROCKY_MAJORS[*]})."
      ;;
    fedora)
      local ok=0 v
      for v in "${SUPPORTED_FEDORA_VERSIONS[@]}"; do
        [[ "$DISTRO_VERSION_ID" == "$v" ]] && ok=1 && break
      done
      (( ok )) || warn "Fedora $DISTRO_VERSION_ID ist nicht explizit getestet (getestet: ${SUPPORTED_FEDORA_VERSIONS[*]})."
      ;;
  esac
}

detect_variant() {
  if [[ -n "$VARIANT" ]]; then
    if [[ "$VARIANT" != "desktop" && "$VARIANT" != "server" ]]; then
      err "Ungültige VARIANT: $VARIANT (erwarte 'desktop' oder 'server')"
      exit 2
    fi
    log "Variant manuell vorgegeben: $VARIANT"
    return 0
  fi

  # Primär: systemd-Default-Target
  local default_target
  default_target="$(systemctl get-default 2>/dev/null || true)"

  # Sekundär: Desktop-Metapaket / gnome-shell installiert?
  local has_desktop_pkg=0
  case "$DISTRO_FAMILY" in
    debian)
      if dpkg-query -W -f='${Status}' ubuntu-desktop         2>/dev/null | grep -q "ok installed" \
      || dpkg-query -W -f='${Status}' ubuntu-desktop-minimal 2>/dev/null | grep -q "ok installed"; then
        has_desktop_pkg=1
      fi
      ;;
    rhel)
      # Rocky/Fedora: gnome-shell ist zuverlässig als Indikator
      if rpm -q gnome-shell >/dev/null 2>&1 \
      || rpm -q plasma-workspace >/dev/null 2>&1; then
        has_desktop_pkg=1
      fi
      ;;
  esac

  if [[ "$default_target" == "graphical.target" || "$has_desktop_pkg" -eq 1 ]]; then
    VARIANT="desktop"
  else
    VARIANT="server"
  fi
  log "Erkannte Variante: $VARIANT  (systemd default: ${default_target:-unbekannt}, desktop-paket: $has_desktop_pkg)"
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
  # falls Datei fehlt (Rocky/Fedora frisch): anlegen
  touch "$file"
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

write_dnf_proxy() {
  local file="/etc/dnf/dnf.conf"
  backup_file "$file"
  log "Aktualisiere dnf-Proxy → $file"
  # [main]-Sektion sicherstellen
  if [[ ! -f "$file" ]]; then
    echo "[main]" > "$file"
  elif ! grep -q "^\[main\]" "$file"; then
    sed -i '1i[main]' "$file"
  fi
  # alte proxy-Zeilen entfernen
  sed -i -E '/^proxy\s*=/d' "$file"
  sed -i -E '/^proxy_username\s*=/d' "$file"
  sed -i -E '/^proxy_password\s*=/d' "$file"
  # Neue Einträge direkt nach [main] einfügen
  sed -i "/^\[main\]/a proxy=http://${PROXY_HOST}:${PROXY_PORT}" "$file"
  if [[ -n "$PROXY_USER" ]]; then
    sed -i "/^\[main\]/a proxy_password=$PROXY_PASS" "$file"
    sed -i "/^\[main\]/a proxy_username=$PROXY_USER" "$file"
  fi
  chmod 0644 "$file"
}

write_pkgmgr_proxy() {
  case "$DISTRO_FAMILY" in
    debian) write_apt_proxy ;;
    rhel)   write_dnf_proxy ;;
  esac
}

write_wget_proxy() {
  local file="/etc/wgetrc"
  # Rocky/Fedora installieren /etc/wgetrc mit wget — falls wget fehlt, überspringen
  if [[ ! -f "$file" ]]; then
    log "Überspringe $file (wget nicht installiert; wird später durch install_packages geliefert)."
    return 0
  fi
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
  write_pkgmgr_proxy
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
# Paket-Operationen (distro-agnostisch)
# ---------------------------------------------------------------------------
pkg_update() {
  log "Paketlisten aktualisieren ..."
  case "$PKGMGR" in
    apt-get)
      apt-get update
      ;;
    dnf|yum)
      $PKGMGR -y makecache
      ;;
  esac
  ok "Paketlisten aktualisiert."
}

pkg_install() {
  export DEBIAN_FRONTEND=noninteractive
  case "$PKGMGR" in
    apt-get)
      apt-get install -y --no-install-recommends "$@"
      ;;
    dnf|yum)
      $PKGMGR -y install "$@"
      ;;
  esac
}

install_packages() {
  log "=== Pakete installieren (distro=$DISTRO_FAMILY variant=$VARIANT) ==="

  local pkgs_base pkgs_desktop
  case "$DISTRO_FAMILY" in
    debian)
      pkgs_base=(open-vm-tools openssh-server ca-certificates curl wget iproute2)
      pkgs_desktop=(open-vm-tools-desktop)
      ;;
    rhel)
      # Rocky 10 / Fedora: openssh-server ist meist dabei, aber wir stellen's sicher
      pkgs_base=(open-vm-tools openssh-server ca-certificates curl wget iproute)
      pkgs_desktop=(open-vm-tools-desktop)
      ;;
  esac

  local pkgs=("${pkgs_base[@]}")
  if [[ "$VARIANT" == "desktop" ]]; then
    pkgs+=("${pkgs_desktop[@]}")
  else
    log "Server-Variante: open-vm-tools-desktop wird nicht installiert."
  fi

  pkg_install "${pkgs[@]}"
  ok "Pakete installiert."
}

# ---------------------------------------------------------------------------
# Dienste aktivieren
# ---------------------------------------------------------------------------
enable_services() {
  log "=== Dienste aktivieren ==="

  # open-vm-tools — gleicher Unit-Name überall
  if systemctl list-unit-files 2>/dev/null | grep -q "^vmtoolsd\.service"; then
    systemctl enable --now vmtoolsd.service \
      || warn "vmtoolsd.service konnte nicht aktiviert werden"
  elif systemctl list-unit-files 2>/dev/null | grep -q "^open-vm-tools\.service"; then
    systemctl enable --now open-vm-tools.service \
      || warn "open-vm-tools.service konnte nicht aktiviert werden"
  else
    warn "Keine open-vm-tools Unit gefunden."
  fi

  # SSH
  local unit
  for unit in $SSH_UNITS; do
    systemctl enable --now "$unit" \
      || warn "$unit konnte nicht aktiviert werden"
  done
  ok "Dienste aktiviert."
}

# ---------------------------------------------------------------------------
# Firewall
# ---------------------------------------------------------------------------
configure_firewall() {
  case "$FIREWALL" in
    ufw)
      if command -v ufw >/dev/null 2>&1; then
        if ufw status 2>/dev/null | grep -q "Status: active"; then
          log "UFW ist aktiv – öffne SSH"
          ufw allow OpenSSH 2>/dev/null || ufw allow 22/tcp \
            || warn "UFW-Regel konnte nicht gesetzt werden"
        else
          log "UFW inaktiv – überspringe."
        fi
      fi
      ;;
    firewalld)
      if command -v firewall-cmd >/dev/null 2>&1; then
        if systemctl is-active --quiet firewalld; then
          log "firewalld aktiv – öffne SSH"
          firewall-cmd --permanent --add-service=ssh >/dev/null \
            || warn "firewalld: ssh-Service konnte nicht hinzugefügt werden"
          firewall-cmd --reload >/dev/null \
            || warn "firewalld reload fehlgeschlagen"
        else
          log "firewalld inaktiv – überspringe."
        fi
      fi
      ;;
    *)
      log "Keine Firewall-Konfiguration nötig."
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Self-Tests
# ---------------------------------------------------------------------------
run_tests() {
  log "=== Self-Tests ==="
  local rc=0 unit

  # 1) SSH: mindestens eine Unit aktiv?
  local ssh_ok=0
  for unit in $SSH_UNITS; do
    if systemctl is-active --quiet "$unit"; then
      ok "$unit läuft."
      ssh_ok=1
    fi
  done
  if [[ $ssh_ok -eq 0 ]]; then
    err "Keine SSH-Unit ($SSH_UNITS) läuft."
    rc=1
  fi

  # 2) Port 22 lauscht?
  if command -v ss >/dev/null 2>&1 \
     && ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE '(^|:)22$'; then
    ok "Port 22 lauscht."
  else
    err "Port 22 lauscht nicht."
    rc=1
  fi

  # 3) open-vm-tools läuft?
  if systemctl is-active --quiet vmtoolsd.service 2>/dev/null \
  || systemctl is-active --quiet open-vm-tools.service 2>/dev/null; then
    ok "open-vm-tools läuft."
  else
    warn "open-vm-tools läuft nicht (ok, falls keine VMware-Umgebung)."
  fi

  # 4) Paketmanager-Proxy funktioniert?
  if [[ "$SKIP_PROXY" != "1" ]]; then
    local update_ok=0
    case "$PKGMGR" in
      apt-get)
        if apt-get \
             -o Acquire::http::Timeout=10 \
             -o Acquire::https::Timeout=10 \
             -o APT::Update::Error-Mode=any \
             update >/dev/null 2>&1; then
          update_ok=1
        fi
        ;;
      dnf|yum)
        # --refresh zwingt echten Netzwerkzugriff
        if $PKGMGR -y --refresh makecache >/dev/null 2>&1; then
          update_ok=1
        fi
        ;;
    esac
    if (( update_ok )); then
      ok "$PKGMGR update über Proxy erfolgreich."
    else
      err "$PKGMGR update über Proxy fehlgeschlagen."
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

  : > "$LOG_FILE"
  chmod 0640 "$LOG_FILE"
  log "=== $SCRIPT_NAME gestartet am $(date -Iseconds) ==="

  detect_distro
  detect_variant
  collect_proxy_details
  configure_proxy
  pkg_update
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
