Hallo Claude! Ich baue eine RGB-LED-Stripe-Steuerung mit einem ESP32, die ich über Apple Home (HomeKit) auf dem iPhone steuere. Ich will die Hardware jetzt komplett neu aufbauen, erst auf einem Breadboard, ohne meine alte Lötplatine. Bitte antworte auf Deutsch, locker und Schritt für Schritt.

## Was ich habe und was schon funktioniert

- **ESP32:** NodeMCU/DevKit, Chip ESP32-D0WD-V3 (Rev 3.1), 4 MB Flash, USB-Chip CP2102. Treiber ist installiert, das Board hängt an COM3 (Windows 10/11).
- **Software:** Arduino IDE 2.x, Board-Paket „esp32 von Espressif“ 3.3.12, Bibliothek **HomeSpan 2.1.8**.
  - Board „ESP32 Dev Module“.
  - Partition Scheme **„Minimal SPIFFS (1.9MB APP with OTA/128KB SPIFFS)“**, sonst ist der Sketch zu groß.
- **Flashen:** BOOT halten, EN kurz drücken, BOOT loslassen, dann hochladen, danach EN drücken. Updates gehen auch per WLAN (OTA, Port „LED-Stripe“).
- **Meine Firmware läuft bereits** und ist mit der Home-App gekoppelt. Sie kann:
  - Lightbulb mit Farbe und Helligkeit, Zustand im Flash gespeichert (nach Stromausfall wieder da)
  - weiches Überblenden, Gamma 2.0
  - PWM 1 kHz / 14 Bit über `ledcAttach`/`ledcWrite`
  - Taster an GPIO 33 nach GND als programmierbarer HomeKit-Schalter
  - WLAN-Daten in einer separaten `secrets.h`
- **Aktuelle Pins in der Firmware:** Rot = GPIO 4, Grün = GPIO 22, Blau = GPIO 17 (auf dem Board „TX2“), Taster = GPIO 33.
- **Gelernte Lektionen:**
  - GPIO 10 hat eine Neustart-Schleife verursacht (GPIO 6–11 hängen am Flash). Nie benutzen.
  - GPIO 0, 2, 12 und 15 sind Boot-Pins, die meide ich.
- **Offenes Problem vom alten Aufbau:** Nach dem Umzug an ein Netzteil an anderem Ort mit angeschlossener alter Platine zeigte die Home-App „Keine Antwort“. Vermutlich lag es an Verkabelung oder Stromversorgung. Darum baue ich jetzt neu und sauber auf.

## Vorgeschichte (kurz)

Früher lief das mit einem Raspberry Pi, `pigpio` und einem Homebridge-Plugin, nach der Anleitung von dordnung.de.
- Der Stripe ging immer weiß mit 100 % an.
- Der Pi ist oft abgestürzt.

Deshalb bin ich auf den ESP32 mit HomeSpan umgestiegen. Mein Raspberry Pi 4 soll später nur noch Homebridge machen, für einen Dreo-Lüfter über das Plugin homebridge-dreo. Das ist aber ein anderes Thema.

## Was ich von dir möchte

1. **MOSFET-Frage bestätigen:** Ich habe gelernt, dass ich für einen RGB-Stripe mit gemeinsamer Plusleitung (+12 V) **N-Kanal-Logic-Level-MOSFETs** als Low-Side-Schalter nehmen soll, keine P-Kanal-MOSFETs. Bitte bestätige das kurz.
   Sag mir auch, wie ich herausfinde, ob mein Stripe „common anode“ ist. Auf dem Stripe stehen meist +12V, R, G, B.
2. **Schaltplan (Schematic)**, am besten als Bild/SVG oder Artifact, mit:
   - 12-V-Netzteil → LED-Stripe (+12 V)
   - 3 N-Kanal-MOSFETs für R, G, B, jeweils mit Gate-Vorwiderstand (z. B. 100–220 Ω) und Pull-down-Widerstand (10 kΩ) nach GND
   - ESP32-GPIOs (R = 4, G = 22, B = 17) an die Gates
   - Stromversorgung des ESP32 aus den 12 V über einen Step-down-Wandler auf 5 V → VIN, oder alternativ USB
   - **gemeinsame Masse** von Netzteil, Wandler, ESP32 und MOSFETs
   - Taster an GPIO 33 → GND
   - Sicherung, und wo Kondensatoren sinnvoll sind (z. B. Elko am 12-V-Eingang, 10 µF EN–GND für das Auto-Boot-Problem)
3. **Breadboard-Plan**, so dass ich jedes Kabel einzeln stecken kann:
   - eine Zeichnung, wie die Bauteile auf dem Breadboard sitzen (MOSFET-Pinbelegung Gate/Drain/Source beachten!)
   - eine **Tabelle „Kabel Nr. – von – nach – Farbe“**
   - Hinweise, welche Leitungen nicht über das Breadboard laufen sollten, wegen des hohen Stroms
4. **Einkaufsliste** mit konkreten Bauteilen und Werten: MOSFET-Typ, Widerstände, Step-down-Modul, Netzteil-Größe, Kabelquerschnitt, Sicherung, Taster, Breadboard und Jumperkabel.
5. **Strom und Sicherheit:** Wie berechne ich die Netzteil-Leistung aus der Stripe-Länge? Brauchen die MOSFETs Kühlkörper? Was darf nie passieren (12 V an den ESP32, fehlende Masse, …)?
6. **Testplan:** In welcher Reihenfolge ich aufbaue und teste, damit nichts kaputtgeht. Zuerst ohne Stripe, dann mit einer Farbe, dann mit allen.
7. Falls du **andere Pins** empfiehlst, sag mir, was ich in der Firmware ändern muss. Es sind nur die drei `#define PIN_...`-Zeilen. Die `secrets.h` bleibt, wie sie ist.

Wenn dir Infos fehlen (z. B. Stripe-Länge, LEDs pro Meter, Netzteil-Stromstärke), frag mich zuerst kurz danach.
Sag mir bitte ehrlich, wenn du etwas nicht sicher weißt oder nicht testen konntest.

Später möchte ich noch mehr bauen, z. B. Bewegungsmelder, Temperatursensor, Pflanzen-Gießmelder mit meinem alten DHT11-/OLED-Sketch und den Dreo-Lüfter per Infrarot. Jetzt geht es aber erstmal nur um den LED-Stripe.
