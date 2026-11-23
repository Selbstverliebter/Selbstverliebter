#!/usr/bin/env bash
# Installiert nur Homebridge (mit Weboberfläche) auf einem Raspberry Pi 4/5 und optional das Dreo-Plugin.
# Der LED-Stripe läuft separat auf dem ESP32 und braucht Homebridge NICHT.
#
# Aufruf:  sudo ./scripts/homebridge-pi4.sh
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Bitte mit sudo starten." >&2; exit 1; }

echo "==> Homebridge-Paketquelle einrichten"
apt-get update
apt-get install -y curl gpg
curl -sSfL https://repo.homebridge.io/KEY.gpg | gpg --dearmor --yes -o /usr/share/keyrings/homebridge.gpg
echo "deb [signed-by=/usr/share/keyrings/homebridge.gpg] https://repo.homebridge.io stable main" \
  > /etc/apt/sources.list.d/homebridge.list
apt-get update

echo "==> Homebridge installieren (mit Weboberfläche auf Port 8581)"
apt-get install -y homebridge avahi-daemon

echo "==> Warten, bis Homebridge zum ersten Mal gestartet ist"
for _ in $(seq 1 120); do [[ -f /var/lib/homebridge/config.json ]] && break; sleep 1; done

echo "==> avahi als mDNS-Advertiser (stabiler unter Linux)"
python3 - /var/lib/homebridge/config.json <<'PY'
import json, sys
p = sys.argv[1]
c = json.load(open(p))
c.setdefault("bridge", {})["advertiser"] = "avahi"
json.dump(c, open(p, "w"), indent=4)
PY
chown homebridge:homebridge /var/lib/homebridge/config.json
systemctl restart homebridge

echo "==> Dreo-Plugin installieren"
hb-service add homebridge-dreo || echo "   (Bitte stattdessen in der Weboberfläche unter 'Plugins' nach 'Dreo' suchen.)"

IP="$(hostname -I | awk '{print $1}')"
cat <<EOF

Fertig!
  1. Im Browser öffnen:   http://$IP:8581   (oder http://$(hostname).local:8581)
     → beim ersten Mal Benutzer + Passwort anlegen
  2. Plugins → "Homebridge Dreo" → Einstellungen (Zahnrad):
     E-Mail + Passwort deines Dreo-Kontos eintragen → Speichern → Homebridge neu starten
  3. Home-App → + → Gerät hinzufügen → den QR-Code von der Homebridge-Startseite scannen

Empfohlen gegen Abstürze / "Keine Antwort":  sudo ./scripts/stabilisieren.sh  und danach  sudo reboot
EOF
