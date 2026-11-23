# Homebridge auf dem Raspberry Pi 4 (für Dreo & Co.)

So ist die Aufteilung gedacht:

```
                       ┌──▶ ESP32  ──▶ LED-Stripe          (HomeKit direkt, kein Pi nötig)
iPhone (Home-App) ─────┤
                       └──▶ Pi 4: Homebridge ──▶ Dreo-Cloud ──▶ Dreo-Lüfter
```

Wenn der Pi 4 mal aus ist, geht der LED-Stripe trotzdem. Homebridge braucht nur wenig Leistung,
der Pi 4 kann nebenbei also weiter andere Aufgaben übernehmen.

## Pi 4 einrichten (falls noch nicht geschehen)

Das geht genauso wie in [ERSTEINRICHTUNG.md](ERSTEINRICHTUNG.md), mit diesen Unterschieden:
- Im Imager als Gerät **Raspberry Pi 4** wählen und als System **Raspberry Pi OS Lite (64-bit)**.
- Hostname z. B. `homebridge`. Dann verbindest du dich mit `ssh pi@homebridge.local`.
- Der Pi 4 kann auch 5-GHz-WLAN. Noch besser ist ein **LAN-Kabel**.

Läuft auf deinem Pi 4 schon etwas anderes, ist das kein Problem. Das Skript installiert nur Homebridge dazu.

## Homebridge + Dreo installieren

Projekt auf den Pi kopieren (siehe ERSTEINRICHTUNG.md, Schritt 4) und dann:

```bash
cd ledstrip
sudo ./scripts/homebridge-pi4.sh
sudo ./scripts/stabilisieren.sh
sudo reboot
```

Danach:
1. Im Browser **http://homebridge.local:8581** öffnen und einen Benutzer anlegen.
2. **Plugins** → **Homebridge Dreo** → Zahnrad → **E-Mail und Passwort deines Dreo-Kontos** eintragen → speichern → Homebridge neu starten.
   - Hast du dich bei Dreo mit Apple oder Google angemeldet, gibt es eventuell kein Passwort. Dann leg in der Dreo-App eines fest,
     oder erstell ein Konto mit E-Mail und teile den Lüfter damit.
3. Home-App → **+** → **Gerät hinzufügen** → den **QR-Code** von der Homebridge-Startseite scannen.
   Der Dreo-Lüfter erscheint dann als Ventilator, mit An/Aus und Geschwindigkeit, je nach Modell auch mit Schwenken.

## Gut zu wissen

- Das Dreo-Plugin ist ein Community-Projekt und läuft **über die Dreo-Cloud**. Ohne Internet geht der Lüfter also nicht
  über HomeKit, und wenn Dreo seine Server ändert, kann es eine Weile haken, bis das Plugin angepasst ist.
- Auf der Homebridge-Oberfläche findest du unter **Plugins** viele weitere Geräte, zum Beispiel Ring, Roborock oder Tuya-Steckdosen.
  Neue Plugins installierst du mit einem Klick, ganz ohne SSH.
- Updates für Homebridge bekommst du ganz normal mit `sudo apt update && sudo apt upgrade`.
- Der **Taster am ESP32** kann per Doppelklick auch den Dreo-Lüfter schalten.
  Dafür in der Home-App beim Taster „Zweimal drücken“ mit dem Lüfter belegen.
