#!/bin/bash
# pi-ntern — turn a fresh Raspberry Pi 5 (Raspberry Pi OS Trixie, SD card) into an
# "Autonomous Intern" running the Hermes agent (Nous Research). Provisions, in order:
#   - Caddy            setup web UI + API proxy (Cloudsmith apt repo)
#   - intern backend   the Autonomous intern-server (LED ring, Wi-Fi onboarding API)
#   - Hermes agent     gateway as a systemd service, pinned to a release tag
#   - Honcho           self-hosted memory (Docker Compose on 127.0.0.1:8000)
#   - Tailscale        SSH over the tailnet + the Hermes dashboard published tailnet-only
#   - Rabbit R1        optional OpenClaw-compatible channel (third-party r1_shim) + pairing QR
#   - Firewall         iptables lockdown of 22/80/443/5000/8080 on physical interfaces
#                      (loopback, tailscale0, and the AP subnet 192.168.100.0/24 stay open)
#
# Single-interface AP/STA switch handles Wi-Fi onboarding: brings up a captive-portal
# access point when no Wi-Fi is configured, otherwise keeps the existing connection.
#
# Optional env:
#   TS_AUTHKEY              Tailscale auth key for unattended join (else: run `tailscale up` later)
#   TS_HOSTNAME             Tailnet hostname (default: intern-<serial suffix>)
#   HERMES_BRANCH           Hermes installer release tag (default: v2026.6.5 == v0.16.0)
#   HONCHO_LLM_OPENAI_API_KEY  LLM key for Honcho's generative models (falls back to OPENAI_API_KEY)
#   HONCHO_LLM_BASE_URL     Optional OpenAI-compatible base URL for Honcho generation + embeddings
#                           (e.g. https://openrouter.ai/api/v1 — OpenRouter serves both).
#   HONCHO_LLM_MODEL        Optional model id for Honcho generation (e.g. openrouter/auto)
#   HONCHO_EMBED_MODEL      Honcho embedding model (default: openai/text-embedding-3-small, 1536 dims)
#   HONCHO_EMBED_BASE_URL   Embedding endpoint (default: HONCHO_LLM_BASE_URL)
#   OPENROUTER_API_KEY      Hermes LLM key for the unpaired/BYO path (defaults to reusing the
#                           Honcho OpenRouter key, so one key configures both)
#   HERMES_MODEL            Hermes default model (default: openrouter/owl-alpha)
#   HERMES_FALLBACK_MODEL   Hermes fallback model (default: openrouter/auto)
#   R1_SHIM_ENABLED         1 (default) | 0 — install the Rabbit R1 channel (third-party shim)
#   R1_SHIM_TOKEN           Fixed R1 pairing token (default: auto-generated; keeps the QR stable)
#   R1_SHIM_PORT            R1 shim WebSocket port (default: 18790)
#   R1_SHIM_REPO_RAW        Raw base URL for the r1_shim adapter + Hermes patch
#                           (default: github.com/iammatthias/r1-hermes-shim main)
#   INTERN_SKILLS_ZIP_URL   Onboarding-skill archive URL (best-effort; non-fatal if unreachable).
#                           GITHUB_TOKEN is sent as a bearer header for a private repo.
#   INTERN_ONBOARDING_SKILL Skill folder name inside the archive (default: autonomous-intern-onboarding)
#   AP_MODE                 auto (default) | force | skip — whether to run AP/captive-portal
#                           onboarding. auto skips it when Wi-Fi is already configured (baked
#                           image or live link) and falls back to the AP when it isn't.
#   WIFI_SSID / WIFI_PASS   Optional Wi-Fi to provision (persistent NM profile) before the AP
#                           decision, so a flashed image comes up online without the captive portal.
#   SKIP_AP=1               Legacy alias for AP_MODE=skip (keep wlan0 as the existing uplink).
#   SKIP_REBOOT=1           Don't reboot at the end (otherwise reboots to apply SPI/WiFi firmware)
#   SKIP_FIREWALL=1         Don't apply the tailnet-only firewall lockdown — keeps the dashboard +
#                           SSH reachable over the LAN. Useful on a dev box you reach over the LAN.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# ----------------------------------------------------------
# Utils
# ----------------------------------------------------------
retry() {
  local n=0
  local max=$2
  local delay=${3:-2}
  local cmd="$1"
  until [ $n -ge $max ]; do
    eval "$cmd" && return 0
    n=$((n+1))
    echo "Retry $n/$max..."
    sleep $delay
  done
  echo "ERROR: Command failed after $max attempts: $cmd"
  return 1
}

ensure_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root"
    exit 1
  fi
}

# Pi 5: prefer device-tree serial; fallback to cpuinfo. Used for AP SSID and tailnet hostname.
serial_suffix() {
  local serial
  serial=$(tr -d '\0' </proc/device-tree/serial-number 2>/dev/null) || serial=$(awk '/Serial/ {print $3}' /proc/cpuinfo)
  echo "${serial: -4}"
}

# Optional: AP band and channel. Pi 5 (Bookworm/Trixie): firmware config is
# /boot/firmware/config.txt; ensure dtoverlay=disable-wifi is not set or WiFi will stay off.
AP_BAND="${AP_BAND:-2.4}"       # 2.4 or 5 (5 GHz for better throughput)
AP_CHANNEL="${AP_CHANNEL:-}"    # default: 6 (2.4 GHz) or 36 (5 GHz); override e.g. AP_CHANNEL=11 or 40

WEB_ROOT="/usr/share/caddy/setup"
HONCHO_DIR="${HONCHO_DIR:-/opt/honcho}"
HERMES_HOME_DIR="/root/.hermes"
# Pinned Hermes release tag (== v0.16.0). Bump to track upstream; the installer's
# `--branch` accepts tags. NB: the device-runtime doc pins v2026.4.30, but that ref
# is stale (it 404s on `hermes update`, which looks for a *branch* of that name) and
# several releases behind — we track the current tag instead.
HERMES_BRANCH="${HERMES_BRANCH:-v2026.6.5}"
# Pairing-time device config (LLM key/model/base_url, channel tokens, active_agent)
DEVICE_CONFIG="/root/config/config.json"
# Hermes LLM when the device is NOT paired with the Autonomous proxy: bring-your-own
# OpenRouter. Reuses the Honcho OpenRouter key by default (one key configures both).
OPENROUTER_API_KEY="${OPENROUTER_API_KEY:-}"
HERMES_MODEL="${HERMES_MODEL:-openrouter/owl-alpha}"
HERMES_FALLBACK_MODEL="${HERMES_FALLBACK_MODEL:-openrouter/auto}"
# Vision/multimodal auxiliary model. openrouter/auto is NOT image-capable (returns
# "No endpoints found that support image input"), so image understanding — e.g. R1
# camera photos via vision_analyze — needs an explicit multimodal model here.
HERMES_VISION_MODEL="${HERMES_VISION_MODEL:-google/gemini-2.5-flash}"

# Rabbit R1 channel. r1_shim is a THIRD-PARTY shim (github.com/iammatthias/r1-hermes-shim),
# NOT an upstream Hermes feature — upstream Hermes does not ship it. stage_hermes installs it
# by copying the adapter and applying a small source patch (pinned to HERMES_BRANCH) into the
# Hermes git checkout; `hermes update` would wipe those edits, so the patch step is idempotent
# and re-run on every provision. It is an OpenClaw-compatible WS gateway and MUST NOT share
# :18789 with the intern-gateway-shim stub (intern-server needs that one), so it runs on :18790.
# A fixed token keeps the pairing QR stable across reboots (pair once). The QR is rendered to
# /usr/share/caddy/r1 and shown as a tile in the Hermes dashboard (stage_r1_shim).
# Set R1_SHIM_ENABLED=0 to skip the channel; leave the token empty to auto-generate one.
R1_SHIM_ENABLED="${R1_SHIM_ENABLED:-1}"
R1_SHIM_PORT="${R1_SHIM_PORT:-18790}"
R1_SHIM_TOKEN="${R1_SHIM_TOKEN:-}"
# Source of the r1_shim adapter + the version-pinned Hermes patch (raw GitHub; set GITHUB_TOKEN if private).
R1_SHIM_REPO_RAW="${R1_SHIM_REPO_RAW:-https://raw.githubusercontent.com/iammatthias/r1-hermes-shim/main}"

# AP onboarding mode: auto (default) | force | skip.
#   auto  — skip the AP/captive-portal step when Wi-Fi is already configured (baked
#           image or a live connection); otherwise bring up the AP.
#   force — always bring up the AP (the classic onboarding flow).
#   skip  — never bring up the AP; keep the existing Wi-Fi connection.
# SKIP_AP=1 is a legacy alias for skip.
AP_MODE="${AP_MODE:-auto}"
[ "${SKIP_AP:-0}" = "1" ] && AP_MODE="skip"

# Optionally provision Wi-Fi from env before deciding, so a freshly flashed image can
# come up online without the captive portal. Writes a persistent NM profile + brings it up.
provision_wifi_from_env() {
  [ -z "${WIFI_SSID:-}" ] && return 0
  if ! command -v nmcli >/dev/null 2>&1; then
    echo "[stage] WARN: WIFI_SSID set but nmcli not present; cannot provision Wi-Fi"
    return 0
  fi
  if nmcli -t -f NAME connection show 2>/dev/null | grep -qxF "intern-wifi"; then
    echo "[stage] Wi-Fi profile 'intern-wifi' already present"
    return 0
  fi
  echo "[stage] Provisioning Wi-Fi profile for SSID '$WIFI_SSID'"
  if [ -n "${WIFI_PASS:-}" ]; then
    nmcli connection add type wifi ifname wlan0 con-name intern-wifi ssid "$WIFI_SSID" \
      wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$WIFI_PASS" connection.autoconnect yes >/dev/null 2>&1 || true
  else
    nmcli connection add type wifi ifname wlan0 con-name intern-wifi ssid "$WIFI_SSID" \
      connection.autoconnect yes >/dev/null 2>&1 || true
  fi
  nmcli connection up intern-wifi >/dev/null 2>&1 || true
}

# Returns 0 if wlan0 already has a usable Wi-Fi connection or saved profile, so AP
# onboarding is unnecessary. Covers Pi Imager / netplan / NM keyfile / a live link.
wifi_preconfigured() {
  [ -n "${WIFI_SSID:-}" ] && return 0
  if command -v nmcli >/dev/null 2>&1; then
    nmcli -t -f DEVICE,TYPE,STATE device 2>/dev/null | grep -q '^wlan0:wifi:connected$' && return 0
    nmcli -t -f TYPE connection show 2>/dev/null | grep -q '^802-11-wireless$' && return 0
  fi
  local f
  for f in /etc/wpa_supplicant/wpa_supplicant.conf /etc/wpa_supplicant/wpa_supplicant-wlan0.conf; do
    [ -f "$f" ] && grep -qE '^[[:space:]]*network[[:space:]]*=' "$f" && return 0
  done
  return 1
}

# Echoes "ap" (run AP onboarding) or "skip" (keep the existing Wi-Fi connection).
ap_decision() {
  case "$AP_MODE" in
    force) echo ap ;;
    skip)  echo skip ;;
    *)     if wifi_preconfigured; then echo skip; else echo ap; fi ;;
  esac
}

# Returns 0 if Tailscale is up with a tailnet IP (a guaranteed remote path back in).
tailscale_connected() {
  command -v tailscale >/dev/null 2>&1 || return 1
  ip -4 -brief addr show tailscale0 2>/dev/null | grep -qE '100\.' && return 0
  return 1
}

# Pi 5 has no RTC; TLS downloads fail on a fresh boot until NTP catches up.
wait_for_clock_sync() {
  echo "[stage] Waiting for NTP clock sync (Pi 5 has no RTC)"
  for _ in $(seq 1 60); do
    if timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q '^yes$'; then
      echo "[stage] System clock synchronized"
      return 0
    fi
    sleep 2
  done
  echo "[stage] WARN: clock not NTP-synced after 120s; TLS downloads may fail"
}

# ----------------------------------------------------------
# Stage -1: Locale (Debian hygiene — Bookworm/Trixie)
# ----------------------------------------------------------
stage_locale() {
  echo "[stage] Fix locale (Debian)"
  unset LC_CTYPE
  apt update
  apt install -y locales
  sed -i 's/^# *\(C\.UTF-8 UTF-8\)/\1/' /etc/locale.gen 2>/dev/null || true
  grep -q '^C\.UTF-8 UTF-8' /etc/locale.gen || echo 'C.UTF-8 UTF-8' >> /etc/locale.gen
  locale-gen C.UTF-8 2>/dev/null || locale-gen
  # Debian reads /etc/default/locale (not /etc/locale.conf — that's systemd/Arch)
  if command -v update-locale >/dev/null 2>&1; then
    update-locale LANG=C.UTF-8 LC_ALL=C.UTF-8
  else
    printf 'LANG=C.UTF-8\nLC_ALL=C.UTF-8\n' > /etc/default/locale
  fi
}

# ----------------------------------------------------------
# Stage 0: Prerequisites
# ----------------------------------------------------------
stage_prerequisites() {
  echo "[stage] Install system packages"
  apt update
  # No `|| true` here: these packages are load-bearing; fail loudly instead of later and mysteriously.
  apt install -y \
    hostapd dnsmasq unzip curl jq wpasupplicant dhcpcd iproute2 iptables \
    iw git ca-certificates gnupg apt-transport-https debian-keyring debian-archive-keyring \
    qrencode openssl
  systemctl stop hostapd dnsmasq 2>/dev/null || true
  systemctl unmask hostapd dnsmasq 2>/dev/null || true
  # Node.js/chromium/xvfb dropped from this list: the Hermes installer brings its
  # own Python (uv), Node.js, ffmpeg and chromium (that's why its stage is slow).
  # Keep wpa_supplicant running so STA (e.g. Pi Imager WiFi) stays connected during setup.
  # Global wpa_supplicant is stopped/masked only when we switch to AP in device-ap-mode.
  # dhcpcd is still a real package on Trixie (1:10.1.0) — we install it because
  # Raspberry Pi OS no longer ships it by default (NetworkManager is the default).
}

# ----------------------------------------------------------
# Take wlan0 out of NetworkManager's hands (Trixie default net stack)
# ----------------------------------------------------------
# On Bookworm/Trixie, NetworkManager owns every interface by default and, after
# first boot, ignores legacy wpa_supplicant.conf. We drive wlan0 ourselves
# (hostapd in AP mode; wpa_supplicant@wlan0 + dhcpcd in STA mode), so mark it
# permanently unmanaged. This replaces the old `systemctl stop NetworkManager`
# hack and, crucially, leaves eth0 under NM so a wired uplink keeps working.
# Runs late (just before the AP switch): until then, NM-managed wlan0 may be the
# provisioning uplink on a Pi-Imager-flashed image.
stage_nm_unmanage_wlan0() {
  echo "[stage] Mark wlan0 unmanaged by NetworkManager"
  if [ ! -d /etc/NetworkManager ]; then
    echo "[stage] NetworkManager not present; nothing to unmanage"
    return 0
  fi
  mkdir -p /etc/NetworkManager/conf.d
  cat >/etc/NetworkManager/conf.d/99-intern-unmanaged.conf <<'EOF'
[keyfile]
unmanaged-devices=interface-name:wlan0
EOF
  if command -v nmcli >/dev/null 2>&1; then
    nmcli general reload 2>/dev/null || systemctl reload NetworkManager 2>/dev/null || true
    nmcli device set wlan0 managed no 2>/dev/null || true
  fi
}

# ----------------------------------------------------------
# Stage 0a: Raspberry Pi 5 WiFi stability (reduces STA drops when SSID/PSK are correct)
# ----------------------------------------------------------
stage_rpi5_wifi_stability() {
  echo "[stage] RPi 5 WiFi stability (power save off, IPv6 disable)"

  # Disable IPv6 — can cause connection drops on RPi 5
  mkdir -p /etc/sysctl.d
  cat >/etc/sysctl.d/99-intern-wifi.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
  sysctl -p /etc/sysctl.d/99-intern-wifi.conf 2>/dev/null || true

  # Disable WiFi power saving at boot (chip sleep causes STA drops)
  # device-ap-mode and device-sta-mode also run power_save off when switching modes
  cat >/etc/systemd/system/intern-wifi-power-save.service <<'EOF'
[Unit]
Description=Disable WiFi power save on wlan0 (RPi 5 stability)
After=network-online.target
Before=hostapd.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'for i in 1 2 3 4 5 6 7 8 9 10; do ip link show wlan0 >/dev/null 2>&1 && break; sleep 2; done; iw dev wlan0 set power_save off 2>/dev/null || iwconfig wlan0 power off 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable intern-wifi-power-save.service
  # Run now if wlan0 exists (e.g. already on STA from image)
  systemctl start intern-wifi-power-save.service 2>/dev/null || true
}

# ----------------------------------------------------------
# Stage 0b: Enable SPI (firmware config + runtime)
# ----------------------------------------------------------
# intern-server opens /dev/spidev0.0 at startup (the LED-ring bus) and exits if it's
# missing. The SPI0 bus exists on every Pi 5 — it just has to be turned on. We do both:
# persist dtparam=spi=on in config.txt (survives reboot) AND load it at runtime so
# /dev/spidev0.0 appears immediately, letting the backend come up without a reboot.
# Note: this is the SPI *bus*; whether an LED ring is physically wired to it is irrelevant.
stage_enable_spi() {
  echo "[stage] Enable SPI (firmware config + runtime)"

  local cfg=""
  if [ -f /boot/firmware/config.txt ]; then
    cfg="/boot/firmware/config.txt"
  elif [ -f /boot/config.txt ]; then
    cfg="/boot/config.txt"
  fi

  if [ -n "$cfg" ]; then
    # If dtparam=spi=on is present but commented, uncomment it; otherwise append.
    if grep -qE '^\s*#?\s*dtparam=spi=on' "$cfg" 2>/dev/null; then
      sed -i -E 's/^\s*#\s*(dtparam=spi=on)/\1/' "$cfg" 2>/dev/null || true
      echo "[stage] Ensured dtparam=spi=on is enabled in $cfg"
    else
      {
        echo ""
        echo "# Enabled by intern setup to turn on the SPI0 bus (LED ring)"
        echo "dtparam=spi=on"
      } >>"$cfg"
      echo "[stage] Added dtparam=spi=on to $cfg"
    fi
  else
    echo "[stage] No config.txt found; relying on runtime SPI enable only"
  fi

  # Bring SPI0 up now so /dev/spidev0.0 exists without waiting for a reboot.
  if [ ! -e /dev/spidev0.0 ] && command -v dtoverlay >/dev/null 2>&1; then
    dtoverlay spi0-0cs 2>/dev/null || true
    sleep 1
  fi
  if [ -e /dev/spidev0.0 ]; then
    echo "[stage] SPI0 active (/dev/spidev0.0 present)"
  else
    echo "[stage] WARN: /dev/spidev0.0 not present yet; it will appear after the reboot (dtparam=spi=on)."
  fi
}

# ----------------------------------------------------------
# Stage 0c: OTA metadata (web, intern, bootstrap URLs from GCS)
# ----------------------------------------------------------
OTA_METADATA_URL="${OTA_METADATA_URL:-https://storage.googleapis.com/s3-autonomous-upgrade-3/intern/ota/metadata.json}"

stage_ota_metadata() {
  echo "[stage] Fetch OTA metadata"
  METADATA_TMP="/tmp/ota-metadata.$$.json"
  retry "curl -fsSL -H \"Cache-Control: no-cache\" -H \"Pragma: no-cache\" -o \"$METADATA_TMP\" \"$OTA_METADATA_URL\"" 5
  export WEB_VERSION WEB_URL INTERN_VERSION INTERN_URL BOOTSTRAP_VERSION BOOTSTRAP_URL
  WEB_VERSION=$(jq -r '.web.version // empty' "$METADATA_TMP")
  WEB_URL=$(jq -r '.web.url // empty' "$METADATA_TMP")
  INTERN_VERSION=$(jq -r '.intern.version // empty' "$METADATA_TMP")
  INTERN_URL=$(jq -r '.intern.url // empty' "$METADATA_TMP")
  BOOTSTRAP_VERSION=$(jq -r '.bootstrap.version // empty' "$METADATA_TMP")
  BOOTSTRAP_URL=$(jq -r '.bootstrap.url // empty' "$METADATA_TMP")
  rm -f "$METADATA_TMP"
  if [ -z "$WEB_URL" ] || [ -z "$INTERN_URL" ] || [ -z "$BOOTSTRAP_URL" ]; then
    echo "ERROR: OTA metadata missing web.url, intern.url or bootstrap.url. Check $OTA_METADATA_URL"
    exit 1
  fi
  echo "[stage] OTA versions: web=$WEB_VERSION intern=$INTERN_VERSION bootstrap=$BOOTSTRAP_VERSION"
}

# Download zip from URL, unzip, copy single binary to dest path (handles intern-server, bootstrap-server in zip)
install_binary_from_zip() {
  local url="$1"
  local dest_binary="$2"
  local name="$3"
  local zip_tmp="/tmp/${name}-zip.$$"
  local dir_tmp="/tmp/${name}-dir.$$"
  mkdir -p "$dir_tmp"
  retry "curl -fsSL -H \"Cache-Control: no-cache\" -H \"Pragma: no-cache\" -o \"$zip_tmp\" \"$url\"" 5
  unzip -o -q "$zip_tmp" -d "$dir_tmp"
  rm -f "$zip_tmp"
  # Zip may contain intern-server, bootstrap-server or bare binary (at root or in subdir)
  local bin_file
  bin_file=$(find "$dir_tmp" -type f -executable 2>/dev/null | head -1)
  [ -z "$bin_file" ] && bin_file=$(find "$dir_tmp" -type f 2>/dev/null | head -1)
  if [ -z "$bin_file" ] || [ ! -f "$bin_file" ]; then
    echo "ERROR: No binary found in zip from $url"
    rm -rf "$dir_tmp" 2>/dev/null || true
    exit 1
  fi
  cp -f "$bin_file" "$dest_binary"
  chmod +x "$dest_binary"
  rm -rf "$dir_tmp"
}

# ----------------------------------------------------------
# Stage 0d: OpenClaw-gateway WS shim (for intern-server's LED/lifecycle client)
# ----------------------------------------------------------
# intern-server dials ws://127.0.0.1:18789 (the OpenClaw gateway) for its lifecycle WS
# and reconnect-loops on connection-refused under Hermes. This installs a tiny stdlib WS
# server that greets + answers the connect handshake so intern-server stays connected (no
# error spam). It does NOT push LED events itself — the LED ring is driven separately by
# the Hermes lifecycle hooks in stage_hermes (step 4b) via intern-server's /api/led. Runs
# BEFORE stage_backend so it's up when intern first starts. (Only needed because we run Hermes
# instead of OpenClaw — under OpenClaw the real gateway already owns :18789.)
stage_gateway_shim() {
  echo "[stage] Install OpenClaw-gateway WS shim (:18789)"
  cat >/usr/local/bin/intern-gateway-shim <<'SHIMEOF'
#!/usr/bin/env python3
# Minimal WebSocket shim on 127.0.0.1:18789 standing in for the OpenClaw gateway so
# intern-server's LED/lifecycle client connects cleanly instead of reconnect-looping.
# Greets the client, answers its JSON-RPC `connect` handshake, pongs pings. No events
# are pushed (LED stays idle). Pure stdlib, no deps.
import base64
import hashlib
import json
import socket
import struct
import threading

HOST, PORT = "127.0.0.1", 18789
GUID = b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def recvn(conn, n):
    buf = b""
    while len(buf) < n:
        chunk = conn.recv(n - len(buf))
        if not chunk:
            return None
        buf += chunk
    return buf


def handshake(conn):
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = conn.recv(1024)
        if not chunk:
            return False
        data += chunk
        if len(data) > 65536:
            return False
    key = None
    for line in data.split(b"\r\n"):
        if line.lower().startswith(b"sec-websocket-key:"):
            key = line.split(b":", 1)[1].strip()
    if not key:
        return False
    accept = base64.b64encode(hashlib.sha1(key + GUID).digest())
    conn.sendall(
        b"HTTP/1.1 101 Switching Protocols\r\n"
        b"Upgrade: websocket\r\n"
        b"Connection: Upgrade\r\n"
        b"Sec-WebSocket-Accept: " + accept + b"\r\n\r\n"
    )
    return True


def recv_frame(conn):
    hdr = recvn(conn, 2)
    if not hdr:
        return None
    opcode = hdr[0] & 0x0F
    masked = hdr[1] & 0x80
    ln = hdr[1] & 0x7F
    if ln == 126:
        ext = recvn(conn, 2)
        if not ext:
            return None
        ln = struct.unpack(">H", ext)[0]
    elif ln == 127:
        ext = recvn(conn, 8)
        if not ext:
            return None
        ln = struct.unpack(">Q", ext)[0]
    mask = recvn(conn, 4) if masked else b"\x00\x00\x00\x00"
    if masked and mask is None:
        return None
    payload = recvn(conn, ln) if ln else b""
    if ln and payload is None:
        return None
    if masked and payload:
        payload = bytes(payload[i] ^ mask[i % 4] for i in range(len(payload)))
    return opcode, payload


def send_frame(conn, opcode, payload=b""):
    b1 = 0x80 | opcode
    ln = len(payload)
    if ln < 126:
        hdr = struct.pack(">BB", b1, ln)
    elif ln < 65536:
        hdr = struct.pack(">BBH", b1, 126, ln)
    else:
        hdr = struct.pack(">BBQ", b1, 127, ln)
    conn.sendall(hdr + payload)


def handle(conn, addr):
    try:
        if not handshake(conn):
            conn.close()
            return
        print(f"client connected {addr}", flush=True)
        try:
            send_frame(conn, 0x1, json.dumps({
                "method": "connected",
                "params": {"protocol": 3, "server": {"id": "intern-gateway-shim", "mode": "gateway", "version": "1.0"}},
            }).encode("utf-8"))
        except OSError:
            conn.close()
            return
        logged = 0
        while True:
            fr = recv_frame(conn)
            if fr is None:
                break
            opcode, payload = fr
            if opcode == 0x8:
                try:
                    send_frame(conn, 0x8)
                except OSError:
                    pass
                break
            if opcode == 0x9:
                send_frame(conn, 0xA, payload)
                continue
            if opcode not in (0x1, 0x2):
                continue
            try:
                msg = json.loads(payload.decode("utf-8", "replace"))
            except (ValueError, UnicodeError):
                continue
            if logged < 5:
                print(f"frame from {addr}: {payload[:240]!r}", flush=True)
                logged += 1
            if not isinstance(msg, dict):
                continue
            mid = msg.get("id")
            method = msg.get("method")
            if mid is None or method is None:
                continue
            if method == "connect":
                params = msg.get("params") or {}
                result = {
                    "protocol": 3,
                    "scopes": params.get("scopes", []),
                    "server": {"id": "intern-gateway-shim", "mode": "gateway", "version": "1.0"},
                }
            else:
                result = {}
            try:
                send_frame(conn, 0x1, json.dumps({"id": mid, "result": result}).encode("utf-8"))
            except OSError:
                break
    except OSError:
        pass
    finally:
        try:
            conn.close()
        except OSError:
            pass


def main():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((HOST, PORT))
    srv.listen(8)
    print(f"intern-gateway-shim listening on {HOST}:{PORT}", flush=True)
    while True:
        conn, addr = srv.accept()
        threading.Thread(target=handle, args=(conn, addr), daemon=True).start()


if __name__ == "__main__":
    main()
SHIMEOF
  chmod +x /usr/local/bin/intern-gateway-shim

  # intern-server reads a gateway token from this file before connecting; the shim
  # ignores the token's value, but the file must exist or intern-server errors.
  mkdir -p /root/openclaw
  if [ ! -f /root/openclaw/openclaw.json ]; then
    cat >/root/openclaw/openclaw.json <<'EOF'
{"gateway":{"mode":"local","bind":"loopback","port":18789,"auth":{"mode":"token","token":"intern-shim-token"}}}
EOF
    chmod 600 /root/openclaw/openclaw.json
  fi

  cat >/etc/systemd/system/intern-gateway-shim.service <<'EOF'
[Unit]
Description=Intern gateway WS shim (OpenClaw-compat stub for intern-server on :18789)
After=network.target
Before=intern.service

[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/intern-gateway-shim
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal
SyslogIdentifier=intern-gateway-shim

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now intern-gateway-shim
}

# ----------------------------------------------------------
# Stage 1: Backend (bootstrap + intern from OTA metadata)
# ----------------------------------------------------------
stage_backend() {
  echo "[stage] Install backend (bootstrap + intern)"

  install_binary_from_zip "$BOOTSTRAP_URL" /usr/local/bin/bootstrap-server "bootstrap"
  install_binary_from_zip "$INTERN_URL" /usr/local/bin/intern-server "intern"

  cat >/etc/systemd/system/bootstrap.service <<EOF
[Unit]
Description=Bootstrap Backend
After=network-online.target

[Service]
User=root
ExecStart=/usr/local/bin/bootstrap-server
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=bootstrap

[Install]
WantedBy=multi-user.target
EOF

  # intern-server opens /dev/spidev0.0 (the LED-ring bus) at startup; stage_enable_spi
  # turns that bus on at runtime, so the service starts normally here. Restart=always
  # covers a transient crash; if the bus were somehow absent it'd retry until SPI is up.
  cat >/etc/systemd/system/intern.service <<EOF
[Unit]
Description=Intern Backend
After=network-online.target

[Service]
User=root
WorkingDirectory=/root
ExecStart=/usr/local/bin/intern-server
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=intern

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable bootstrap intern
  systemctl restart bootstrap intern

  # intern-server natively supports Hermes once active_agent=hermes is persisted
  # in /root/config/config.json (done in stage_hermes): its model-sync loop then
  # maintains ~/.hermes/config.yaml and /api/device/setup writes channel creds
  # to ~/.hermes/.env.
}

# ----------------------------------------------------------
# Stage 1a: Tailscale (SSH over tailnet + dashboard published on tailnet only)
# ----------------------------------------------------------
stage_tailscale() {
  echo "[stage] Install Tailscale"
  if ! command -v tailscale >/dev/null 2>&1; then
    # Official installer detects Raspberry Pi OS vs Debian and adds the right apt repo.
    retry "curl -fsSL https://tailscale.com/install.sh | sh" 5
  fi
  systemctl enable --now tailscaled

  local suffix hostname
  suffix=$(serial_suffix)
  hostname="${TS_HOSTNAME:-intern-${suffix}}"

  # No --ssh: rely on the regular sshd reachable over the tailnet. Tailscale SSH needs a
  # tailnet ACL `ssh` rule the operator may not have, and (since it shadows port 22 on the
  # tailnet) combined with stage_firewall locking LAN SSH it would lock out a fresh device.
  # stage_firewall exempts tailscale0, so `ssh <user>@<tailnet-ip>` works with the operator's
  # key regardless. The dashboard is published to the tailnet in stage_hermes_dashboard; the
  # setup-web stays local/AP-only (not on the tailnet).
  if tailscale_connected; then
    echo "[stage] Tailscale already connected; skipping re-auth"
    tailscale set --ssh=false 2>/dev/null || true
  elif [ -n "${TS_AUTHKEY:-}" ]; then
    retry "tailscale up --authkey='$TS_AUTHKEY' --hostname='$hostname'" 5 5
    echo "[stage] Tailscale up as $hostname"
  else
    echo "[stage] TS_AUTHKEY not set. After setup, run:  tailscale up --hostname=$hostname"
  fi
}

# ----------------------------------------------------------
# Stage 1b: Self-hosted Honcho (memory backend for Hermes)
# Docker Compose stack: api :8000, deriver worker, Postgres+pgvector, Redis.
# Everything binds to 127.0.0.1; only Hermes on this box talks to it.
# ----------------------------------------------------------
stage_honcho() {
  echo "[stage] Install self-hosted Honcho"

  if ! command -v docker >/dev/null 2>&1; then
    echo "[stage] Install Docker (get.docker.com)"
    # The convenience script can lag a brand-new Debian release (no trixie repo
    # yet); fall back to Debian's own packages, which ship the compose v2 plugin.
    if ! retry "curl -fsSL https://get.docker.com | sh" 3; then
      echo "[stage] get.docker.com failed; falling back to Debian docker.io + docker-compose-v2"
      apt update
      apt install -y docker.io docker-compose-v2 || { echo "ERROR: Docker install failed"; exit 1; }
    fi
  fi
  systemctl enable --now docker
  # The stack uses `docker compose` (v2 plugin), not the legacy `docker-compose`.
  if ! docker compose version >/dev/null 2>&1; then
    echo "ERROR: 'docker compose' (v2) unavailable after install"
    exit 1
  fi

  if [ -d "$HONCHO_DIR/.git" ]; then
    git -C "$HONCHO_DIR" pull --ff-only || true
  else
    retry "git clone --depth 1 https://github.com/plastic-labs/honcho '$HONCHO_DIR'" 5
  fi

  if [ ! -f "$HONCHO_DIR/docker-compose.yml" ]; then
    cp "$HONCHO_DIR/docker-compose.yml.example" "$HONCHO_DIR/docker-compose.yml"
  fi

  # Honcho's deriver needs one OpenAI-compatible LLM key; the server won't start without it.
  local honcho_key="${HONCHO_LLM_OPENAI_API_KEY:-${OPENAI_API_KEY:-}}"
  # Optional OpenAI-compatible provider override (OpenRouter, Ollama, vLLM, ...).
  # When HONCHO_LLM_BASE_URL is set, all four generative model configs are pointed at it.
  local honcho_base_url="${HONCHO_LLM_BASE_URL:-}"
  local honcho_model="${HONCHO_LLM_MODEL:-}"
  # Embeddings: OpenRouter now serves an OpenAI-compatible /v1/embeddings endpoint, so the same
  # base_url + key cover embeddings too (no separate OpenAI account needed). Defaults to the
  # generation base_url + openai/text-embedding-3-small, which returns 1536 dims — matching
  # Honcho's default pgvector schema, so no DB rebuild. Override for a different provider/model.
  local honcho_embed_base="${HONCHO_EMBED_BASE_URL:-$honcho_base_url}"
  local honcho_embed_model="${HONCHO_EMBED_MODEL:-openai/text-embedding-3-small}"
  if [ ! -f "$HONCHO_DIR/.env" ]; then
    {
      echo "# Honcho self-hosted config (written by setup-hermes.sh)"
      echo "AUTH_USE_AUTH=false"
      echo "LLM_OPENAI_API_KEY=${honcho_key}"
      if [ -n "$honcho_base_url" ]; then
        echo ""
        echo "# Generative models routed to an OpenAI-compatible provider (e.g. OpenRouter)."
        local feat
        for feat in DERIVER DIALECTIC SUMMARY DREAM; do
          echo "${feat}_MODEL_CONFIG__TRANSPORT=openai"
          [ -n "$honcho_model" ] && echo "${feat}_MODEL_CONFIG__MODEL=${honcho_model}"
          echo "${feat}_MODEL_CONFIG__OVERRIDES__BASE_URL=${honcho_base_url}"
        done
      fi
      if [ -n "$honcho_embed_base" ]; then
        echo ""
        echo "# Embeddings via the same OpenAI-compatible provider (OpenRouter serves /v1/embeddings)."
        echo "# text-embedding-3-small = 1536 dims = Honcho's default schema (no rebuild). DIMENSIONS_MODE"
        echo "# =never: OpenRouter's embeddings endpoint does not accept a dimensions= param."
        echo "EMBEDDING_MODEL_CONFIG__TRANSPORT=openai"
        echo "EMBEDDING_MODEL_CONFIG__MODEL=${honcho_embed_model}"
        echo "EMBEDDING_MODEL_CONFIG__OVERRIDES__BASE_URL=${honcho_embed_base}"
        echo "EMBEDDING_MODEL_CONFIG__DIMENSIONS_MODE=never"
      else
        echo "# No base_url set: generation + embeddings default to OpenAI and need LLM_OPENAI_API_KEY"
        echo "# to be a real OpenAI key. To use OpenRouter for both, re-run with HONCHO_LLM_BASE_URL"
        echo "# (e.g. https://openrouter.ai/api/v1) + HONCHO_LLM_MODEL set."
      fi
    } >"$HONCHO_DIR/.env"
    chmod 600 "$HONCHO_DIR/.env"
  fi
  if [ -z "$honcho_key" ]; then
    echo "[stage] WARN: no HONCHO_LLM_OPENAI_API_KEY/OPENAI_API_KEY set."
    echo "        Honcho's API will not start until you add LLM_OPENAI_API_KEY to $HONCHO_DIR/.env"
    echo "        and run: docker compose -f $HONCHO_DIR/docker-compose.yml up -d"
  fi

  # First build compiles from source — expect several minutes on a Pi 5.
  echo "[stage] Building + starting Honcho stack (this takes a while on first run)"
  (cd "$HONCHO_DIR" && docker compose up -d --build) \
    || { echo "ERROR: Honcho docker compose failed"; exit 1; }

  # Non-fatal readiness probe. Hit /health, not / — Honcho has no route at root
  # (it 404s), so a `curl -f /` would report a false negative while the API is up.
  for _ in $(seq 1 30); do
    curl -fsS -o /dev/null http://127.0.0.1:8000/health 2>/dev/null && { echo "[stage] Honcho API is up on 127.0.0.1:8000"; return 0; }
    sleep 2
  done
  echo "[stage] WARN: Honcho API not responding yet on 127.0.0.1:8000 (check: docker compose -f $HONCHO_DIR/docker-compose.yml logs)"
}

# ----------------------------------------------------------
# Stage 1c: Hermes agent — same order intern-server uses internally when it
# switches a device to Hermes: install binary → register systemd unit → stop
# OpenClaw → write config.yaml → write .env → enable + start gateway →
# onboarding skill → persist active_agent.
# ----------------------------------------------------------

# Install the THIRD-PARTY r1_shim adapter into the Hermes source tree. Upstream Hermes does NOT
# ship r1_shim — we copy the adapter and git-apply a small source patch pinned to HERMES_BRANCH
# (source of truth: github.com/iammatthias/r1-hermes-shim). These are working-tree edits to the
# Hermes git checkout, so `hermes update`/reinstall wipes them; this runs on every provision and
# is idempotent (reverse-check). If the patch doesn't apply (Hermes != the pinned tag) it warns
# and leaves the source untouched (R1 channel inert) rather than corrupting it.
apply_r1_shim_patches() {
  local src="" d
  for d in /usr/local/lib/hermes-agent "$HERMES_HOME_DIR/hermes-agent"; do
    if [ -f "$d/gateway/config.py" ]; then src="$d"; break; fi
  done
  if [ -z "$src" ]; then
    echo "[stage] WARN: Hermes source not found — cannot install r1_shim adapter (R1 channel inert)"
    return 0
  fi

  local -a auth=()
  [ -n "${GITHUB_TOKEN:-}" ] && auth=(-H "Authorization: Bearer ${GITHUB_TOKEN}")

  # 1. adapter file (idempotent overwrite)
  if ! curl -fsSL --retry 3 --retry-delay 3 "${auth[@]}" \
       "$R1_SHIM_REPO_RAW/gateway/platforms/r1_shim.py" \
       -o "$src/gateway/platforms/r1_shim.py"; then
    echo "[stage] WARN: could not fetch r1_shim.py from $R1_SHIM_REPO_RAW — skipping R1 patch (inert)"
    return 0
  fi

  # 2. version-pinned source patch (config.py enum+env, run.py dispatch+auth bypass)
  local patch=/tmp/r1-shim-hermes.patch
  if ! curl -fsSL --retry 3 --retry-delay 3 "${auth[@]}" \
       "$R1_SHIM_REPO_RAW/patches/hermes-${HERMES_BRANCH}.patch" -o "$patch"; then
    echo "[stage] WARN: no r1_shim patch for Hermes $HERMES_BRANCH at $R1_SHIM_REPO_RAW — skipping (inert)"
    return 0
  fi
  if git -C "$src" apply --reverse --check "$patch" 2>/dev/null; then
    echo "[stage] r1_shim source patch already applied"
  elif git -C "$src" apply --check "$patch" 2>/dev/null; then
    git -C "$src" apply "$patch" && echo "[stage] r1_shim source patch applied to $src"
  else
    echo "[stage] WARN: r1_shim patch does not apply to Hermes $HERMES_BRANCH — source left unmodified (R1 inert)."
    echo "        The patch is pinned to a Hermes tag; regenerate patches/hermes-<tag>.patch if you changed HERMES_BRANCH."
    return 0
  fi

  # 3. drop stale bytecode so the patched modules are reimported on gateway start
  find "$src" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true
  echo "[stage] r1_shim adapter installed (port ${R1_SHIM_PORT})"
}

stage_hermes() {
  echo "[stage] Install Hermes agent (pinned tag: $HERMES_BRANCH)"
  export HOME=/root

  # --- 1. Install the Hermes binary.
  # Slow phase: the upstream installer downloads Python (uv), Node.js, ffmpeg and
  # chromium — expect 5-10 minutes on a Pi 5 with a healthy connection.
  # NB: process substitution, NOT `curl | bash < /dev/null` — that redirect
  # overrides the pipe, bash reads an empty stdin, and the "installer" exits 0
  # without doing anything. HERMES_HOME pins the install root so the systemd
  # unit, which runs as root, sees the same paths.
  retry "HERMES_HOME=$HERMES_HOME_DIR DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a bash <(curl -fsSL https://hermes-agent.nousresearch.com/install.sh) --skip-setup --branch $HERMES_BRANCH < /dev/null" 3 10

  if ! command -v hermes >/dev/null 2>&1; then
    echo "ERROR: hermes not on PATH after install (expected /usr/local/bin/hermes)"
    exit 1
  fi
  hermes --version || true

  # --- 2. Register the gateway systemd unit.
  # --system: root has no login session; per-user mode would fail at
  #   `systemctl --user daemon-reload`.
  # --force: overwrite a stale unit file from a previous attempt.
  # --run-as-user root: the uv-managed Python under /root/.local/share/uv/... is
  #   mode 700; a non-root unit fails at exec with EPERM on the venv interpreter.
  # v0.16.0+ asks TWO [Y/n] questions with no non-interactive flag ("start now?" and
  # "start on boot?"); feed enough 'y's for both (we also restart it via systemctl below).
  # printf (not `yes`) keeps the pipe's exit status the command's under pipefail.
  printf 'y\ny\ny\ny\ny\n' | hermes gateway install --system --force --run-as-user root

  # Resource guardrail (ours, not from the docs): the Pi shares RAM with the
  # Honcho docker stack; mirrors the old openclaw.service cap.
  mkdir -p /etc/systemd/system/hermes-gateway.service.d
  cat >/etc/systemd/system/hermes-gateway.service.d/override.conf <<'EOF'
[Service]
MemoryMax=1500M
LimitNOFILE=65535
EOF
  systemctl daemon-reload

  # --- 2b. R1 channel (third-party shim): copy the adapter + patch the Hermes source NOW, before
  # the gateway starts below, so R1_SHIM is a known Platform when the .env (step 5) enables it.
  # Idempotent; re-applied here because `hermes gateway install` re-checks-out the pinned tag.
  if [ "${R1_SHIM_ENABLED}" = "1" ]; then
    apply_r1_shim_patches
  fi

  # --- 3. Stop OpenClaw. This script never installs it, but the golden image may
  # ship it pre-installed; two runtimes must never share the channel adapters.
  systemctl stop openclaw 2>/dev/null || true
  systemctl disable openclaw 2>/dev/null || true

  # --- 4. config.yaml: model/provider values come from the pairing-time device
  # config. On a fresh (unpaired) device those fields don't exist yet; write the
  # memory section only — intern-server's model-sync loop maintains the provider
  # block once active_agent=hermes and the device is paired.
  mkdir -p "$HERMES_HOME_DIR"
  chmod 700 "$HERMES_HOME_DIR"
  local llm_key="" llm_model="" llm_base_url="" have_llm=0
  if [ -f "$DEVICE_CONFIG" ]; then
    llm_key=$(jq -r '.llm_api_key // empty' "$DEVICE_CONFIG")
    llm_model=$(jq -r '.llm_model // empty' "$DEVICE_CONFIG")
    llm_base_url=$(jq -r '.llm_base_url // empty' "$DEVICE_CONFIG")
  fi
  # OpenRouter key for the unpaired path: explicit OPENROUTER_API_KEY, else reuse the
  # Honcho OpenRouter key so one key configures both Honcho and Hermes ("one fell swoop").
  local or_key="$OPENROUTER_API_KEY"
  if [ -z "$or_key" ] && printf '%s' "${HONCHO_LLM_BASE_URL:-}" | grep -qi openrouter; then
    or_key="${HONCHO_LLM_OPENAI_API_KEY:-}"
  fi
  if [ -n "$llm_key" ] && [ -n "$llm_model" ] && [ -n "$llm_base_url" ]; then
    have_llm=1
    # Paired device: Autonomous proxy (Anthropic Messages). intern-server's sync loop
    # refreshes the models map once active_agent=hermes.
    cat >"$HERMES_HOME_DIR/config.yaml" <<YAML
model:
  default: '${llm_model}'
  provider: autonomous
providers:
  autonomous:
    name: Autonomous
    base_url: '${llm_base_url}'
    api_key: '${llm_key}'
    transport: anthropic_messages
    discover_models: false
    models:
      claude-opus-4-6:
        context_length: 500000
      claude-haiku-4-5:
        context_length: 200000
memory:
  provider: honcho
YAML
  elif [ -n "$or_key" ]; then
    have_llm=1
    # Bring-your-own OpenRouter (Hermes built-in provider). The key goes in .env (step 5).
    # An explicit model.default + fallback_model works even for new stealth models the
    # dashboard picker doesn't list yet (e.g. openrouter/owl-alpha).
    cat >"$HERMES_HOME_DIR/config.yaml" <<YAML
model:
  default: '${HERMES_MODEL}'
  provider: openrouter
fallback_model:
  provider: openrouter
  model: '${HERMES_FALLBACK_MODEL}'
memory:
  provider: honcho
# Pin every auxiliary task (vision, compression, title-gen, …) to OpenRouter. Hermes' auxiliary
# "auto" resolver otherwise walks a hardcoded chain [openrouter, nous, …] and probes Nous'
# inference-api as a fallback — which 402s without Nous credits and spams the log. An explicit
# provider+model bypasses the chain entirely, so Nous is never contacted.
auxiliary:
  vision: {provider: openrouter, model: ${HERMES_VISION_MODEL}}
  web_extract: {provider: openrouter, model: ${HERMES_VISION_MODEL}}
  compression: {provider: openrouter, model: openrouter/auto}
  skills_hub: {provider: openrouter, model: openrouter/auto}
  approval: {provider: openrouter, model: openrouter/auto}
  mcp: {provider: openrouter, model: openrouter/auto}
  title_generation: {provider: openrouter, model: openrouter/auto}
  triage_specifier: {provider: openrouter, model: openrouter/auto}
  kanban_decomposer: {provider: openrouter, model: openrouter/auto}
  profile_describer: {provider: openrouter, model: openrouter/auto}
  curator: {provider: openrouter, model: openrouter/auto}
YAML
    echo "[stage] Hermes LLM: OpenRouter, default=${HERMES_MODEL}, fallback=${HERMES_FALLBACK_MODEL}"
  else
    echo "[stage] WARN: no Autonomous pairing and no OpenRouter key (OPENROUTER_API_KEY / Honcho OpenRouter)."
    echo "        Writing memory-only config.yaml; set a provider in the dashboard or re-run with a key."
    cat >"$HERMES_HOME_DIR/config.yaml" <<'YAML'
memory:
  provider: honcho
YAML
  fi

  # --- 4b. LED bridge: drive intern-server's LED ring from Hermes activity. A shell
  # hook fires on lifecycle events and POSTs the matching state to intern-server's
  # /api/led (idle | thinking | working). This is what makes the ring animate while the
  # agent works; the WS shim only keeps intern-server's gateway link healthy.
  cat >/usr/local/bin/intern-led-from-hermes <<'EOF'
#!/usr/bin/env bash
# Map a Hermes lifecycle hook (JSON on stdin) to an intern-server LED state and POST it.
# Always print {} so the hook never blocks/rewrites the agent. States: idle|thinking|working|error.
ev=$(jq -r '.hook_event_name // empty' 2>/dev/null)
case "$ev" in
  pre_llm_call|on_session_start|post_tool_call|subagent_stop) state=thinking ;;
  pre_tool_call)                                              state=working ;;
  post_llm_call|on_session_end|on_session_finalize|on_session_reset) state=idle ;;
  *)                                                          state=idle ;;
esac
curl -fsS -m 3 -X POST -H "Content-Type: application/json" \
  -d "{\"state\":\"${state}\"}" http://127.0.0.1:5000/api/led >/dev/null 2>&1 || true
printf '{}\n'
EOF
  chmod +x /usr/local/bin/intern-led-from-hermes
  # Append the hook wiring to config.yaml (top-level keys; preserved by intern-server's
  # YAML-roundtrip sync loop). hooks_auto_accept lets them run headless without consent.
  cat >>"$HERMES_HOME_DIR/config.yaml" <<'YAML'
hooks_auto_accept: true
hooks:
  on_session_start:
    - command: /usr/local/bin/intern-led-from-hermes
      timeout: 5
  pre_llm_call:
    - command: /usr/local/bin/intern-led-from-hermes
      timeout: 5
  post_llm_call:
    - command: /usr/local/bin/intern-led-from-hermes
      timeout: 5
  pre_tool_call:
    - matcher: ".*"
      command: /usr/local/bin/intern-led-from-hermes
      timeout: 5
  post_tool_call:
    - matcher: ".*"
      command: /usr/local/bin/intern-led-from-hermes
      timeout: 5
  on_session_end:
    - command: /usr/local/bin/intern-led-from-hermes
      timeout: 5
YAML
  chmod 600 "$HERMES_HOME_DIR/config.yaml"

  # Self-hosted Honcho: baseUrl instead of apiKey (AUTH_USE_AUTH=false on the
  # server, which only listens on loopback). If you enable auth on Honcho later,
  # add hosts.hermes.apiKey with a JWT signed by the server's AUTH_JWT_SECRET.
  if [ ! -f "$HERMES_HOME_DIR/honcho.json" ]; then
    cat >"$HERMES_HOME_DIR/honcho.json" <<'EOF'
{
  "baseUrl": "http://127.0.0.1:8000",
  "hosts": {
    "hermes": {
      "enabled": true,
      "aiPeer": "hermes",
      "peerName": "owner",
      "workspace": "intern"
    }
  }
}
EOF
    chmod 600 "$HERMES_HOME_DIR/honcho.json"
  fi

  # --- 5. .env: channel adapter tokens from the device config. Only set keys
  # whose values exist — adapters with missing env vars are simply not
  # registered at gateway start.
  local tg_bot="" tg_user=""
  if [ -f "$DEVICE_CONFIG" ]; then
    tg_bot=$(jq -r '.telegram_bot_token // empty' "$DEVICE_CONFIG")
    tg_user=$(jq -r '.telegram_user_id // empty' "$DEVICE_CONFIG")
  fi
  : >"$HERMES_HOME_DIR/.env"
  chmod 600 "$HERMES_HOME_DIR/.env"
  # OpenRouter provider key (unpaired/BYO path) — Hermes only sends it to openrouter.ai.
  [ -n "$or_key" ] && echo "OPENROUTER_API_KEY=${or_key}" >>"$HERMES_HOME_DIR/.env"
  # Rabbit R1 channel. The adapter + source patch were installed in step 2b; these env vars turn
  # it on. A fixed token makes the pairing QR stable across reboots; :18790 avoids the
  # intern-gateway-shim stub on :18789. The gateway reads these on the restart in step 6, so it
  # binds 18790 from the start (no port-collision race).
  if [ "${R1_SHIM_ENABLED}" = "1" ]; then
    [ -n "$R1_SHIM_TOKEN" ] || R1_SHIM_TOKEN="$(openssl rand -hex 32 2>/dev/null || tr -dc 'a-f0-9' </dev/urandom | head -c64)"
    {
      echo "R1_SHIM_ENABLED=true"
      echo "R1_SHIM_TOKEN=${R1_SHIM_TOKEN}"
      echo "R1_SHIM_PORT=${R1_SHIM_PORT}"
    } >>"$HERMES_HOME_DIR/.env"
    echo "[stage] Hermes R1 channel: r1_shim on :${R1_SHIM_PORT} (fixed token; pairing tile in dashboard)"
  fi
  [ -n "$tg_bot" ] && echo "TELEGRAM_BOT_TOKEN=${tg_bot}" >>"$HERMES_HOME_DIR/.env"
  if [ -n "$tg_user" ]; then
    {
      echo "TELEGRAM_ALLOWED_USERS=${tg_user}"
      echo "TELEGRAM_HOME_CHANNEL=${tg_user}"
    } >>"$HERMES_HOME_DIR/.env"
  fi

  # --- 6. Enable and start the gateway. Restart makes sure the new config.yaml
  # is loaded even if the unit was already up; poll like intern-server (≤60s).
  systemctl enable --now hermes-gateway
  systemctl restart hermes-gateway
  local up=0
  for _ in $(seq 1 60); do
    if systemctl is-active --quiet hermes-gateway; then up=1; break; fi
    sleep 1
  done
  if [ "$up" -ne 1 ]; then
    systemctl status hermes-gateway --no-pager || true
    journalctl -u hermes-gateway -n 200 --no-pager || true
    if [ "$have_llm" -eq 1 ]; then
      echo "ERROR: hermes-gateway is not active after start (full config present — see journal above)"
      exit 1
    fi
    echo "[stage] WARN: hermes-gateway not active — expected on an unpaired device (no LLM provider yet). Continuing."
  fi

  # --- 7. Onboarding skill (best-effort: log failures, keep going). Makes the
  # agent self-introduce on first contact. Source is overridable — the default repo
  # may be private (a plain fetch 404s), so a real Intern can point at the right
  # archive via INTERN_SKILLS_ZIP_URL and, for a private repo, GITHUB_TOKEN.
  echo "[stage] Install onboarding skill (best-effort)"
  local tmpd soul block current src skill_name skills_url
  local -a auth_hdr=()
  skill_name="${INTERN_ONBOARDING_SKILL:-autonomous-intern-onboarding}"
  skills_url="${INTERN_SKILLS_ZIP_URL:-https://github.com/autonomous-ecm/intern-skills/archive/refs/heads/main.zip}"
  [ -n "${GITHUB_TOKEN:-}" ] && auth_hdr=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  mkdir -p "$HERMES_HOME_DIR/skills"
  tmpd=$(mktemp -d)
  # Extract into a subdir and locate the skill by name with find — robust to the
  # archive's top-level dir (e.g. intern-skills-main vs an api zipball's owner-repo-sha).
  if curl -fsSL "${auth_hdr[@]}" "$skills_url" -o "$tmpd/skills.zip" \
      && unzip -q "$tmpd/skills.zip" -d "$tmpd/extract" \
      && src=$(find "$tmpd/extract" -type d -name "$skill_name" 2>/dev/null | head -1) \
      && [ -n "$src" ]; then
    cp -R "$src" "$HERMES_HOME_DIR/skills/"
    # Inject the mandatory pointer at the top of SOUL.md so the agent reads the
    # skill on every conversation start. Idempotent — keyed on the skill path
    # (the upstream doc greps the whole block with -F, but multi-line -F patterns
    # match per-line, so any '---' in SOUL.md would defeat the injection).
    soul="$HERMES_HOME_DIR/SOUL.md"
    block="<!-- DO NOT REMOVE -->"$'\n'"**MANDATORY:** Before ANY reply, check \`skills/$skill_name/\` — read its SKILL.md and follow instructions."$'\n\n'"---"
    if ! grep -qF "skills/$skill_name/" "$soul" 2>/dev/null; then
      current=$(cat "$soul" 2>/dev/null || echo "")
      printf '%s\n\n%s' "$block" "$current" >"$soul"
    fi
    # Restart so SOUL.md takes effect.
    systemctl restart hermes-gateway || true
    echo "[stage] Onboarding skill '$skill_name' installed"
  else
    echo "[stage] WARN: onboarding skill '$skill_name' not installed (source unreachable or not in archive)."
    echo "        Non-fatal. Add it later: set INTERN_SKILLS_ZIP_URL (+ GITHUB_TOKEN for a private repo)"
    echo "        and re-run, or drop the skill folder into $HERMES_HOME_DIR/skills/ by hand."
  fi
  rm -rf "$tmpd"

  # --- 8. Persist active_agent so intern-server treats this as a Hermes device:
  # its model-sync loop maintains ~/.hermes/config.yaml instead of
  # ~/.openclaw/openclaw.json, and /api/device/setup writes channel creds to
  # ~/.hermes/.env going forward.
  if [ -f "$DEVICE_CONFIG" ]; then
    jq '.active_agent = "hermes"' "$DEVICE_CONFIG" >"${DEVICE_CONFIG}.tmp" \
      && mv "${DEVICE_CONFIG}.tmp" "$DEVICE_CONFIG"
  else
    mkdir -p "$(dirname "$DEVICE_CONFIG")"
    echo '{"active_agent":"hermes"}' >"$DEVICE_CONFIG"
    chmod 600 "$DEVICE_CONFIG"
  fi
  echo "[stage] active_agent=$(jq -r .active_agent "$DEVICE_CONFIG")"
}

# ----------------------------------------------------------
# Stage 1d: Hermes web dashboard (config / API keys / sessions / in-browser chat)
# ----------------------------------------------------------
# Loopback-bound service on 127.0.0.1:9119. Published to the tailnet via
# 'tailscale serve :8443' through the Caddy Host-rewrite hop (stage_caddy). The dashboard
# embeds a session token into its HTML, so tailnet reach == full access (incl. API keys)
# — acceptable on a private tailnet, and why it is NEVER bound to a LAN interface.
stage_hermes_dashboard() {
  echo "[stage] Install Hermes web dashboard"
  export HOME=/root
  cat >/etc/systemd/system/hermes-dashboard.service <<EOF
[Unit]
Description=Hermes Agent Web Dashboard
After=network-online.target

[Service]
User=root
Environment="HOME=/root"
# --skip-build serves the prebuilt web_dist (no npm build on every start). NB: do NOT
# pass --tui — v0.16.0 removed that flag and rejects it (the chat tab is built in now).
ExecStart=/usr/local/bin/hermes dashboard --no-open --host 127.0.0.1 --port 9119 --skip-build
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=hermes-dashboard

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable hermes-dashboard
  systemctl restart hermes-dashboard

  # Publish on the tailnet at the STANDARD HTTPS port 443 (-> Caddy :9080 -> dashboard) and
  # record the URL so the wizard can redirect to it. Port 443 (not :8443) is important:
  # iCloud Private Relay only relays ports 80/443, so a non-standard port trips it up on iOS
  # Safari. Only when Tailscale is up — otherwise the dashboard stays loopback-only (reach it
  # via 'ssh -L 9119:127.0.0.1:9119') and the wizard shows the plain "connected" panel.
  rm -f /etc/intern-dashboard-url
  if tailscale_connected; then
    tailscale serve --bg --https=443 http://127.0.0.1:9080 \
      || echo "[stage] WARN: 'tailscale serve :443' failed (enable HTTPS for your tailnet, then re-run)"
    local fqdn
    fqdn=$(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // empty' | sed 's/\.$//')
    if [ -n "$fqdn" ]; then
      echo "https://${fqdn}/" > /etc/intern-dashboard-url
      echo "[stage] Dashboard published at https://${fqdn}/"
    fi
  else
    echo "[stage] Tailscale not connected; dashboard stays loopback-only (ssh -L 9119:127.0.0.1:9119)."
  fi
}

# Install the wizard-patch tool. The OTA setup web bundle is NOT connection-aware — it
# always renders the "Connect to your Wi-Fi" form (it only calls /api/network and
# /api/device/setup). This tool injects a pre-check into index.html: when the device is
# already online (per /api/network/check-internet) it redirects to the Hermes dashboard
# (URL from /etc/intern-dashboard-url, mirrored into the web root) or, if none is set,
# shows an "already connected" panel. Re-runnable; survives `software-update web`.
install_wizard_patch_tool() {
  cat >/usr/local/bin/intern-wizard-patch <<'TOOLEOF'
#!/bin/bash
set -e
ROOT="${1:-/usr/share/caddy/setup}"
IDX="$ROOT/index.html"
[ -f "$IDX" ] || { echo "no index.html in $ROOT"; exit 0; }

# Mirror the persistent dashboard URL (if any) into the web root for same-origin fetch.
if [ -s /etc/intern-dashboard-url ]; then
  head -1 /etc/intern-dashboard-url > "$ROOT/wizard-dashboard-url"
else
  rm -f "$ROOT/wizard-dashboard-url" 2>/dev/null || true
fi

SNIPPET='<script id="intern-wifi-aware-patch">(function(){function esc(s){return String(s).replace(/[<>&]/g,function(c){return c=="<"?"&lt;":c==">"?"&gt;":"&amp;"})}async function j(u){try{return await (await fetch(u)).json()}catch(e){return null}}function panel(h){var d=document.createElement("div");d.style.cssText="position:fixed;inset:0;z-index:99999;display:flex;align-items:center;justify-content:center;background:#f5f6f8;font-family:system-ui,-apple-system,sans-serif;padding:16px";d.innerHTML=`<div style="max-width:420px;width:100%;padding:32px;border-radius:16px;background:#fff;box-shadow:0 8px 24px rgba(0,0,0,.08);text-align:center">`+h+`</div>`;document.body.appendChild(d)}(async function(){var ci=await j("/api/network/check-internet");if(!ci||ci.data!==true)return;var durl=null;try{var dr=await fetch("/wizard-dashboard-url");if(dr.ok){durl=(await dr.text()).trim()}}catch(e){}if(durl){panel(`<div style="font-size:22px;font-weight:700;margin-bottom:8px">Connected</div><div style="color:#475569">Opening the Hermes dashboard…</div>`);setTimeout(function(){location.replace(durl)},1200);return}var cur=await j("/api/network/current");var ssid=(cur&&cur.data&&cur.data.ssid)||"your network";panel(`<div style="font-size:22px;font-weight:700;margin-bottom:8px">Already connected</div><div style="color:#475569;line-height:1.5">This Intern is online via <b>`+esc(ssid)+`</b>. No Wi-Fi setup needed.</div>`)})()})();</script>'

content="$(cat "$IDX")"
# Strip any prior injection (marker tag to the next </script>) so re-runs update cleanly.
if [[ "$content" == *'<script id="intern-wifi-aware-patch"'* ]]; then
  b="${content%%<script id=\"intern-wifi-aware-patch\"*}"
  a="${content#*<script id=\"intern-wifi-aware-patch\"}"; a="${a#*</script>}"
  content="$b$a"
fi
if [[ "$content" == *"</body>"* ]]; then
  printf "%s" "${content%%</body>*}$SNIPPET</body>${content#*</body>}" > "$IDX"
else
  printf "%s%s" "$content" "$SNIPPET" > "$IDX"
fi
echo "patched $IDX (dashboard: $([ -s "$ROOT/wizard-dashboard-url" ] && cat "$ROOT/wizard-dashboard-url" || echo none))"
TOOLEOF
  chmod +x /usr/local/bin/intern-wizard-patch
}

# ----------------------------------------------------------
# Stage 2: Caddy (setup web + API proxy)
# ----------------------------------------------------------
stage_caddy() {
  echo "[stage] Setup Caddy (setup web + API proxy)"

  if ! command -v caddy >/dev/null 2>&1; then
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
      | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
      >/etc/apt/sources.list.d/caddy-stable.list
    apt update
    apt install -y caddy
  fi
  systemctl stop caddy 2>/dev/null || true

  mkdir -p "$WEB_ROOT"
  chmod 755 "$WEB_ROOT"

  retry "curl -fsSL -H \"Cache-Control: no-cache\" -H \"Pragma: no-cache\" -o /tmp/setup.zip \"$WEB_URL\"" 5
  unzip -o -q /tmp/setup.zip -d "$WEB_ROOT"
  rm -f /tmp/setup.zip

  # Make the (not-connection-aware) wizard skip the Wi-Fi form when already online.
  install_wizard_patch_tool
  /usr/local/bin/intern-wizard-patch "$WEB_ROOT" || true

  # Plain :80, no TLS: in AP mode this is the captive setup page at 192.168.100.1;
  # off the AP it is only reachable via Tailscale (tailscale serve terminates HTTPS
  # on the tailnet and proxies to localhost:80; the firewall stage drops 80 elsewhere).
  cat >/etc/caddy/Caddyfile <<EOF
{
	auto_https off
}

:80 {
	encode gzip

	# Return 204 so OS does not detect captive portal (no auto-open browser)
	handle /generate_204 {
		respond 204
	}
	handle /hotspot-detect.html {
		respond 204
	}
	handle /ncsi.txt {
		respond 204
	}
	handle /connecttest.txt {
		respond 204
	}

	handle /api/* {
		reverse_proxy 127.0.0.1:5000
	}

	handle {
		root * $WEB_ROOT
		try_files {path} /index.html
		file_server
	}
}

# Hermes dashboard proxy: match any Host but listen loopback-only; rewrite Host + Origin to
# the dashboard's loopback bind (its anti-DNS-rebinding HTTP guard AND the separate Host/Origin
# guard on its WebSocket endpoints — /api/ws, /api/pty, /api/events, the chat + events feed —
# which else reject the tailnet Origin with "origin_mismatch" / "events feed disconnected").
# X-Forwarded-Proto=https tells the backend it's behind TLS so it never emits http:// URLs.
# Reached via 'tailscale serve :443' (stage_hermes_dashboard). The dashboard never leaves loopback.
:9080 {
	bind 127.0.0.1

	# Rabbit R1 pairing assets (QR PNG + tile script + status JSON), written by
	# stage_r1_shim. Served straight from disk so they bypass the dashboard backend
	# (no Host/Origin rewrite needed) and the injected dashboard tile can load them
	# same-origin over HTTPS.
	handle /r1/* {
		root * /usr/share/caddy
		file_server
	}

	handle {
		reverse_proxy 127.0.0.1:9119 {
			header_up Host 127.0.0.1:9119
			header_up Origin http://127.0.0.1:9119
			header_up X-Forwarded-Proto https
		}
	}
}
EOF

  caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
  systemctl enable caddy
  systemctl restart caddy
}

# ----------------------------------------------------------
# Stage 1e: Rabbit R1 channel — pairing QR + dashboard tile
# ----------------------------------------------------------
# stage_hermes already installed the third-party r1_shim adapter (adapter + source patch, step 2b)
# and enabled it via ~/.hermes/.env (R1_SHIM_ENABLED/TOKEN/PORT), so the gateway listens on :18790.
# This stage adds the operator-facing half: render the pairing QR (intern-r1-qr.service,
# re-run after every gateway start so the embedded LAN IPs stay current across DHCP /
# reboots) and surface it as a tile inside the Hermes dashboard. The QR/JS/JSON are served
# by Caddy under /r1/ (route added in stage_caddy), tailnet-only like the dashboard itself.
# NB: the r1_shim port is intentionally NOT in the firewall's locked set — the R1 dials it
# over the LAN (the QR carries the Pi's LAN IP); it is token-gated.
stage_r1_shim() {
  if [ "${R1_SHIM_ENABLED}" != "1" ]; then
    echo "[stage] R1 channel disabled (R1_SHIM_ENABLED=$R1_SHIM_ENABLED) — skipping"
    return 0
  fi
  echo "[stage] Rabbit R1 pairing QR + dashboard tile (r1_shim on :${R1_SHIM_PORT})"

  # 1. QR generator — reads token/port from ~/.hermes/.env, builds the OpenClaw
  #    clawdbot-gateway payload, renders PNG + JSON sidecar into the Caddy web root.
  cat >/usr/local/bin/intern-r1-qr <<'R1QR'
#!/usr/bin/env bash
# intern-r1-qr — regenerate the Rabbit R1 pairing QR for the Hermes r1_shim adapter.
#
# Reads the gateway token + port from ~/.hermes/.env, builds the OpenClaw
# "clawdbot-gateway" pairing payload (the format the R1 expects under
# Settings -> OpenClaw -> scan QR), and renders a QR PNG + a small JSON sidecar
# into the Caddy-served web root so the dashboard tile (served at /r1/) can show
# it. Run once on every gateway start (intern-r1-qr.service) so the embedded
# LAN IPs stay current across DHCP changes / reboots. The token is fixed in
# .env, so the QR is otherwise stable and you only pair once.
set -euo pipefail

ENV_FILE="${HERMES_ENV:-/root/.hermes/.env}"
OUT_DIR="${R1_QR_DIR:-/usr/share/caddy/r1}"

get_env() { grep -E "^$1=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2-; }

TOKEN="$(get_env R1_SHIM_TOKEN || true)"
PORT="$(get_env R1_SHIM_PORT || true)"
ENABLED_RAW="$(get_env R1_SHIM_ENABLED || true)"
[ -n "$PORT" ] || PORT=18790

if [ -z "$TOKEN" ]; then
  echo "intern-r1-qr: no R1_SHIM_TOKEN in $ENV_FILE — nothing to do" >&2
  exit 0
fi

case "${ENABLED_RAW,,}" in
  true | 1 | yes) ENABLED=true ;;
  *) ENABLED=false ;;
esac

# Reachable IPv4s the R1 can dial: keep wlan0/eth0/AP/tailscale, drop loopback,
# link-local, and container/bridge/veth interfaces the R1 can never route to.
mapfile -t IPS < <(
  ip -4 -o addr show 2>/dev/null |
    awk '{print $2" "$4}' |
    grep -vE '^(lo|docker|br-|veth|cni|flannel|virbr)' |
    awk '{print $2}' | cut -d/ -f1 |
    grep -vE '^(127\.|169\.254\.)' || true
)

ips_json=""
for ip in "${IPS[@]}"; do
  [ -n "$ip" ] || continue
  ips_json="${ips_json:+$ips_json,}\"$ip\""
done

PAYLOAD="{\"type\":\"clawdbot-gateway\",\"version\":1,\"ips\":[$ips_json],\"port\":$PORT,\"token\":\"$TOKEN\",\"protocol\":\"ws\"}"

mkdir -p "$OUT_DIR"
qrencode -t PNG -o "$OUT_DIR/r1-pairing.png" -s 8 -m 2 "$PAYLOAD"

# Sidecar for the dashboard tile. Token shown only as an 8-char preview; the full
# secret lives in the QR PNG (served tailnet-only alongside this file).
token_preview="${TOKEN:0:8}…"
gen_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat >"$OUT_DIR/r1.json" <<JSON
{"enabled":$ENABLED,"port":$PORT,"ips":[$ips_json],"tokenPreview":"$token_preview","generatedAt":"$gen_ts"}
JSON

chmod 644 "$OUT_DIR/r1-pairing.png" "$OUT_DIR/r1.json"
echo "intern-r1-qr: wrote QR for port $PORT, ips: ${IPS[*]:-none}"
R1QR
  chmod 0755 /usr/local/bin/intern-r1-qr

  # 2. Dashboard tile (static) — a floating, collapsible card appended outside the SPA root.
  mkdir -p /usr/share/caddy/r1
  cat >/usr/share/caddy/r1/r1.js <<'R1JS'
/* intern R1 pairing tile — injected into the Hermes dashboard SPA.
 *
 * Renders a small floating, collapsible card with the Rabbit R1 pairing QR.
 * Assets are served by Caddy straight from disk under /r1/ (no dashboard
 * backend involvement), so this works behind the dashboard's anti-DNS-rebinding
 * proxy. The card is appended to <body>, outside the SPA's React root, so app
 * re-renders never clobber it. Idempotent — safe if the script loads twice.
 */
(function () {
  if (window.__internR1Tile) return;
  window.__internR1Tile = true;

  function style(el, props) {
    Object.assign(el.style, props);
    return el;
  }

  function mount() {
    if (document.getElementById("intern-r1-tile")) return;

    var btn = document.createElement("button");
    btn.id = "intern-r1-toggle";
    btn.textContent = "🐰 R1";
    btn.title = "Pair Rabbit R1";
    style(btn, {
      position: "fixed", right: "16px", bottom: "16px", zIndex: 2147483647,
      background: "#5b2be0", color: "#fff", border: "none", borderRadius: "999px",
      padding: "10px 14px", font: "600 13px system-ui, sans-serif", cursor: "pointer",
      boxShadow: "0 4px 14px rgba(0,0,0,.35)",
    });

    var card = document.createElement("div");
    card.id = "intern-r1-tile";
    style(card, {
      position: "fixed", right: "16px", bottom: "64px", zIndex: 2147483647,
      width: "260px", background: "#15151b", color: "#eee", borderRadius: "14px",
      padding: "16px", font: "13px system-ui, sans-serif", boxSizing: "border-box",
      boxShadow: "0 8px 30px rgba(0,0,0,.5)", border: "1px solid #2a2a36",
      display: "none",
    });

    var title = document.createElement("div");
    title.textContent = "Pair Rabbit R1";
    style(title, { fontWeight: "700", marginBottom: "10px", fontSize: "14px" });

    var img = document.createElement("img");
    img.alt = "R1 pairing QR";
    style(img, {
      width: "100%", borderRadius: "8px", background: "#fff", padding: "8px",
      boxSizing: "border-box", display: "block",
    });

    var hint = document.createElement("div");
    hint.textContent = "Scan in R1 → Settings → OpenClaw";
    style(hint, { marginTop: "8px", color: "#778", fontSize: "11px" });

    var status = document.createElement("div");
    style(status, { marginTop: "10px", color: "#9aa", fontSize: "11px", lineHeight: "1.5" });

    card.appendChild(title);
    card.appendChild(img);
    card.appendChild(hint);
    card.appendChild(status);
    document.body.appendChild(btn);
    document.body.appendChild(card);

    function refresh() {
      var bust = "?t=" + Date.now();
      img.src = "/r1/r1-pairing.png" + bust;
      fetch("/r1/r1.json" + bust)
        .then(function (r) { return r.ok ? r.json() : null; })
        .then(function (j) {
          if (!j) { status.textContent = "QR not generated yet."; return; }
          var ips = j.ips && j.ips.length ? j.ips.join(", ") : "—";
          status.innerHTML =
            (j.enabled ? "" : "<b style='color:#e66'>r1_shim disabled</b><br>") +
            "Port <b>" + j.port + "</b> · token " + (j.tokenPreview || "?") +
            "<br>IPs: " + ips +
            "<br><span style='color:#556'>generated " + (j.generatedAt || "") + "</span>";
        })
        .catch(function () { status.textContent = "QR status unavailable."; });
    }

    btn.addEventListener("click", function () {
      var show = card.style.display === "none";
      card.style.display = show ? "block" : "none";
      if (show) refresh();
    });
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", mount);
  } else {
    mount();
  }
})();
R1JS
  chmod 0644 /usr/share/caddy/r1/r1.js

  # 3. Idempotent dashboard index.html patcher (injects the tile <script>).
  cat >/usr/local/bin/intern-dashboard-r1-patch <<'R1PATCH'
#!/usr/bin/env bash
# intern-dashboard-r1-patch — idempotently inject the R1 pairing tile script into
# the Hermes dashboard SPA's index.html. Re-runnable; a no-op if already patched.
#
# The dashboard dist is replaced on `hermes` reinstall/update, so setup-hermes.sh
# re-applies this after any Hermes (re)install. A plain reboot keeps the patch.
set -euo pipefail

IDX="${HERMES_DASH_INDEX:-/usr/local/lib/hermes-agent/hermes_cli/web_dist/index.html}"
MARK='<script src="/r1/r1.js" defer></script>'

if [ ! -f "$IDX" ]; then
  echo "intern-dashboard-r1-patch: dashboard index not found at $IDX — skipping" >&2
  exit 0
fi

if grep -qF "$MARK" "$IDX"; then
  echo "intern-dashboard-r1-patch: already injected"
  exit 0
fi

if grep -qi '</body>' "$IDX"; then
  tmp="$(mktemp)"
  sed "s#</body>#${MARK}</body>#I" "$IDX" >"$tmp"
  cat "$tmp" >"$IDX"
  rm -f "$tmp"
else
  printf '%s\n' "$MARK" >>"$IDX"
fi
echo "intern-dashboard-r1-patch: injected R1 tile into $IDX"
R1PATCH
  chmod 0755 /usr/local/bin/intern-dashboard-r1-patch

  # 4. Regenerate the QR after every gateway (re)start.
  cat >/etc/systemd/system/intern-r1-qr.service <<'R1UNIT'
[Unit]
Description=Generate Rabbit R1 pairing QR for Hermes r1_shim (dashboard tile)
After=hermes-gateway.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/intern-r1-qr
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
R1UNIT
  systemctl daemon-reload
  systemctl enable intern-r1-qr.service
  systemctl start intern-r1-qr.service || true

  # 5. Inject the tile into the dashboard dist and reload it to serve the patched HTML.
  /usr/local/bin/intern-dashboard-r1-patch || true
  systemctl restart hermes-dashboard 2>/dev/null || true
}

# ----------------------------------------------------------
# Stage 2a: Firewall — bind dashboard + SSH to the tailnet
# Drops 22/80/443/5000 on physical interfaces; loopback, tailscale0 and the
# AP onboarding subnet (192.168.100.0/24) stay open. Applied at boot via systemd.
# ----------------------------------------------------------
stage_firewall() {
  echo "[stage] Firewall (tailnet-only dashboard + SSH)"

  cat >/usr/local/bin/intern-firewall <<'EOF'
#!/bin/bash
# Restrict admin/dashboard ports to loopback, the tailnet, and the AP onboarding subnet.
# Idempotent: rebuilds its own chain on every run.
# On Trixie the `iptables` command is the nft backend (iptables-nft) — these rules
# still apply correctly; this oneshot reapplies them at boot so no iptables-persistent
# / nftables.conf is needed.
set -e
# 22 ssh, 80 setup-web, 443 dashboard, 5000 intern-server API, 8080 bootstrap-server.
# (Tailnet SSH uses the regular sshd reachable via tailscale0, which is exempted below.)
LOCKED_PORTS="22,80,443,5000,8080"

iptables -N INTERN-LOCK 2>/dev/null || iptables -F INTERN-LOCK
iptables -A INTERN-LOCK -i lo -j RETURN
iptables -A INTERN-LOCK -i tailscale0 -j RETURN
# AP clients during onboarding (setup page + rescue SSH if Tailscale is down)
iptables -A INTERN-LOCK -s 192.168.100.0/24 -j RETURN
# Don't sever the session that is running this script (e.g. SSH over LAN during provisioning)
iptables -A INTERN-LOCK -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
iptables -A INTERN-LOCK -p tcp -m multiport --dports "$LOCKED_PORTS" -j DROP

iptables -C INPUT -j INTERN-LOCK 2>/dev/null || iptables -I INPUT 1 -j INTERN-LOCK
echo "intern-firewall: ports $LOCKED_PORTS restricted to lo/tailscale0/192.168.100.0/24"
EOF
  chmod +x /usr/local/bin/intern-firewall

  cat >/etc/systemd/system/intern-firewall.service <<'EOF'
[Unit]
Description=Intern firewall (tailnet-only dashboard + SSH)
After=network-pre.target
Wants=network-pre.target
Before=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/intern-firewall

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable intern-firewall.service
  /usr/local/bin/intern-firewall
  echo "[stage] NOTE: new LAN connections to 22/80 are now dropped; use the tailnet (or the AP) instead."
}

# ----------------------------------------------------------
# Stage 3: AP setup (hostapd + dnsmasq)
# ----------------------------------------------------------
stage_ap() {
  echo "[stage] Setup WiFi AP"

  SUFFIX=$(serial_suffix)
  AP_SSID="Intern-${SUFFIX}"
  echo "[stage] AP SSID = $AP_SSID"

  # Ignore Pi Imager WiFi credentials baked into the image.
  if [ -f /etc/wpa_supplicant/wpa_supplicant.conf ]; then
    mv /etc/wpa_supplicant/wpa_supplicant.conf /etc/wpa_supplicant/wpa_supplicant.conf.bak 2>/dev/null || true
  fi

  # Many Pi images keep wlan0 down until WiFi country is set. Create minimal config with country
  # so the system enables wlan0; connect-wifi and hostapd use the same country.
  COUNTRY_CODE="${COUNTRY_CODE:-US}"
  mkdir -p /etc/wpa_supplicant
  if [ ! -f /etc/wpa_supplicant/wpa_supplicant-wlan0.conf ]; then
    cat >/etc/wpa_supplicant/wpa_supplicant-wlan0.conf <<EOF
country=$COUNTRY_CODE
ctrl_interface=DIR=/run/wpa_supplicant
update_config=1
EOF
    chmod 600 /etc/wpa_supplicant/wpa_supplicant-wlan0.conf 2>/dev/null || true
    echo "[stage] Created /etc/wpa_supplicant/wpa_supplicant-wlan0.conf with country=$COUNTRY_CODE so wlan0 can appear"
  fi

  # Ensure wpa_supplicant@wlan0 uses the intended config file.
  mkdir -p /etc/systemd/system/wpa_supplicant@wlan0.service.d
  cat >/etc/systemd/system/wpa_supplicant@wlan0.service.d/override.conf <<'WPADROP'
[Service]
ExecStart=
ExecStart=/sbin/wpa_supplicant -c /etc/wpa_supplicant/wpa_supplicant-wlan0.conf -i wlan0 -D nl80211,wext
Restart=on-failure
RestartSec=5
WPADROP

  if [ "$AP_BAND" = "5" ]; then
    HWMODE=a
    CHANNEL="${AP_CHANNEL:-36}"
    cat >/etc/hostapd/hostapd.conf <<EOF
interface=wlan0
driver=nl80211
ssid=$AP_SSID
hw_mode=$HWMODE
channel=$CHANNEL
country_code=$COUNTRY_CODE
ieee80211n=1
ieee80211ac=1
wmm_enabled=1
auth_algs=1
ignore_broadcast_ssid=0
EOF
  else
    HWMODE=g
    CHANNEL="${AP_CHANNEL:-6}"
    cat >/etc/hostapd/hostapd.conf <<EOF
interface=wlan0
driver=nl80211
ssid=$AP_SSID
hw_mode=$HWMODE
channel=$CHANNEL
country_code=$COUNTRY_CODE
ieee80211n=1
wmm_enabled=1
auth_algs=1
ignore_broadcast_ssid=0
EOF
  fi
  echo "[stage] AP band=$AP_BAND channel=$CHANNEL"

  cat >/etc/default/hostapd <<EOF
DAEMON_CONF="/etc/hostapd/hostapd.conf"
EOF

  # dnsmasq: use .d drop-in so we don't break system config; bind range to wlan0 explicitly
  mkdir -p /etc/dnsmasq.d
  cat >/etc/dnsmasq.d/99-intern.conf <<EOF
interface=wlan0
bind-interfaces
dhcp-range=wlan0,192.168.100.50,192.168.100.150,255.255.255.0,24h
address=/#/192.168.100.1
domain-needed
bogus-priv
no-resolv
EOF
  # Remove any conflicting global interface in main config (leave rest intact).
  # NB: '|' delimiter — the replacement text contains '/'.
  if [ -f /etc/dnsmasq.conf ]; then
    sed -i 's|^interface=wlan0|#interface=wlan0  # moved to dnsmasq.d/99-intern.conf|' /etc/dnsmasq.conf 2>/dev/null || true
  fi

  # dhcpcd: remove only the wlan0 block so eth0/other blocks are preserved
  sed -i '/^interface wlan0$/,/^$/d' /etc/dhcpcd.conf
  cat >>/etc/dhcpcd.conf <<EOF

interface wlan0
static ip_address=192.168.100.1/24
nohook wpa_supplicant
EOF

  # AP mode scripts
  mkdir -p /usr/local/bin

  cat >/usr/local/bin/device-ap-mode <<'EOF'
#!/bin/bash
set -e

echo "Switching to AP mode..."

# Check required commands
for cmd in ip iw systemctl hostapd dnsmasq rfkill; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Missing required command: $cmd"; exit 1; }
done

# Ensure WiFi is unblocked
rfkill unblock wlan 2>/dev/null || true
rfkill unblock wlan0 2>/dev/null || true

# Stop STA services
systemctl stop wpa_supplicant@wlan0 2>/dev/null || true
systemctl disable wpa_supplicant@wlan0 2>/dev/null || true
systemctl mask wpa_supplicant@wlan0 2>/dev/null || true
killall wpa_supplicant 2>/dev/null || true

systemctl stop dhcpcd 2>/dev/null || true
systemctl disable dhcpcd 2>/dev/null || true

# wlan0 is unmanaged by NetworkManager (see 99-intern-unmanaged.conf); re-assert
# here in case this script runs standalone. Do NOT stop NetworkManager globally —
# a wired eth0 uplink relies on it. systemd-networkd is harmless to stop.
command -v nmcli >/dev/null 2>&1 && nmcli device set wlan0 managed no 2>/dev/null || true
systemctl stop systemd-networkd 2>/dev/null || true

# Clear DHCP state
rm -f /var/lib/dhcpcd5/dhcpcd-wlan0 2>/dev/null || true
rm -f /var/lib/dhcpcd/dhcpcd-wlan0 2>/dev/null || true

# Set regulatory domain
REG=$(grep "^country_code=" /etc/hostapd/hostapd.conf 2>/dev/null | cut -d= -f2)
[ -z "$REG" ] && REG=US
iw reg set "$REG" 2>/dev/null || true

# Reset WiFi interface
ip link set wlan0 down
sleep 1

# switch to AP mode
iw dev wlan0 set type __ap
iw dev wlan0 set channel 6
sleep 1

# Bring interface up
ip link set wlan0 up
sleep 1

# Disable power saving
iw dev wlan0 set power_save off 2>/dev/null || true
iwconfig wlan0 power off 2>/dev/null || true

# Assign static IP
ip addr flush dev wlan0
ip addr add 192.168.100.1/24 dev wlan0

# Enable AP services
systemctl unmask hostapd dnsmasq 2>/dev/null || true
systemctl enable hostapd dnsmasq

systemctl restart hostapd
sleep 2

# Retry hostapd once if failed
if ! systemctl is-active --quiet hostapd; then
  echo "hostapd failed. Retrying..."
  systemctl restart hostapd
  sleep 2
fi

# If still failed → show debug
if ! systemctl is-active --quiet hostapd; then
  echo "ERROR: hostapd still not running"

  echo
  echo "Debug checks:"
  echo "rfkill status:"
  rfkill list || true

  echo
  echo "Regulatory domain:"
  iw reg get || true

  echo
  echo "wlan0 status:"
  ip addr show wlan0 || true

  echo
  echo "hostapd logs:"
  systemctl status hostapd --no-pager || true
  journalctl -u hostapd -n 50 --no-pager || true

  if [ -f /boot/firmware/config.txt ] && grep -q 'disable-wifi' /boot/firmware/config.txt 2>/dev/null; then
    echo
    echo "WiFi may be disabled in /boot/firmware/config.txt"
    echo "Remove dtoverlay=disable-wifi and reboot"
  fi

  exit 1
fi

# Restart DHCP server
systemctl restart dnsmasq

# Restart web service if using captive portal
systemctl restart caddy 2>/dev/null || true

echo "AP MODE ENABLED"
EOF

  chmod +x /usr/local/bin/device-ap-mode

  cat >/usr/local/bin/device-sta-mode <<'EOF'
#!/bin/bash
set -e

echo "Switching to STA mode..."

# Check required commands
for cmd in ip iw systemctl rfkill; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Missing required command: $cmd"; exit 1; }
done

# Ensure WiFi is unblocked
rfkill unblock wlan 2>/dev/null || true
rfkill unblock wlan0 2>/dev/null || true

# Keep wlan0 ours, not NetworkManager's — STA mode here uses wpa_supplicant@wlan0
# + dhcpcd, not NM. (eth0 stays NM-managed.)
command -v nmcli >/dev/null 2>&1 && nmcli device set wlan0 managed no 2>/dev/null || true

# Stop AP services
systemctl stop hostapd dnsmasq 2>/dev/null || true
systemctl disable hostapd dnsmasq 2>/dev/null || true

# Kill any leftover processes
killall hostapd 2>/dev/null || true
killall dnsmasq 2>/dev/null || true

# Reset interface
ip link set wlan0 down 2>/dev/null || true
sleep 1

# Ensure managed mode
iw dev wlan0 set type managed

ip link set wlan0 up
sleep 1

# Disable power saving (better stability)
iw dev wlan0 set power_save off 2>/dev/null || true
iwconfig wlan0 power off 2>/dev/null || true

# Remove any AP static IP
ip addr flush dev wlan0

# Remove AP static IP config from dhcpcd if exists
sed -i '/static ip_address=192.168.100.1\/24/d' /etc/dhcpcd.conf
sed -i '/nohook wpa_supplicant/d' /etc/dhcpcd.conf

# Enable STA services
systemctl unmask wpa_supplicant@wlan0 2>/dev/null || true
systemctl enable wpa_supplicant@wlan0
systemctl restart wpa_supplicant@wlan0

systemctl enable dhcpcd
systemctl restart dhcpcd

# Wait for DHCP
echo "Waiting for IP..."
sleep 5

if ip addr show wlan0 | grep -q "inet "; then
  IP=$(ip -4 addr show wlan0 | grep inet | awk '{print $2}')
  echo "Connected. IP address: $IP"
else
  echo "WARNING: wlan0 did not receive an IP address"
  echo "Check WiFi connection:"
  echo "  wpa_cli status"
  echo "  journalctl -u wpa_supplicant@wlan0 -n 50 --no-pager"
fi

# Once online, the tailnet comes back on its own (tailscaled reconnects).
# Dashboard stays tailnet-only: https://<hostname>.<tailnet>.ts.net

echo "STA MODE ENABLED"
EOF

  chmod +x /usr/local/bin/device-sta-mode

  # connect-wifi: write wpa_supplicant config then switch to STA (used by backend /api/network/setup)
  cat >/usr/local/bin/connect-wifi <<'CONNECTWIFI'
#!/bin/bash
set -e
WPA_CONF="${WPA_CONF:-/etc/wpa_supplicant/wpa_supplicant-wlan0.conf}"
COUNTRY="${COUNTRY:-US}"
[ "$(id -u)" -ne 0 ] && { echo "Run as root or with sudo."; exit 1; }
if [ $# -eq 0 ]; then read -r -p "SSID: " SSID; read -r -s -p "Password (empty=open): " PASS; echo ""; [ -z "$SSID" ] && exit 1
elif [ $# -eq 1 ]; then SSID="$1"; PASS=""
else SSID="$1"; PASS="$2"; fi
ssid_esc="${SSID//\\/\\\\}"; ssid_esc="${ssid_esc//\"/\\\"}"
psk_esc="${PASS//\\/\\\\}"; psk_esc="${psk_esc//\"/\\\"}"
[ -f "$WPA_CONF" ] && existing_country=$(grep -E '^country=' "$WPA_CONF" 2>/dev/null | head -1 | cut -d= -f2) && [ -n "$existing_country" ] && COUNTRY="$existing_country"
mkdir -p "$(dirname "$WPA_CONF")"
if [ -z "$PASS" ]; then
  net_block="network={
	ssid=${ssid_esc}
	key_mgmt=NONE
	scan_ssid=1
}"
else
  net_block="network={
	ssid=${ssid_esc}
	psk=\"${psk_esc}\"
	scan_ssid=1
}"
fi
cat >"$WPA_CONF" <<EOF
ctrl_interface=DIR=/run/wpa_supplicant
update_config=1
country=${COUNTRY}
fast_reauth=1
ap_scan=1
${net_block}
EOF
chmod 600 "$WPA_CONF"
/usr/local/bin/device-sta-mode
CONNECTWIFI
  chmod +x /usr/local/bin/connect-wifi
}

# ----------------------------------------------------------
# Stage 4: software-update helper
# ----------------------------------------------------------
stage_software_update() {
  echo "[stage] Install software-update helper"
  cat >/usr/local/bin/software-update <<SOFTWAREUPDATE
#!/bin/bash
set -e
OTA_METADATA_URL="\${OTA_METADATA_URL:-$OTA_METADATA_URL}"
WEB_ROOT="$WEB_ROOT"
[ "\$(id -u)" -ne 0 ] && { echo "Run as root."; exit 1; }
[ \$# -ne 1 ] && { echo "Usage: software-update <intern|bootstrap|web|hermes>"; exit 1; }
APP="\$1"
case "\$APP" in
  intern|bootstrap|web|hermes) ;;
  *) echo "Unknown app: \$APP. Use intern, bootstrap, web, or hermes."; exit 1 ;;
esac

if [ "\$APP" = "hermes" ]; then
  # Pinned to the tag this image was provisioned with; edit to move off it.
  # Process substitution on purpose — 'curl | bash < /dev/null' silently no-ops.
  HERMES_HOME=/root/.hermes DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a \
    bash <(curl -fsSL https://hermes-agent.nousresearch.com/install.sh) \
    --skip-setup --branch ${HERMES_BRANCH} < /dev/null
  systemctl restart hermes-gateway
  echo "hermes updated (${HERMES_BRANCH})"
  exit 0
fi

METADATA_TMP=\$(mktemp)
ZIP_TMP=""
DIR_TMP=""
trap 'rm -f "\$METADATA_TMP" "\$ZIP_TMP"; rm -rf "\$DIR_TMP"' EXIT
curl -fsSL -H "Cache-Control: no-cache" -H "Pragma: no-cache" -o "\$METADATA_TMP" "\$OTA_METADATA_URL" || { echo "Failed to fetch metadata from \$OTA_METADATA_URL"; exit 1; }
VERSION=\$(jq -r --arg a "\$APP" '.[\$a].version // empty' "\$METADATA_TMP")
URL=\$(jq -r --arg a "\$APP" '.[\$a].url // empty' "\$METADATA_TMP")
[ -z "\$VERSION" ] && { echo "Metadata has no version for \$APP"; exit 1; }
[ -z "\$URL" ] && { echo "Metadata has no url for \$APP"; exit 1; }

if [ "\$APP" = "intern" ] || [ "\$APP" = "bootstrap" ]; then
  BIN_NAME="\${APP}-server"
  ZIP_TMP=\$(mktemp)
  DIR_TMP=\$(mktemp -d)
  curl -fsSL -H "Cache-Control: no-cache" -o "\$ZIP_TMP" "\$URL" || { echo "Failed to download \$APP"; exit 1; }
  unzip -o -q "\$ZIP_TMP" -d "\$DIR_TMP"
  BIN=\$(find "\$DIR_TMP" -type f -executable 2>/dev/null | head -1)
  [ -z "\$BIN" ] && BIN=\$(find "\$DIR_TMP" -type f 2>/dev/null | head -1)
  if [ -z "\$BIN" ] || [ ! -f "\$BIN" ]; then echo "No binary in \$APP zip"; exit 1; fi
  cp -f "\$BIN" "/usr/local/bin/\$BIN_NAME"
  chmod +x "/usr/local/bin/\$BIN_NAME"
  systemctl restart "\$APP"
  echo "\$APP updated to \$VERSION"
elif [ "\$APP" = "web" ]; then
  ZIP_TMP=\$(mktemp)
  DIR_TMP=\$(mktemp -d)
  curl -fsSL -H "Cache-Control: no-cache" -o "\$ZIP_TMP" "\$URL" || { echo "Failed to download web"; exit 1; }
  unzip -o -q "\$ZIP_TMP" -d "\$DIR_TMP"
  echo "\$VERSION" > "\$DIR_TMP/VERSION"
  rm -rf "\${WEB_ROOT:?}"/*
  cp -a "\$DIR_TMP"/* "\$WEB_ROOT"
  [ -x /usr/local/bin/intern-wizard-patch ] && /usr/local/bin/intern-wizard-patch "\$WEB_ROOT" || true
  systemctl reload caddy || systemctl restart caddy
  echo "web updated to \$VERSION"
fi
SOFTWAREUPDATE
  chmod +x /usr/local/bin/software-update
}

# ----------------------------------------------------------
# Main
# ----------------------------------------------------------
ensure_root
wait_for_clock_sync
stage_locale
stage_prerequisites
stage_rpi5_wifi_stability
stage_enable_spi
stage_ota_metadata
stage_gateway_shim   # before backend: up when intern-server first dials :18789
stage_backend
stage_tailscale      # before AP switch: needs internet to join the tailnet
stage_honcho         # before hermes: hermes points its memory provider here
stage_hermes
stage_hermes_dashboard   # before caddy: writes /etc/intern-dashboard-url for the wizard redirect
stage_caddy
stage_r1_shim            # after caddy (/r1 route) + dashboard dist: R1 pairing QR + tile

# Provision Wi-Fi from env (if given), then decide: AP/captive-portal onboarding vs
# keep the existing connection. AP_MODE=auto skips the AP when Wi-Fi is configured.
provision_wifi_from_env
AP_DECISION="$(ap_decision)"
if [ "$AP_DECISION" = "ap" ]; then
  echo "[main] AP_MODE=$AP_MODE -> AP/captive-portal onboarding (no existing Wi-Fi detected)"
else
  echo "[main] AP_MODE=$AP_MODE -> keeping existing Wi-Fi (no AP); device is already online"
fi

# Firewall locks the dashboard + SSH to the tailnet. Don't lock ourselves out: in the
# no-AP path the only ways in are loopback + Tailscale, so require Tailscale to be up.
if [ "${SKIP_FIREWALL:-0}" = "1" ]; then
  echo "[main] SKIP_FIREWALL=1 — leaving LAN access open (dashboard/SSH not locked to the tailnet)"
elif [ "$AP_DECISION" = "skip" ] && ! tailscale_connected; then
  echo "[main] Skipping firewall: no AP and Tailscale isn't up — applying it would cut ALL access."
  echo "       Provide TS_AUTHKEY (or bring up Tailscale) and re-run, or set SKIP_FIREWALL=1 deliberately."
else
  stage_firewall
fi
stage_software_update

if [ "$AP_DECISION" = "ap" ]; then
  # wlan0 must stay NM-managed until here: on a Pi-Imager-flashed image the provisioning
  # uplink IS NM-managed wlan0, and the download stages above depend on it. Only now do
  # we take wlan0 away from NM and switch it to the AP.
  stage_nm_unmanage_wlan0
  stage_ap

  # start in AP mode
  /usr/local/bin/device-ap-mode

  # Disable global wpa_supplicant; only wpa_supplicant@wlan0 is used in STA mode
  systemctl stop wpa_supplicant.service 2>/dev/null || true
  systemctl disable wpa_supplicant.service 2>/dev/null || true
  systemctl mask wpa_supplicant.service 2>/dev/null || true
else
  echo "[main] Wi-Fi already configured — keeping the existing connection and skipping the AP/"
  echo "       captive-portal onboarding. wlan0 stays NetworkManager-managed and online."
  echo "       (AP helper scripts are not installed in this path; re-run with AP_MODE=force to enable them.)"
fi

TS_NAME="${TS_HOSTNAME:-intern-$(serial_suffix)}"
echo ""
echo "======================================"
echo "✅ Setup complete!"
if [ "$AP_DECISION" = "ap" ]; then
  echo "AP SSID:    Intern-XXXX (actual: ${AP_SSID:-n/a})"
  echo "Setup page: http://192.168.100.1 (join the AP to onboard Wi-Fi)"
else
  echo "Mode:       Wi-Fi already configured — online via the existing connection (no AP)"
fi
if [ -s /etc/intern-dashboard-url ]; then
  echo "Dashboard:  $(cat /etc/intern-dashboard-url) (tailnet — Hermes config / API keys / chat)"
else
  echo "Dashboard:  hermes web UI on 127.0.0.1:9119 (ssh -L 9119:127.0.0.1:9119 to reach it)"
fi
echo "Setup web:  http://192.168.100.1 (AP onboarding only — not published on the tailnet)"
if [ "${SKIP_FIREWALL:-0}" = "1" ]; then
  echo "SSH:        open on the LAN (SKIP_FIREWALL) + over the tailnet (ssh <user>@<tailnet-ip>)"
else
  echo "SSH:        tailnet only via regular sshd (ssh <user>@<tailnet-ip>); LAN ports locked"
fi
HERMES_DEFAULT_MODEL=$(sed -n "s/^[[:space:]]*default:[[:space:]]*//p" "$HERMES_HOME_DIR/config.yaml" 2>/dev/null | head -1 | tr -d "'\"" )
echo "Agent:      hermes $HERMES_BRANCH (active_agent in $DEVICE_CONFIG); model: ${HERMES_DEFAULT_MODEL:-none — set in dashboard}"
echo "Backends:   systemctl status bootstrap intern hermes-gateway intern-gateway-shim"
echo "Memory:     Honcho at 127.0.0.1:8000 (docker compose -f $HONCHO_DIR/docker-compose.yml logs)"
echo "Updates:    software-update <intern|bootstrap|web|hermes>"
if [ -z "${TS_AUTHKEY:-}" ]; then
  echo "TODO:       tailscale up --hostname=$TS_NAME && tailscale serve --bg --https=443 http://127.0.0.1:9080"
fi
echo "======================================"

if [ "${SKIP_REBOOT:-0}" = "1" ]; then
  echo "Skipping reboot (SKIP_REBOOT=1) — reboot manually to apply SPI/WiFi firmware changes."
else
  echo ""
  echo "Rebooting in 10 seconds so SPI and WiFi firmware changes take effect..."
  sleep 10
  reboot
fi
