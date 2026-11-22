# Ersteinrichtung ohne Bildschirm (nur per SSH)

Diese Anleitung ist für einen **Raspberry Pi Zero 2 W** oder **Zero W**. Du brauchst keinen Monitor und keine Tastatur,
nur einen Computer mit SD-Kartenleser und dasselbe WLAN.

## 1. Welcher Zero ist es?

Schau auf den großen Chip in der Mitte der Platine:

| Aufdruck auf dem Chip / der Platine | Modell | Betriebssystem im Imager |
|---|---|---|
| **RP3A0**, Platine sagt „Zero 2 W“ | Pi Zero 2 W (schneller, 4 Kerne) | **Raspberry Pi OS Lite (64-bit)** |
| **BCM2835** | Pi Zero W (alt, 1 Kern) | **Raspberry Pi OS Lite (32-bit)** |

Wenn du dir unsicher bist: Nimm **Lite (32-bit)**. Das läuft auf beiden.
Später kannst du per SSH nachsehen, welches Modell es ist: `cat /proc/device-tree/model`

## 2. SD-Karte beschreiben (am Computer)

1. **Raspberry Pi Imager** installieren: https://www.raspberrypi.com/software/
2. Als Gerät „Raspberry Pi Zero 2 W“ bzw. „Raspberry Pi Zero“ wählen, dann das Betriebssystem aus der Tabelle oben.
   Das findest du unter „Raspberry Pi OS (other)“. Danach die SD-Karte auswählen.
3. Bei **„Einstellungen bearbeiten“ / „Anpassen“** Folgendes eintragen. Das ist der wichtigste Schritt:
   - **Hostname:** `ledstrip`
   - **Benutzername + Passwort:** z. B. `pi` und ein eigenes Passwort
   - **WLAN:** Name (SSID) und Passwort, **Land: DE**.
     ⚠️ Der Zero kann nur **2,4 GHz**-WLAN, kein 5 GHz. Bei der Fritzbox ist das meistens dasselbe WLAN, dann ist alles gut.
   - **Zeitzone:** Europe/Berlin
   - **Dienste → SSH aktivieren** mit Passwort-Authentifizierung
4. Schreiben, Karte in den Pi stecken und Strom anschließen. Den Pi **an der Buchse „PWR“** anschließen, nicht an „USB“.
5. **2–5 Minuten warten.** Der erste Start dauert beim Zero lange.

## 3. Per SSH verbinden

Am Mac im Terminal, unter Windows in der PowerShell:

```bash
ssh pi@ledstrip.local
```

Falls `ledstrip.local` nicht gefunden wird, such im Router (z. B. fritz.box → Heimnetz) nach dem Gerät
„ledstrip“ und nimm dessen IP: `ssh pi@192.168.178.xx`.
Tipp: Stell im Router ein, dass der Pi **immer dieselbe IP** bekommt.

## 4. Dateien auf den Pi bringen

**Variante A, über GitHub** (falls das Repo dort liegt):

```bash
sudo apt update && sudo apt install -y git
git clone https://github.com/Selbstverliebter/Selbstverliebter.git ledstrip
cd ledstrip
```

**Variante B, ohne GitHub:** Lade `ledstrip.tar.gz` auf deinen Computer und kopiere die Datei von dort auf den Pi.
Das machst du **am Computer**, nicht im SSH-Fenster:

```bash
scp ~/Downloads/ledstrip.tar.gz pi@ledstrip.local:
```

Danach wieder **auf dem Pi** (im SSH-Fenster):

```bash
tar xzf ledstrip.tar.gz
cd ledstrip
```

## 5. Installieren

```bash
sudo ./install.sh
sudo ./scripts/stabilisieren.sh
sudo reboot
```

Der Zero braucht dafür **15–40 Minuten**. Lass das SSH-Fenster offen, bis „Fertig!“ erscheint.
Wenn die Verbindung abbricht, verbindest du dich neu und startest `sudo ./install.sh` einfach nochmal. Das Skript kann man beliebig oft ausführen.

## 6. Testen und koppeln

Nach dem Neustart wieder einloggen (`ssh pi@ledstrip.local`) und dann:

```bash
cd ledstrip
curl -X POST -d '{"on":true,"hue":0,"saturation":100,"brightness":30}' http://127.0.0.1:8765/state
```

→ Der Stripe sollte **rot** leuchten. Wenn eine andere Farbe kommt, passt du die Pins an (siehe README):

```bash
sudo nano /etc/ledstrip/config.json      # speichern: Strg+O, Enter, Strg+X
sudo systemctl restart ledstrip
```

Danach am iPhone oder Computer im Browser **http://ledstrip.local:8581** öffnen. Beim ersten Mal legst du einen Benutzer an.
Dann in der **Home-App** auf „+“ → „Gerät hinzufügen“ tippen und den QR-Code von der Homebridge-Seite scannen. Fertig. 🎉

## Hinweise zum Pi Zero

- **Strom:** Der Zero braucht 5 V mit mindestens 1,2 A (Zero 2 W: besser 2,5 A). Wenn er aus dem LED-Netzteil versorgt wird,
  brauchst du einen ordentlichen Step-down-Wandler (5 V, ≥ 2 A). Unterspannung ist die Absturzursache Nr. 1.
  Prüfen mit: `vcgencmd get_throttled` (`0x0` = alles gut).
- **RAM:** Der Zero hat nur 512 MB. `stabilisieren.sh` vergrößert deshalb den Swap. Ohne das kann der Kernel
  Homebridge einfach beenden. Das passt auch zu deinem alten Problem, dass das Gerät „nicht erreichbar“ war.
- **Zero W (alt):** Homebridge läuft dort nur inoffiziell und ist langsam. Das Installationsskript macht das automatisch.
  Wenn du die Wahl hast, nimm einen Zero 2 W.
