# Projekt: Smart Home DIY – LED-Stripe & mehr in Apple Home

Stand: 24.11.2026. Diese Datei fasst den bisherigen Chat zusammen und ist als **Projektwissen für ein Claude-Projekt** gedacht.

---

## 1. Ziel

Einen **RGB-LED-Stripe** (12 V, über 3 MOSFETs geschaltet) per **Apple Home / iPhone** steuern:
Farbe, Helligkeit, An/Aus, Siri und Automationen. Das Ganze soll **stabil** laufen.

### Probleme der alten Lösung
Die alte Lösung bestand aus einem Raspberry Pi mit `pigpio` und Homebridge-Plugin, nach der Anleitung von dordnung.de.
- Beim Einschalten war der Stripe **immer weiß mit 100 %**. Die letzte Einstellung ging verloren.
- Der Pi ist **immer wieder abgestürzt**. Danach war der Stripe „nicht erreichbar“.

---

## 2. Hardware

| Teil | Details |
|---|---|
| **MOSFET-Lötplatine** | selbst gelötet, 3 MOSFETs (R/G/B), mit **Buchsenleiste für die 40-Pin-GPIO-Leiste des Pi**. Die Pins sind fest verlötet. |
| **ESP32** (aktuell im Einsatz) | NodeMCU / DevKit, Chip **ESP32-D0WD-V3** (Rev 3.1), 4 MB Flash, USB-Chip **CP2102** |
| Raspberry Pi Zero W **v1.1** | ARMv6, 512 MB RAM. Zu schwach für Homebridge. Reserve. |
| Raspberry Pi 4 | geplant für **Homebridge** (Dreo-Lüfter), läuft nebenbei für anderes |
| Dreo-Lüfter | nur per Dreo-App steuerbar → soll über Homebridge auf dem Pi 4 in HomeKit |
| Computer | Windows 10/11, Arduino IDE 2.x |

---

## 3. Entscheidungen (chronologisch)

1. **Pi + neue Software** (`ledstripd` in Python + eigenes Homebridge-Plugin).
   Merkt sich den Zustand und startet nach Abstürzen automatisch neu.
2. **Pi Zero W:** Homebridge ist dafür zu schwer. Deshalb spricht der Pi **direkt HomeKit** über HAP-python, ganz ohne Homebridge.
3. **ESP32 statt Pi.** Das ist die **aktuelle Hauptlösung.** Mit **HomeSpan** spricht der ESP32 selbst HomeKit.
   Es braucht keinen Pi, kein Homebridge und keine SD-Karte. Der Zustand liegt im Flash (NVS).
4. **Pi 4 nur für Homebridge**, für Geräte ohne HomeKit, z. B. den Dreo-Lüfter über das Plugin `homebridge-dreo`.
   Der LED-Stripe bleibt davon unabhängig auf dem ESP32.

---

## 4. Aktueller Stand ESP32 (Hauptprojekt)

### Software-Umgebung
- Arduino IDE 2.x, Board-Paket **esp32 von Espressif 3.3.12** (ESP-IDF 5.5.5)
- Bibliothek **HomeSpan 2.1.8**
- Treiber: **Silicon Labs CP210x** installiert → Board auf **COM3**
- Board-Einstellung: **ESP32 Dev Module**
- **Partition Scheme: „Minimal SPIFFS (1.9MB APP with OTA/128KB SPIFFS)“**. Pflicht, sonst kommt „Sketch too big“, weil der Sketch ~1,43 MB groß ist.

### Firmware `esp32/LedStripHomeKit/LedStripHomeKit.ino`
- HomeKit-Gerät „LED Stripe“ (Lightbulb: On, Hue, Saturation, Brightness)
- **Zustand wird im Flash gespeichert** (`Characteristic(..., true)`) und nach Stromausfall wiederhergestellt
- „An“ schaltet nur an, die Farbe bleibt (behebt das alte „immer weiß“)
- weiches Überblenden (400 ms), Gamma 2.0, PWM 1 kHz / 14 Bit über **`ledcAttach`/`ledcWrite`** (nicht HomeSpans `LedPin`)
- **Taster** an GPIO 33 → GND als „programmierbarer Schalter“: 1× = Stripe an/aus (lokal), 2× und lang = in der Home-App frei belegbar
- **OTA-Updates per WLAN**: In der Arduino IDE den Port „LED-Stripe“ wählen, Passwort `ledstrip`
- HomeSpan-Watchdog 30 s, Log-Level 1, Diagnose-Schalter `DEBUG_STEPS` (0/1)
- WLAN-Daten in **`secrets.h`** im Sketch-Ordner. Die Datei ist nicht im Git. Ohne sie öffnet der ESP32 das Setup-WLAN „LED-Stripe-Setup“ mit dem Passwort `homespan`.

### Pin-Belegung (aktuell)
| Funktion | ESP32-GPIO | Board-Beschriftung | Loch in der Buchsenleiste der Platine |
|---|---|---|---|
| Rot | **GPIO 4** | D4 | 11 |
| Grün | **GPIO 22** | D22 | 15 |
| Blau | **GPIO 17** | oft **TX2** | 18 |
| Masse | GND | GND | 6 |
| Taster | GPIO 33 → Taster → GND | D33 | – |

Strom für den ESP32: USB-Netzteil **oder** Loch 2 (5 V) der Platine → VIN, aber nur, wenn dort ~5 V gemessen wurden. Nie beides gleichzeitig.
Welche Löcher die Platine tatsächlich nutzt, ist nicht sicher. 11, 15 und 18 kommen aus der dordnung.de-Anleitung (GPIO 17, 22 und 24 am Pi).

### HomeKit
- Kopplungscode: **384-61-927**
- Gekoppelt über Home-App → + → Gerät hinzufügen → Weitere Optionen → „LED Stripe“
- IP im Test: 192.168.178.68, Hostname `LED-Stripe.local`, WLAN-Signal −65 dBm

### Flashen
- Download-Modus: **BOOT halten, EN kurz drücken, BOOT loslassen**, dann hochladen. Nach dem Upload einmal **EN** drücken.
- Dauerhafte Lösung: einen **10-µF-Elko zwischen EN (+) und GND (−)** einbauen, oder gleich per **OTA** flashen.
- Serieller Monitor: **115200 Baud, „New Line“**. HomeSpan-Befehle: `?` Hilfe, `W` WLAN, `U` Kopplung löschen, `E` alles löschen.

---

## 5. Gelöste Probleme (Lessons Learned)

| Problem | Ursache | Lösung |
|---|---|---|
| Board rot blinkend, „Could not connect to COM1“ | CP2102-Treiber fehlte | Silicon-Labs-Treiber installiert → COM3 |
| „Wrong boot mode detected (0x13)“ | Auto-Reset-Schaltung des Boards ist zu langsam | BOOT/EN-Trick, 10-µF-Elko an EN oder OTA |
| „Sketch too big“ (109 %) | Standard-Partition hat nur 1,2 MB | Partition „Minimal SPIFFS (1.9MB APP with OTA)“ |
| `���` im Seriellen Monitor | falsche Baudrate | 115200 Baud |
| **Bootloop** „Interrupt watchdog“ / `TG1WDT_SYS_RESET` | **GPIO 10 als Rot-Pin.** GPIO 6–11 hängen am Flash-Chip. | Rot auf **GPIO 4** gelegt. **GPIO 6–11 nie benutzen!** |
| Pairing-Code wurde nicht gespeichert | `setPairingCode()` stand vor `homeSpan.begin()` | Aufruf nach `begin()` verschoben |

**Pin-Regeln ESP32 (DevKit):** Gut nutzbar sind 4, 13, 16–19, 21–23, 25–27 und 32–33.
Meiden: 0, 2, 12, 15 (Boot-Pins), 6–11 (Flash), 34–39 (nur Eingang).

---

## 6. Offene Punkte / nächste Schritte

1. **AKTUELL OFFEN:** Nach dem Umzug vom PC-USB auf ein Netzteil an anderem Ort und dem Anschluss des Stripes zeigt die Home-App **„Keine Antwort“**.
   Mögliche Ursachen:
   - falsche Pins gesteckt (Boot- oder Flash-Pin, 5 V auf einem GPIO)
   - zu schwaches Netzteil (Brownout)
   - schwaches WLAN am neuen Ort
   - fehlende GND-Verbindung

   Nächster Schritt: Verkabelung nach der Tabelle oben prüfen. Wenn es dann noch hakt, den ESP32 mit angeschlossener Platine per USB an den PC hängen und den Seriellen Monitor auslesen. Ein Foto der Verkabelung hilft.
2. Im Router eine **feste IP** für „LED-Stripe“ einstellen.
3. Farben prüfen. Falls sie vertauscht sind: Kabel am ESP32 tauschen.
4. **Pi 4:** `sudo ./scripts/homebridge-pi4.sh` → Homebridge-UI auf Port 8581 → Plugin „Homebridge Dreo“ mit dem Dreo-Konto einrichten → in der Home-App koppeln.
5. Den **Code ins GitHub-Repo** `Selbstverliebter/Selbstverliebter` bringen. Branch: `claude/led-stripe-homebridge-setup-g1xrrv`.
   Push ging bisher nicht, Claude hatte keinen Schreibzugriff. GitHub unter claude.ai/connect-github neu verbinden.

---

## 7. Ideen-Speicher

- **Bewegungsmelder** (PIR oder LD2410-Radar) am selben ESP32 → Licht automatisch an
- **Temperatur/Luftfeuchte** (BME280/SHT31) am selben ESP32
- **Alter Sketch** (`sketch_feb17b.ino`) mit **DHT11 + OLED (SSD1306) + Bodenfeuchte** → HomeKit-fähig machen (Pflanzen-Gießmelder)
- **Dreo-Lüfter per Infrarot**: ESP32 + IR-LED ahmt die Fernbedienung nach → HomeKit-„Ventilator“. Alternative zu Homebridge.
- CO₂-Sensor (SCD40), Tür- und Fensterkontakt, Relais (230 V nur mit fertigen Modulen), Klingel-Melder, adressierbarer WS2812B-Stripe

---

## 8. Dateien im Projekt (Repo / ZIP `ledstrip.zip`)

| Datei | Inhalt |
|---|---|
| `esp32/LedStripHomeKit/LedStripHomeKit.ino` | **ESP32-Firmware (Hauptlösung)** |
| `esp32/LedStripHomeKit/secrets.example.h` | Vorlage für WLAN-Daten (`secrets.h`, nicht im Git) |
| `ESP32.md` | Anleitung ESP32: Verkabelung, Flashen, Koppeln, Fehlersuche |
| `HOMEBRIDGE-PI4.md`, `scripts/homebridge-pi4.sh` | Homebridge + Dreo auf dem Pi 4 |
| `ERSTEINRICHTUNG.md` | Pi headless per SSH einrichten (Pi Zero W) |
| `daemon/ledstripd.py`, `install.sh`, `systemd/` | Pi-Variante (HomeKit direkt per HAP-python oder über Homebridge) |
| `homebridge-ledstrip-local/` | Homebridge-Plugin für die Pi-Variante |
| `scripts/stabilisieren.sh` | Pi: Watchdog, WLAN-Stromsparen aus, Swap, avahi |

---

## 9. Vorschlag: Anweisungen für das Claude-Projekt

```
Du hilfst mir bei meinen DIY-Smart-Home-Projekten mit ESP32 (Arduino IDE, HomeSpan) und
Raspberry Pi (Homebridge). Antworte auf Deutsch, locker und mit Schritt-für-Schritt-Anleitungen.
Ich arbeite unter Windows mit Arduino IDE 2.x, mein ESP32 ist ein DevKit (ESP32-D0WD-V3, CP2102, COM3).
Halte dich an die Pin-Belegung und Einstellungen aus PROJEKT-ZUSAMMENFASSUNG.md, frag nicht erneut danach.
Nutze nie GPIO 6–11 und meide 0, 2, 12, 15. Partition Scheme immer "Minimal SPIFFS (1.9MB APP with OTA)".
Wenn du Code änderst, gib mir immer die komplette .ino-Datei und lass secrets.h unangetastet.
Sag ehrlich, wenn du etwas nicht testen konntest.
```
