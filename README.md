# LED-Stripe am Raspberry Pi → Apple Home

> **Neu: Variante mit ESP32**, ganz ohne Raspberry Pi: [ESP32.md](ESP32.md). Das ist die empfohlene Variante:
> günstiger, startet in Sekunden und hat keine SD-Karte. Darunter folgt die Raspberry-Pi-Variante.

RGB-LED-Stripe, über 3 MOSFETs an GPIOs des Raspberry Pi, in Apple Home.
Standardmäßig meldet sich der Pi **direkt als HomeKit-Gerät** an (HAP-python), ganz ohne Homebridge. Das ist ideal für den Pi Zero W.
Optional geht es auch über Homebridge: `sudo ./install.sh --homebridge`.
Die Hardware ist dieselbe wie in der Anleitung von dordnung.de. Neu ist die Software:

| Problem vorher | Lösung jetzt |
|---|---|
| Homebridge zu schwer für den Pi Zero W (512 MB, ARMv6) | HomeKit direkt in einem kleinen Python-Programm, ca. 40 MB RAM |
| Beim Einschalten immer **weiß / 100 %** | „An“ schaltet nur an, Farbe und Helligkeit bleiben. Der Zustand wird auf der SD-Karte gespeichert und übersteht auch Neustarts. |
| Programm stürzt ab, danach nicht mehr steuerbar | `ledstripd` läuft als systemd-Dienst und startet nach einem Absturz sofort neu (`Restart=always`). Das Plugin wiederholt Befehle, wenn der Dienst kurz weg war. |
| Pi stürzt ab / ist „nicht erreichbar“ | `scripts/stabilisieren.sh`: prüft das Netzteil, schaltet den WLAN-Stromsparmodus aus, aktiviert den Hardware-Watchdog und stellt Homebridge auf avahi um |

## Aufbau

```
Standard (Pi Zero W):
iPhone (Home-App) ──HomeKit──▶ ledstripd (Python, systemd, HAP-python) ──PWM──▶ MOSFETs ──▶ LED-Stripe

Optional (--homebridge, stärkere Pis):
iPhone ──▶ Homebridge ──▶ Plugin homebridge-ledstrip-local ──HTTP 127.0.0.1:8765──▶ ledstripd ──▶ …
```

## Installation auf frischem Pi

👉 **Schritt für Schritt, nur per SSH und ohne Bildschirm: [ERSTEINRICHTUNG.md](ERSTEINRICHTUNG.md)** (für Pi Zero W / Zero 2 W)

Kurzfassung, wenn du schon per SSH eingeloggt bist:

```bash
cd ledstrip
sudo ./install.sh                  # direkt HomeKit (Standard)
sudo ./scripts/stabilisieren.sh
sudo reboot
sudo cat /var/lib/ledstrip/pairing.txt   # QR-Code zum Koppeln
```

## GPIO-Pins einstellen

Voreingestellt sind die Pins aus der dordnung.de-Anleitung: **Rot = GPIO 17, Grün = GPIO 22, Blau = GPIO 24**.
Das sind **BCM-Nummern**, nicht die Nummern auf der Stiftleiste. In physischen Pins entspricht das 11, 15 und 18.

```bash
sudo nano /etc/ledstrip/config.json
sudo systemctl restart ledstrip
```

Testen, ohne das iPhone zu benutzen:

```bash
curl -X POST -d '{"on":true,"hue":0,"saturation":100,"brightness":30}'   http://127.0.0.1:8765/state  # rot
curl -X POST -d '{"on":true,"hue":120,"saturation":100,"brightness":30}' http://127.0.0.1:8765/state  # grün
curl -X POST -d '{"on":true,"hue":240,"saturation":100,"brightness":30}' http://127.0.0.1:8765/state  # blau
curl -X POST -d '{"on":false}' http://127.0.0.1:8765/state
```

Wenn bei „rot“ eine andere Farbe leuchtet, tauschst du einfach die Pins in der Konfiguration.

**Pins herausfinden**: Im Terminal `pinout` eingeben, das zeigt die Stiftleiste. Dann von jedem MOSFET-Gate die
Leiterbahn bis zum Pi verfolgen.

## Weitere Einstellungen (`/etc/ledstrip/config.json`)

| Schlüssel | Bedeutung |
|---|---|
| `power_on_behavior` | Nach Stromausfall/Neustart: `"last"` (wie vorher), `"off"` (aus, aber Farbe gemerkt) oder `"on"` |
| `fade_ms` | Weiches Überblenden in Millisekunden, `0` = sofort |
| `gamma` | Helligkeitskurve. `2.0` sorgt dafür, dass niedrige Helligkeiten fein regelbar sind |
| `pwm_frequency` | PWM-Frequenz in Hz. Wenn es auf Handyvideos flackert, ausprobieren: 400, 800 oder 1000 |
| `channel_scale` | Farbkorrektur, z. B. `"blue": 0.8`, wenn Weiß zu bläulich wirkt |
| `homekit.enabled` | `true` = direkt in Apple Home (setzt `install.sh` automatisch) |
| `homekit.pincode` | Kopplungscode, den `install.sh` einmalig zufällig erzeugt |
| `backend` | `"auto"` nimmt pigpio (Pi 0–4, falls installiert), sonst lgpio (alle Pis inkl. Pi 5) |

## Fehlersuche

```bash
journalctl -u ledstrip -f          # Log des LED-Dienstes
journalctl -u homebridge -f        # Log von Homebridge
curl http://127.0.0.1:8765/health  # läuft der Dienst?
vcgencmd get_throttled             # 0x0 = Stromversorgung ok
journalctl -b -1 -e                # was war vor dem letzten Absturz?
```

**Häufigste Ursache für Abstürze: die Stromversorgung.**
- Nimm das offizielle Netzteil: 5,1 V / 3 A beim Pi 4, 5 V / 5 A beim Pi 5.
- Den Pi **nicht** über einen Spannungswandler aus dem 12-V-Netzteil des LED-Stripes versorgen, wenn der nicht genug Leistung hat.
- Die Masse (GND) von Pi und LED-Netzteil muss verbunden sein, sonst schalten die MOSFETs unsauber.
- Billige SD-Karten gehen durch viele Schreibvorgänge kaputt. Nimm eine Markenkarte (A1/A2).

## Dateien

- `daemon/ledstripd.py`: der LED-Dienst (nur Python-Standardbibliothek + lgpio/pigpio)
- `daemon/config.example.json`: Vorlage für `/etc/ledstrip/config.json`
- `homebridge-ledstrip-local/`: Homebridge-Plugin ohne Abhängigkeiten (nur für `--homebridge`)
- `systemd/ledstrip.service`: systemd-Dienst
- `esp32/LedStripHomeKit/`: ESP32-Firmware (Arduino + HomeSpan)
- `install.sh`: installiert alles (Pi)
- `scripts/stabilisieren.sh`: Maßnahmen gegen Abstürze und Verbindungsabbrüche
