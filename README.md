# ubuntu-vm-setup

Initial-Setup-Script für eine frische **Ubuntu 24.04 Desktop**-VM in **VMware Workstation** hinter einem Corporate-Proxy.

## Was macht das Script?

- Konfiguriert HTTP/HTTPS-Proxy für:
  - Login-Shells (`/etc/profile.d/99-proxy.sh`)
  - System-weit (`/etc/environment`)
  - APT (`/etc/apt/apt.conf.d/95proxy`)
  - wget (`/etc/wgetrc`)
  - curl (`/root/.curlrc`)
  - snap (falls installiert)
- Installiert **`open-vm-tools`** und **`open-vm-tools-desktop`** für saubere VMware-Integration (Copy-Paste, Ordner-Shares, Mouse-Grab, Shutdown aus dem Host, dynamisches Display-Resizing).
- Installiert und aktiviert **`openssh-server`** für Remote-Zugriff.
  - Aktiviert **`ssh.socket` UND `ssh.service`** (Ubuntu 24.04 nutzt Socket-Activation).
- Öffnet Port 22 in `ufw`, falls UFW aktiv ist.
- Führt am Ende automatische Self-Tests aus:
  - ssh.service **oder** ssh.socket aktiv
  - Port 22 lauscht
  - echter SSH-Banner-Handshake gegen `127.0.0.1:22`
  - `PasswordAuthentication`-Status (nur Info)
  - open-vm-tools läuft
  - `apt update` geht über den Proxy (mit `Error-Mode=any`)

## Voraussetzungen

- Ubuntu 24.04 Desktop (frisch installiert)
- sudo-fähiger Benutzer
- Erreichbarer HTTP/HTTPS-Proxy

## Verwendung

### Interaktiv (fragt nach Host und Port)

```bash
sudo ./setup-ubuntu-vm.sh
```

### Mit Parametern

```bash
sudo ./setup-ubuntu-vm.sh --host proxy.example.com --port 8080
```

### Mit Proxy-Auth

```bash
sudo ./setup-ubuntu-vm.sh \
  --host proxy.example.com --port 8080 \
  --user mario --pass 'GeheimesPasswort!' \
  --yes
```

### Via Umgebungsvariablen

```bash
sudo PROXY_HOST=proxy.example.com PROXY_PORT=8080 ASSUME_YES=1 \
  ./setup-ubuntu-vm.sh
```

### Ohne Proxy (Direktzugriff)

```bash
sudo ./setup-ubuntu-vm.sh --skip-proxy
```

## Optionen

| Option | Beschreibung |
|---|---|
| `--host <host>` | Proxy-Hostname oder IP |
| `--port <port>` | Proxy-Port (1–65535) |
| `--user <user>` | Proxy-Benutzer (optional) |
| `--pass <pw>` | Proxy-Passwort (optional, wird URL-encoded) |
| `--no-proxy <liste>` | Komma-Liste für `NO_PROXY` |
| `--skip-proxy` | Proxy-Konfiguration überspringen |
| `-y`, `--yes` | Alle Rückfragen mit Ja beantworten |
| `-h`, `--help` | Hilfe anzeigen |

## Logging

Alle Aktionen werden in `/var/log/setup-ubuntu-vm.log` protokolliert.

## Idempotenz

Das Script kann mehrfach ausgeführt werden. Originale von `/etc/environment` und `/etc/wgetrc` werden beim ersten Lauf als `.orig` gesichert; Proxy-Einträge werden vor dem Schreiben entfernt.

## Nach dem Lauf

```bash
# IP der VM ermitteln
hostname -I

# Per SSH vom Host verbinden
ssh <benutzer>@<vm-ip>

# Status der Dienste
systemctl status ssh ssh.socket open-vm-tools
```

### SSH-Hinweise

Ubuntu 24.04 aktiviert SSH per **Socket-Activation**. `ssh.socket` lauscht auf Port 22 und startet `ssh.service` beim ersten Connect. Der Self-Test akzeptiert deshalb beide Zustände als "aktiv".

Standardmäßig ist `PasswordAuthentication yes` aktiv – der Self-Test meldet den Status. Für höhere Sicherheit empfiehlt sich nach dem ersten Login der Umstieg auf SSH-Keys:

```bash
# auf dem Host:
ssh-copy-id <benutzer>@<vm-ip>

# auf der VM:
sudo sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sudo systemctl restart ssh
```

## Getestet mit

- Ubuntu 24.04.x Desktop LTS
- VMware Workstation 17
- Squid als HTTP-Proxy (Test)

## Lizenz

MIT – siehe [LICENSE](LICENSE).
