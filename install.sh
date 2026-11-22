#!/usr/bin/env bash
# Installiert den LED-Stripe-Dienst auf Raspberry Pi OS (Lite).
#
#   sudo ./install.sh               → direkt in Apple Home, OHNE Homebridge (empfohlen, v. a. Pi Zero W)
#   sudo ./install.sh --homebridge  → über Homebridge + Plugin (nur Pi mit ARMv7/ARMv8, z. B. Zero 2 W, Pi 3/4/5)
#
# Kann beliebig oft wiederholt werden (z. B. nach Updates). Einstellungen und Kopplung bleiben erhalten.
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Bitte mit sudo starten: sudo ./install.sh" >&2
  exit 1
fi

MODE=homekit
[[ "${1:-}" == "--homebridge" ]] && MODE=homebridge

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG=/etc/ledstrip/config.json
VENV=/opt/ledstrip/venv
step() { echo; echo "==> $*"; }

MODEL="$(tr -d '\0' </proc/device-tree/model 2>/dev/null || echo unbekannt)"
ARCH="$(uname -m)"
echo "Modell: $MODEL ($ARCH)   Modus: $MODE"
if [[ $MODE == homebridge && $ARCH == armv6l ]]; then
  echo "Homebridge läuft auf diesem Pi (ARMv6, z. B. Zero W) nicht offiziell." >&2
  echo "Nimm einfach:  sudo ./install.sh   (direktes HomeKit, ohne Homebridge)" >&2
  exit 1
fi

# ------------------------------------------------------------------------------------------
step "Systempakete installieren (dauert auf dem Pi Zero ein paar Minuten)"
apt-get update
apt-get install -y python3 python3-venv python3-pip curl
apt-get install -y python3-lgpio || apt-get install -y python3-rpi-lgpio || true
apt-get install -y avahi-daemon || true

# ------------------------------------------------------------------------------------------
step "Benutzer + Programm"
id ledstrip >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin ledstrip
getent group gpio >/dev/null || groupadd --system gpio
usermod -aG gpio ledstrip
install -d -m 755 /opt/ledstrip /etc/ledstrip
install -m 755 "$REPO/daemon/ledstripd.py" /opt/ledstrip/ledstripd.py
if [[ ! -f $CFG ]]; then
  install -m 644 "$REPO/daemon/config.example.json" "$CFG"
  echo "   Neue Konfiguration: $CFG  (GPIO-Pins dort prüfen!)"
else
  echo "   Bestehende $CFG bleibt erhalten."
fi

# Python-Umgebung (nutzt die Systempakete mit, z. B. lgpio)
[[ -x $VENV/bin/python ]] || python3 -m venv --system-site-packages "$VENV"

if [[ $MODE == homekit ]]; then
  step "HomeKit-Bibliothek (HAP-python) installieren"
  # Möglichst viel aus Debian nehmen → auf dem Pi Zero muss dann nichts kompiliert werden.
  for p in python3-cryptography python3-zeroconf python3-h11 python3-orjson python3-ifaddr; do
    apt-get install -y "$p" || echo "   ($p nicht verfügbar, kommt per pip)"
  done
  # Die Versionen aus Debian festhalten, damit pip sie nicht durch neue ersetzt
  # (neue cryptography/orjson müssten auf dem Zero W stundenlang kompiliert werden).
  CONSTRAINTS="$(mktemp)"
  python3 - >"$CONSTRAINTS" <<'PY'
import importlib.metadata as md
for name in ("cryptography", "zeroconf", "h11", "orjson", "ifaddr"):
    try:
        print(f"{name}=={md.version(name)}")
    except md.PackageNotFoundError:
        pass
PY
  echo "   Feste Versionen: $(tr '\n' ' ' <"$CONSTRAINTS")"
  if ! "$VENV/bin/pip" install --no-cache-dir -c "$CONSTRAINTS" HAP-python pyqrcode base36; then
    echo "   Erster Versuch fehlgeschlagen – installiere Compiler und versuche es nochmal …"
    apt-get install -y build-essential python3-dev libffi-dev
    "$VENV/bin/pip" install --no-cache-dir -c "$CONSTRAINTS" HAP-python pyqrcode base36
  fi
  rm -f "$CONSTRAINTS"

  # HomeKit in der Konfiguration einschalten (einmalig ein Kopplungscode, den HomeKit akzeptiert)
  python3 - "$CFG" <<'PY'
import json, random, sys
path = sys.argv[1]
cfg = json.load(open(path))
hk = cfg.setdefault("homekit", {})
hk["enabled"] = True
hk.setdefault("name", "LED Stripe")
if not hk.get("pincode"):
    bad = {"00000000", "11111111", "22222222", "33333333", "44444444", "55555555",
           "66666666", "77777777", "88888888", "99999999", "12345678", "87654321"}
    while True:
        d = "".join(random.choice("0123456789") for _ in range(8))
        if d not in bad:
            break
    hk["pincode"] = f"{d[:3]}-{d[3:5]}-{d[5:]}"
json.dump(cfg, open(path, "w"), indent=2)
print("   HomeKit-Code:", hk["pincode"])
PY
fi

# ------------------------------------------------------------------------------------------
step "Dienst starten"
install -m 644 "$REPO/systemd/ledstrip.service" /etc/systemd/system/ledstrip.service
systemctl daemon-reload
systemctl enable ledstrip
systemctl restart ledstrip
for _ in $(seq 1 30); do curl -fsS http://127.0.0.1:8765/health >/dev/null 2>&1 && break; sleep 1; done
if curl -fsS http://127.0.0.1:8765/health; then
  echo; echo "   ledstripd läuft."
else
  echo "   WARNUNG: ledstripd antwortet nicht. Log: journalctl -u ledstrip -n 50" >&2
fi

# ------------------------------------------------------------------------------------------
if [[ $MODE == homebridge ]]; then
  HB_DIR=/var/lib/homebridge
  HB_CFG="$HB_DIR/config.json"
  PLUGIN_DST="$HB_DIR/local-plugins/homebridge-ledstrip-local"

  step "Homebridge installieren"
  if ! command -v hb-service >/dev/null 2>&1; then
    apt-get install -y gpg
    curl -sSfL https://repo.homebridge.io/KEY.gpg | gpg --dearmor --yes -o /usr/share/keyrings/homebridge.gpg
    echo "deb [signed-by=/usr/share/keyrings/homebridge.gpg] https://repo.homebridge.io stable main" \
      > /etc/apt/sources.list.d/homebridge.list
    apt-get update
    apt-get install -y homebridge
  fi
  # HomeKit direkt ausschalten, sonst gäbe es den Stripe zweimal
  python3 - "$CFG" <<'PY'
import json, sys
p = sys.argv[1]; c = json.load(open(p))
c.setdefault("homekit", {})["enabled"] = False
json.dump(c, open(p, "w"), indent=2)
PY
  systemctl restart ledstrip

  step "Homebridge-Plugin installieren"
  for _ in $(seq 1 240); do [[ -f "$HB_CFG" ]] && break; sleep 1; done
  install -d "$HB_DIR/local-plugins"
  rm -rf "$PLUGIN_DST"
  cp -r "$REPO/homebridge-ledstrip-local" "$PLUGIN_DST"
  chown -R homebridge:homebridge "$HB_DIR/local-plugins"
  sudo -u homebridge env PATH="/opt/homebridge/bin:$PATH" \
    /opt/homebridge/bin/npm --prefix "$HB_DIR" install --no-audit --no-fund "file:$PLUGIN_DST"
  python3 - "$HB_CFG" <<'PY'
import json, sys
path = sys.argv[1]
cfg = json.load(open(path))
acc = cfg.setdefault("accessories", [])
if not any(a.get("accessory") == "LedStripLocal" for a in acc):
    acc.append({"accessory": "LedStripLocal", "name": "LED Stripe", "url": "http://127.0.0.1:8765"})
cfg.setdefault("bridge", {})["advertiser"] = "avahi"
json.dump(cfg, open(path, "w"), indent=4)
PY
  chown homebridge:homebridge "$HB_CFG"
  systemctl restart homebridge
fi

# ------------------------------------------------------------------------------------------
IP="$(hostname -I | awk '{print $1}')"
echo
echo "================================================================"
echo " Fertig!"
echo "================================================================"
echo " Test (sollte ROT leuchten):"
echo "   curl -X POST -d '{\"on\":true,\"hue\":0,\"saturation\":100,\"brightness\":30}' http://127.0.0.1:8765/state"
echo " Pins ändern:  sudo nano $CFG  &&  sudo systemctl restart ledstrip"
echo " Log:          journalctl -u ledstrip -f"
echo
if [[ $MODE == homekit ]]; then
  echo " Mit Apple Home koppeln:  Home-App → + → Gerät hinzufügen → QR-Code scannen"
  echo " (QR-Code + Code jederzeit anzeigen:  sudo cat /var/lib/ledstrip/pairing.txt)"
  echo
  sleep 2
  cat /var/lib/ledstrip/pairing.txt 2>/dev/null || echo " (pairing.txt noch nicht da – in ein paar Sekunden nochmal mit dem Befehl oben)"
else
  echo " Homebridge-Oberfläche: http://$IP:8581  → dort den QR-Code mit der Home-App scannen"
fi
echo
echo " Gegen Abstürze / 'Keine Antwort':  sudo ./scripts/stabilisieren.sh  und danach  sudo reboot"
