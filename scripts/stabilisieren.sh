#!/usr/bin/env bash
# Maßnahmen gegen die typischen Ursachen für "Pi hängt / Gerät nicht erreichbar".
# Aufruf: sudo ./scripts/stabilisieren.sh      (danach einmal neu starten)
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Bitte mit sudo starten." >&2; exit 1; }

echo "==> 1) Stromversorgung prüfen (häufigste Absturzursache!)"
if command -v vcgencmd >/dev/null; then
  T=$(vcgencmd get_throttled | cut -d= -f2)
  echo "   get_throttled = $T"
  if (( T & 0x1 ));     then echo "   !!! JETZT Unterspannung – Netzteil ist zu schwach / Kabel zu dünn"; fi
  if (( T & 0x10000 )); then echo "   !!! Seit dem Start gab es Unterspannung – Netzteil ist zu schwach / Kabel zu dünn"; fi
  if (( T == 0 ));      then echo "   OK, keine Unterspannung seit dem Start."; fi
else
  echo "   vcgencmd nicht gefunden, übersprungen."
fi

echo "==> 2) WLAN-Stromsparmodus aus (sonst ist der Pi nach einer Weile 'nicht erreichbar')"
if [[ -d /etc/NetworkManager/conf.d ]]; then
  printf '[connection]\nwifi.powersave = 2\n' > /etc/NetworkManager/conf.d/wifi-powersave-off.conf
  echo "   NetworkManager: wifi.powersave = 2 (aus)"
else
  echo "   Kein NetworkManager gefunden – ggf. 'iw wlan0 set power_save off' in rc.local."
fi

echo "==> 3) Hardware-Watchdog an (Pi startet sich selbst neu, wenn er komplett hängt)"
mkdir -p /etc/systemd/system.conf.d
printf '[Manager]\nRuntimeWatchdogSec=15\nRebootWatchdogSec=2min\n' > /etc/systemd/system.conf.d/watchdog.conf
echo "   RuntimeWatchdogSec=15"

echo "==> 4) Logs begrenzen + nach Neustart behalten (damit man Abstürze nachlesen kann)"
mkdir -p /etc/systemd/journald.conf.d /var/log/journal
printf '[Journal]\nStorage=persistent\nSystemMaxUse=50M\n' > /etc/systemd/journald.conf.d/size.conf

echo "==> 5) Mehr Swap bei wenig RAM (Pi Zero hat nur 512 MB – sonst killt der Kernel Homebridge)"
MEM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
echo "   RAM: ${MEM_MB} MB"
if (( MEM_MB < 1024 )) && [[ -f /etc/dphys-swapfile ]]; then
  sed -i 's/^#\?CONF_SWAPSIZE=.*/CONF_SWAPSIZE=512/' /etc/dphys-swapfile
  systemctl restart dphys-swapfile && echo "   Swap auf 512 MB gesetzt."
elif (( MEM_MB < 1024 )); then
  echo "   (System nutzt kein dphys-swapfile – aktuellen Swap ansehen mit: free -m)"
fi

echo "==> 6) Homebridge: avahi als mDNS-Advertiser (stabiler unter Linux)"
apt-get install -y avahi-daemon >/dev/null
CFG=/var/lib/homebridge/config.json
if [[ -f $CFG ]]; then
  python3 - "$CFG" <<'PY'
import json, sys
p = sys.argv[1]
c = json.load(open(p))
c.setdefault("bridge", {})["advertiser"] = "avahi"
json.dump(c, open(p, "w"), indent=4)
PY
  chown homebridge:homebridge "$CFG"
  systemctl restart homebridge
fi

echo
echo "Fertig. Bitte einmal neu starten:  sudo reboot"
echo "Nach einem Absturz die Ursache ansehen:  journalctl -b -1 -e"
