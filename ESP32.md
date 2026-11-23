# LED-Stripe mit ESP32 → Apple Home (empfohlen)

Der ESP32 spricht **HomeKit selbst**, mit der Bibliothek [HomeSpan](https://github.com/HomeSpan/HomeSpan).
Du brauchst **keinen Raspberry Pi, kein Homebridge und keine SD-Karte**.

```
iPhone (Home-App) ──HomeKit (WLAN)──▶ ESP32 ──PWM──▶ MOSFETs ──▶ LED-Stripe
```

- Er merkt sich Farbe, Helligkeit und An/Aus im Flash. Das übersteht auch einen Stromausfall.
- „An“ schaltet nur an, die letzte Farbe bleibt. Kein „weiß und 100 %“ mehr.
- Er ist nach 2–3 Sekunden betriebsbereit. Es gibt kein Betriebssystem, das abstürzen kann, und einen eingebauten Watchdog.
- Updates gehen später per WLAN, ohne Kabel.

## 1. Verdrahtung

Deine Lötplatine mit den MOSFETs kannst du weiterverwenden. Statt an den Pi gehen **4 Kabel** an den ESP32:

| Platine (vorher zum Pi) | ESP32 (klassisches DevKit) |
|---|---|
| Gate/Eingang **Rot** | **GPIO 25** |
| Gate/Eingang **Grün** | **GPIO 26** |
| Gate/Eingang **Blau** | **GPIO 27** |
| **GND** | **GND**, unbedingt verbinden! |

### Deine Platine hat eine Buchsenleiste für den Pi? → Jumper-Kabel, ohne Löten

Du brauchst **5 Dupont-Jumperkabel „Stecker auf Buchse“ (male-female)**. Den Stecker steckst du in die Buchsenleiste
der Platine, an die Stelle, an der vorher der Pi-Pin steckte. Die Buchse steckst du auf den Pin des ESP32.

Draufsicht auf die Buchsenleiste. Pin 1 liegt an dem Ende, wo beim Pi die SD-Karte ist, in der **inneren** Reihe.
Die äußere Reihe, also die zur Platinenkante des Pi, hat die geraden Nummern:

```
              innen   außen
   3,3 V  ->   [ 1]   [ 2]  <- 5 V
               [ 3]   [ 4]  <- 5 V
               [ 5]   [ 6]  <- GND  ●
               [ 7]   [ 8]
     GND  ●    [ 9]   [10]
 GPIO 17  ★    [11]   [12]
               [13]   [14]  <- GND
 GPIO 22  ★    [15]   [16]
               [17]   [18]  ★ GPIO 24
               [19]   [20]  <- GND
               ...    ...
```

| Buchsenleiste (Pi-Pin) | → ESP32 | Farbe (wie in der dordnung.de-Anleitung) |
|---|---|---|
| Pin **11** (GPIO 17) | GPIO 25 | Rot |
| Pin **15** (GPIO 22) | GPIO 26 | Grün |
| Pin **18** (GPIO 24) | GPIO 27 | Blau |
| Pin **6** (GND) | GND | Pflicht! |
| *(optional)* Pin **2** (5 V) | 5V / VIN | nur wenn deine Platine den Pi mit Strom versorgt hat, siehe unten |

**Du weißt nicht mehr, welche Pins es waren?** So testest du es, ohne etwas kaputtzumachen:
1. Das LED-Netzteil einstecken. Den ESP32 per USB versorgen und **GND vom ESP32 → Pin 6** der Leiste verbinden.
2. Ein Jumperkabel an den **3V3-Pin des ESP32** stecken. Mit dem anderen Ende kurz nacheinander
   in die Löcher 11, 15, 18 (und notfalls 12, 13, 16, 22 …) der Leiste tippen.
3. Wo der Stripe rot, grün oder blau aufleuchtet, sind deine drei Pins. ⚠️ **Nicht in Pin 2 oder 4 tippen**, da liegen 5 V.

Leuchtet am Ende eine falsche Farbe, tauschst du einfach zwei Kabel am ESP32. Am Code musst du nichts ändern.

**Hat die Platine den Pi mit Strom versorgt?** Wenn auf der Platine ein Spannungswandler sitzt und der Pi kein eigenes
USB-Netzteil hatte, dann ja. Prüf das mit dem Multimeter: LED-Netzteil an, Spannung zwischen **Pin 2 und Pin 6** messen.
- Misst du **ca. 5 V**, kannst du den ESP32 mit einem Kabel von Pin 2 → **5V/VIN** versorgen. Dann ist **kein USB-Netzteil** nötig.
- Misst du **mehr als 5,5 V**, darfst du das **nicht** anschließen. Dann versorgst du den ESP32 per USB.
- ⚠️ USB-Kabel und Pin 2 nicht gleichzeitig benutzen. Zum Hochladen das 5-V-Kabel abziehen.

**Strom für den ESP32**, eine von zwei Möglichkeiten:
- ein USB-Netzteil am USB-Anschluss, **oder**
- ein kleiner **Step-down-Wandler** (z. B. MP1584 oder LM2596), der aus den 12 V des LED-Netzteils **5 V** macht → an den Pin **5V/VIN** des ESP32.
  ⚠️ **Niemals 12 V direkt an den ESP32!**

**MOSFETs:** Der ESP32 schaltet mit 3,3 V, genau wie der Pi. Was am Pi lief, läuft also auch hier.
Logic-Level-Typen (z. B. IRLZ44N, IRLB8721) sind ideal.

**Andere ESP32-Boards:** Die Pins oben im Sketch änderst du so:

| Board | gute Pins für R/G/B | diese Pins meiden |
|---|---|---|
| ESP32 DevKit / WROOM-32 | 25, 26, 27 (auch 16–19, 21–23, 32, 33) | 0, 2, 12, 15 (Boot-Pins), 6–11 (Flash), 34–39 (nur Eingang) |
| ESP32-C3 (z. B. SuperMini) | 5, 6, 7 | 2, 8, 9 (Boot-Pins), 18, 19 (USB) |
| ESP32-S3 | 4, 5, 6 | 0, 3, 45, 46 (Boot-Pins), 19, 20 (USB) |

Tipp: Ein **10-kΩ-Widerstand von jedem Gate nach GND** verhindert, dass der Stripe beim Einstecken kurz aufblitzt.
Auf vielen MOSFET-Platinen ist das schon drauf.

## 2. Arduino IDE vorbereiten (einmalig, am Computer)

1. **Arduino IDE 2** installieren: https://www.arduino.cc/en/software
2. *Einstellungen* → *Zusätzliche Boardverwalter-URLs*:
   `https://espressif.github.io/arduino-esp32/package_esp32_index.json`
3. *Boardverwalter* → nach **„esp32“** suchen → **„esp32 von Espressif Systems“** installieren, **Version 3.x**.
4. *Bibliotheksverwalter* → nach **„HomeSpan“** suchen → installieren.

## 3. Sketch anpassen und hochladen

1. `esp32/LedStripHomeKit/LedStripHomeKit.ino` öffnen.
2. Oben im Block **EINSTELLUNGEN** prüfen:
   - die Pins (`PIN_RED`, `PIN_GREEN`, `PIN_BLUE`)
   - optional WLAN-Name und -Passwort. Wenn du sie leer lässt, richtest du das WLAN später am Handy ein (siehe Schritt 4).
3. ESP32 per USB-Kabel anschließen. Das Kabel muss Daten übertragen können, reine Ladekabel gehen nicht.
4. *Werkzeuge* einstellen:
   - **Board:** „ESP32 Dev Module“ (bzw. „ESP32C3 Dev Module“ / „ESP32S3 Dev Module“)
   - **Partition Scheme:** **„Minimal SPIFFS (1.9MB APP with OTA/190KB SPIFFS)“**
     ⚠️ Wichtig: Mit der Voreinstellung meldet die IDE „Sketch too big“.
   - **Port:** den USB-Port des ESP32
5. **Hochladen** (Pfeil-Knopf). Falls es hängt: Beim Hochladen die **BOOT**-Taste am ESP32 gedrückt halten.
   Am Mac brauchst du je nach Board eventuell einen Treiber (CP210x oder CH340).

## 4. WLAN einrichten (falls nicht im Sketch eingetragen)

1. Nach dem Hochladen öffnet der ESP32 ein eigenes WLAN namens **„LED-Stripe-Setup“**. Das Passwort ist **`homespan`**.
2. Verbinde dich mit dem Handy. Es öffnet sich eine Seite, auf der du dein WLAN auswählst und das Passwort eingibst.
   Falls sich keine Seite öffnet, rufst du im Browser `http://192.168.4.1/hotspot-detect.html` auf.
   Wenn die Seite nach einem Setup-Code fragt: `38461927`.
3. Der ESP32 startet neu und verbindet sich mit deinem WLAN. ⚠️ Viele ESP32 können nur 2,4 GHz.

Alternativ geht es per Kabel: In der Arduino IDE den *Seriellen Monitor* öffnen (115200 Baud) und `W` eingeben.

## 5. Mit Apple Home koppeln

Home-App → **„+“** → **„Gerät hinzufügen“** → **„Weitere Optionen …“** → **„LED Stripe“** antippen → Code **`384-61-927`** eingeben.
Die Meldung „Nicht zertifiziertes Gerät“ bestätigst du mit „Trotzdem hinzufügen“. Fertig. 🎉

Den Code kannst du oben im Sketch unter `PAIRING_CODE` ändern.

## 6. Später: Updates per WLAN

In der Arduino IDE unter *Werkzeuge → Port* erscheint ein Netzwerk-Port **„LED-Stripe“**.
Auswählen, hochladen, und als Passwort `ledstrip` eingeben. Ein Kabel brauchst du dafür nicht.

## Fehlersuche (Serieller Monitor, 115200 Baud)

| Befehl | Wirkung |
|---|---|
| `?` | Hilfe |
| `W` | WLAN neu einrichten |
| `U` | HomeKit-Kopplung löschen (danach in der Home-App neu hinzufügen) |
| `E` | **alles** löschen (WLAN, Kopplung, gespeicherte Farbe) |

- **Farbe stimmt nicht** (z. B. rot statt blau): Die Pins im Sketch tauschen und neu hochladen.
- **„Keine Antwort“:** Prüfe, ob das 2,4-GHz-WLAN den ESP erreicht, und stell im Router eine feste IP ein.
- **Von unterwegs steuern:** Dafür brauchst du wie immer eine Steuerzentrale (HomePod, Apple TV oder iPad).
