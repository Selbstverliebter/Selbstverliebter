# Ersteinrichtung ohne Bildschirm (nur per SSH)

Für den **Raspberry Pi Zero W (v1.1)**. Andere Modelle gehen genauso.
Du brauchst nur einen Computer mit SD-Kartenleser und dasselbe WLAN, keinen Monitor und keine Tastatur.

## Wie es funktioniert

Der Pi Zero W ist zu schwach für Homebridge. Deshalb meldet sich der Pi hier **selbst als HomeKit-Gerät** bei Apple Home an.
Es gibt **kein Homebridge** und kein Node.js, nur ein kleines Python-Programm. Das braucht ca. 40 MB RAM statt 200+ MB
und ist deutlich stabiler.

```
iPhone (Home-App) ──HomeKit (WLAN)──▶ Pi Zero W: ledstripd ──PWM──▶ MOSFETs ──▶ LED-Stripe
```

## 1. Betriebssystem

Im Imager **„Raspberry Pi OS Lite (32-bit)“** wählen, unter „Raspberry Pi OS (other)“.
⚠️ Nicht die 64-bit-Version, die läuft auf dem Zero W nicht.

## 2. SD-Karte beschreiben (am Computer)

1. **Raspberry Pi Imager** installieren: https://www.raspberrypi.com/software/
2. Als Gerät **„Raspberry Pi Zero“** wählen, als Betriebssystem **Raspberry Pi OS Lite (32-bit)**, dann die SD-Karte.
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
```

Das dauert auf dem Zero W **10–30 Minuten**. Lass das SSH-Fenster offen, bis „Fertig!“ erscheint.
Wenn die Verbindung abbricht, verbindest du dich neu und startest `sudo ./install.sh` einfach nochmal.
Das Skript kann man beliebig oft ausführen.

Danach die Maßnahmen gegen Abstürze aktivieren und neu starten:

```bash
sudo ./scripts/stabilisieren.sh
sudo reboot
```

## 6. Farben testen

Etwa eine Minute warten, dann wieder einloggen (`ssh pi@ledstrip.local`) und Folgendes eingeben:

```bash
curl -X POST -d '{"on":true,"hue":0,"saturation":100,"brightness":30}' http://127.0.0.1:8765/state
```

→ Der Stripe sollte **rot** leuchten. Wenn eine andere Farbe kommt, passt du die Pins an:

```bash
sudo nano /etc/ledstrip/config.json      # bei "pins" die Nummern tauschen; speichern: Strg+O, Enter, Strg+X
sudo systemctl restart ledstrip
```

## 7. Mit Apple Home koppeln

```bash
sudo cat /var/lib/ledstrip/pairing.txt
```

Das zeigt einen **QR-Code** und einen **8-stelligen Code** (z. B. `924-50-261`) direkt im SSH-Fenster.
Mach das Terminal-Fenster groß genug, sonst wird der QR-Code zerschnitten.

In der **Home-App**: „+“ → „Gerät hinzufügen“ → QR-Code scannen.
Oder: „Weitere Optionen …“ → „LED Stripe“ antippen → den 8-stelligen Code eingeben.
Die Meldung „Nicht zertifiziertes Gerät“ bestätigst du mit „Trotzdem hinzufügen“. Fertig. 🎉

**Neu koppeln** (z. B. wenn du den Stripe in der Home-App gelöscht hast):

```bash
sudo systemctl stop ledstrip
sudo rm /var/lib/ledstrip/homekit.state
sudo systemctl start ledstrip
sudo cat /var/lib/ledstrip/pairing.txt
```

## Hinweise zum Pi Zero

- **Strom:** Der Zero W braucht 5 V mit mindestens 1,2 A. Wenn er aus dem LED-Netzteil versorgt wird,
  brauchst du einen ordentlichen Step-down-Wandler (5 V, ≥ 2 A). Unterspannung ist die Absturzursache Nr. 1.
  Prüfen mit: `vcgencmd get_throttled` (`0x0` = alles gut).
- **RAM:** Der Zero W hat nur 512 MB. Mit Homebridge war das knapp, und der Kernel beendet Programme, wenn der Speicher voll ist.
  Das passt zu deinem alten Problem, dass das Gerät „nicht erreichbar“ war. Ohne Homebridge ist mehr als genug Speicher frei.
- **Feste IP:** Stell im Router ein, dass der Pi immer dieselbe IP bekommt. Das macht HomeKit zuverlässiger.
- **Kein „Keine Antwort“ mehr nach Neustarts:** Der Dienst wartet beim Booten, bis das WLAN da ist, bevor er sich bei
  HomeKit meldet. Nach einem Absturz startet er sich selbst neu.
- **Homebridge trotzdem?** Auf einem stärkeren Pi (Zero 2 W, Pi 3/4/5) geht auch `sudo ./install.sh --homebridge`.
