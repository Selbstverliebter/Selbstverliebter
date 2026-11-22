#!/usr/bin/env bash
# Installiert ledstripd + Homebridge + das Plugin auf einem frischen Raspberry Pi OS.
# Aufruf (im Repo-Ordner):   sudo ./install.sh
# Kann beliebig oft wiederholt werden (z. B. nach Updates), Einstellungen bleiben erhalten.
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Bitte mit sudo starten: sudo ./install.sh" >&2
  exit 1
fi

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HB_DIR=/var/lib/homebridge
HB_CFG="$HB_DIR/config.json"
PLUGIN_SRC="$REPO/homebridge-ledstrip-local"
PLUGIN_DST="$HB_DIR/local-plugins/homebridge-ledstrip-local"

step() { echo; echo "==> $*"; }

step "Pakete installieren"
apt-get update
apt-get install -y python3 curl gpg
# lgpio gibt es auf allen Pis (auch Pi 5). pigpio wird genutzt, falls vorhanden (nur Pi 0-4).
apt-get install -y python3-lgpio || apt-get install -y python3-rpi-lgpio || true
apt-get install -y pigpio python3-pigpio 2>/dev/null || echo "   (pigpio nicht verfügbar – kein Problem, nehme lgpio)"
if systemctl list-unit-files pigpiod.service >/dev/null 2>&1; then
  mkdir -p /etc/systemd/system/pigpiod.service.d
  printf '[Service]\nRestart=always\nRestartSec=2\n' > /etc/systemd/system/pigpiod.service.d/restart.conf
  systemctl daemon-reload
  systemctl enable --now pigpiod || true
fi

MODEL="$(tr -d '\0' </proc/device-tree/model 2>/dev/null || echo unbekannt)"
ARCH="$(uname -m)"
echo "   Modell: $MODEL  ($ARCH)"

step "Homebridge installieren (falls noch nicht da)"
HB_VIA_NPM=0
if command -v hb-service >/dev/null 2>&1; then
  echo "   Homebridge ist schon installiert."
  [[ -x /opt/homebridge/bin/npm ]] || HB_VIA_NPM=1
elif [[ "$ARCH" == "armv6l" ]]; then
  # Pi Zero W / Pi 1: Das Homebridge-Paket und offizielles Node.js laufen hier nicht mehr.
  # Wir nehmen Node.js aus den inoffiziellen ARMv6-Builds und Homebridge über npm.
  HB_VIA_NPM=1
  echo "   ARMv6 (Pi Zero W) erkannt → Node.js aus unofficial-builds.nodejs.org"
  NODE_VER="$(curl -fsSL https://unofficial-builds.nodejs.org/download/release/index.json | python3 -c '
import json, sys
for r in json.load(sys.stdin):
    if r["version"].startswith("v22.") and "linux-armv6l" in r["files"]:
        print(r["version"]); break')"
  [[ -n "$NODE_VER" ]] || { echo "Keine Node.js-Version für ARMv6 gefunden." >&2; exit 1; }
  echo "   Node.js $NODE_VER"
  curl -fsSL "https://unofficial-builds.nodejs.org/download/release/$NODE_VER/node-$NODE_VER-linux-armv6l.tar.xz" \
    | tar -xJ -C /usr/local --strip-components=1
  npm install -g --unsafe-perm --no-audit --no-fund homebridge homebridge-config-ui-x
  hb-service install --user homebridge
else
  curl -sSfL https://repo.homebridge.io/KEY.gpg | gpg --dearmor --yes -o /usr/share/keyrings/homebridge.gpg
  echo "deb [signed-by=/usr/share/keyrings/homebridge.gpg] https://repo.homebridge.io stable main" \
    > /etc/apt/sources.list.d/homebridge.list
  apt-get update
  apt-get install -y homebridge
fi

step "ledstripd einrichten"
id ledstrip >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin ledstrip
getent group gpio >/dev/null || groupadd --system gpio
usermod -aG gpio ledstrip
install -d -m 755 /opt/ledstrip /etc/ledstrip
install -m 755 "$REPO/daemon/ledstripd.py" /opt/ledstrip/ledstripd.py
if [[ ! -f /etc/ledstrip/config.json ]]; then
  install -m 644 "$REPO/daemon/config.example.json" /etc/ledstrip/config.json
  echo "   Neue Konfiguration: /etc/ledstrip/config.json  (GPIO-Pins dort prüfen!)"
else
  echo "   Bestehende /etc/ledstrip/config.json bleibt unverändert."
fi
install -m 644 "$REPO/systemd/ledstrip.service" /etc/systemd/system/ledstrip.service
systemctl daemon-reload
systemctl enable ledstrip
systemctl restart ledstrip
sleep 2
if curl -fsS http://127.0.0.1:8765/health; then
  echo; echo "   ledstripd läuft."
else
  echo "   WARNUNG: ledstripd antwortet nicht. Log ansehen: journalctl -u ledstrip -n 50" >&2
fi

step "Homebridge-Plugin installieren"
# Warten, bis Homebridge beim ersten Start seine config.json angelegt hat
for _ in $(seq 1 240); do [[ -f "$HB_CFG" ]] && break; sleep 1; done
install -d "$HB_DIR/local-plugins"
rm -rf "$PLUGIN_DST"
cp -r "$PLUGIN_SRC" "$PLUGIN_DST"
chown -R homebridge:homebridge "$HB_DIR/local-plugins"
if [[ $HB_VIA_NPM -eq 1 ]]; then
  # Homebridge über npm -g installiert → Plugin ebenfalls global
  npm install -g --no-audit --no-fund "$PLUGIN_DST"
else
  # Homebridge aus dem apt-Paket → Plugins liegen in /var/lib/homebridge/node_modules
  sudo -u homebridge env PATH="/opt/homebridge/bin:$PATH" \
    /opt/homebridge/bin/npm --prefix "$HB_DIR" install --no-audit --no-fund "file:$PLUGIN_DST"
fi

step "LED-Stripe in Homebridge eintragen"
python3 - "$HB_CFG" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as fh:
    cfg = json.load(fh)
acc = cfg.setdefault("accessories", [])
if any(a.get("accessory") == "LedStripLocal" for a in acc):
    print("   Schon eingetragen.")
else:
    acc.append({"accessory": "LedStripLocal", "name": "LED Stripe",
                "url": "http://127.0.0.1:8765"})
    with open(path, "w") as fh:
        json.dump(cfg, fh, indent=4)
    print("   Eingetragen.")
PY
chown homebridge:homebridge "$HB_CFG"
systemctl restart homebridge

IP="$(hostname -I | awk '{print $1}')"
cat <<EOF

Fertig!
  * Homebridge-Oberfläche:  http://$IP:8581   (beim ersten Mal Benutzer anlegen)
  * Dort den QR-Code mit der Home-App auf dem iPhone scannen.
  * GPIO-Pins anpassen:     sudo nano /etc/ledstrip/config.json && sudo systemctl restart ledstrip
  * Test ohne iPhone:       curl -X POST -d '{"on":true,"hue":0,"saturation":100,"brightness":50}' http://127.0.0.1:8765/state
  * Logs:                   journalctl -u ledstrip -f

Optional gegen Abstürze / "Keine Antwort":  sudo ./scripts/stabilisieren.sh
EOF
