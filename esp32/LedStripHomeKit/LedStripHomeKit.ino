/*
 * LED-Stripe → Apple Home, direkt mit einem ESP32 (ohne Pi, ohne Homebridge)
 *
 * Bibliothek: HomeSpan (Arduino-Bibliotheksverwalter → "HomeSpan" installieren)
 * Board-Paket: "esp32" von Espressif, Version 3.x
 *
 * Was es kann:
 *  - RGB-Stripe über 3 MOSFETs, flimmerfreies Hardware-PWM
 *  - merkt sich An/Aus, Farbe und Helligkeit im Flash (übersteht Stromausfall)
 *  - "An" schaltet nur an → letzte Farbe bleibt (kein Weiß/100 % mehr)
 *  - weiches Überblenden
 *  - Updates später per WLAN (OTA) aus der Arduino IDE, ohne Kabel
 *
 * ===> Nur den Block EINSTELLUNGEN anpassen. <===
 */

#include "HomeSpan.h"

// Diagnose: gibt Schritte aus und wartet, bis sie wirklich über USB raus sind
#define DEBUG_STEPS 0   // auf 1 setzen, falls der ESP32 wieder in einer Neustart-Schleife hängt
#if DEBUG_STEPS
  #define STEP(msg) do { Serial.printf(">>> SCHRITT: %s\n", msg); Serial.flush(); delay(50); } while (0)
#else
  #define STEP(msg) do {} while (0)
#endif

// ============================== EINSTELLUNGEN ==============================

// GPIO-Nummern der MOSFET-Gates (siehe ESP32.md für passende Pins je Board)
#define PIN_RED     4   // NICHT GPIO 10 – der hängt am Flash-Chip und lässt den ESP32 abstürzen!
#define PIN_GREEN  22
#define PIN_BLUE   17
// Verbotene Pins auf dem ESP32 DevKit: 6–11 (Flash), 34–39 (nur Eingang)

// WLAN-Name und -Passwort stehen in secrets.h (gleicher Ordner wie diese Datei).
// Die Datei wird bei Updates nicht überschrieben und nicht ins Git-Repo hochgeladen.
// Fehlt sie bzw. ist sie leer → der ESP32 öffnet beim ersten Start ein eigenes WLAN
// "LED-Stripe-Setup" (Passwort: homespan), dort trägst du dein WLAN am Handy ein.
#if __has_include("secrets.h")
  #include "secrets.h"
#endif
#ifndef WIFI_SSID
  #define WIFI_SSID      ""
  #define WIFI_PASSWORD  ""
#endif

// HomeKit-Code (8 Ziffern, keine einfachen Folgen wie 12345678 / 11111111).
// Wird in der Home-App eingegeben: 384-61-927
#define PAIRING_CODE   "38461927"

// Passwort für Updates per WLAN (Arduino IDE → Port "LED-Stripe" auswählen)
#define OTA_PASSWORD   "ledstrip"

// Verhalten nach Stromausfall: 0 = wie vorher, 1 = immer aus (Farbe bleibt gemerkt)
#define START_OFF_AFTER_POWER_LOSS  0

#define PWM_FREQ_HZ   1000   // PWM-Frequenz für die MOSFETs
#define PWM_BITS      14     // Auflösung: 14 Bit = 16384 Helligkeitsstufen
#define FADE_MS       400    // Überblendzeit, 0 = sofort
#define GAMMA         2.0f   // Helligkeitskurve (fein regelbar bei wenig Helligkeit)

// Farbkorrektur pro Kanal (0.0 – 1.0), falls Weiß z. B. zu bläulich ist
const float CHANNEL_SCALE[3] = {1.0f, 1.0f, 1.0f};

// Taster (programmierbarer Schalter). Taster zwischen diesem Pin und GND, kein Widerstand nötig.
// -1 = kein Taster. Auf dem klassischen DevKit z. B. 33.
//   1× drücken     → Stripe an/aus (funktioniert auch ohne WLAN/iPhone)
//   2× drücken     → frei belegbar in der Home-App (z. B. Szene "Filmabend")
//   lange drücken  → frei belegbar in der Home-App (z. B. "Alles aus")
#define BUTTON_PIN  33
// 0 = auch "1× drücken" frei in der Home-App belegen statt Stripe direkt zu schalten
#define BUTTON_SINGLE_TOGGLES_LIGHT  1

// Onboard-LED zeigt den WLAN/HomeKit-Status (-1 = aus). Bei vielen ESP32-DevKits: 2
#define STATUS_LED_PIN  -1

// ===========================================================================

struct RgbStrip : Service::LightBulb {

  SpanCharacteristic *power, *hue, *sat, *level;
  const uint8_t pins[3] = {PIN_RED, PIN_GREEN, PIN_BLUE};
  uint32_t lastStep = 0;

  float cur[3]    = {0, 0, 0};   // aktuelle Ausgabe 0..1 (vor Gamma)
  float from[3]   = {0, 0, 0};
  float target[3] = {0, 0, 0};
  uint32_t fadeStart = 0;
  bool fading = false;

  RgbStrip() : Service::LightBulb() {
    // zweiter Parameter "true" = im Flash speichern und beim Start wiederherstellen
    STEP("RgbStrip: Characteristics");
    power = new Characteristic::On(false, true);
    hue   = new Characteristic::Hue(30, true);
    sat   = new Characteristic::Saturation(70, true);
    level = new Characteristic::Brightness(60, true);
    level->setRange(1, 100, 1);

    // PWM direkt über das ESP32-Board-Paket (ohne Interrupts)
    STEP("RgbStrip: PWM einrichten");
    for (int i = 0; i < 3; i++) {
      if (!ledcAttach(pins[i], PWM_FREQ_HZ, PWM_BITS))
        Serial.printf("*** PWM auf GPIO %d fehlgeschlagen!\n", pins[i]);
      ledcWrite(pins[i], 0);
    }

    if (START_OFF_AFTER_POWER_LOSS)
      power->setVal(false, false);

    startFade();   // gespeicherten Zustand sofort wiederherstellen
    STEP("RgbStrip: fertig");
  }

  // Wird von HomeSpan EINMAL pro HomeKit-Befehl aufgerufen – auch wenn das iPhone
  // On + Hue + Saturation gleichzeitig schickt. getNewVal() liefert dann die neuen
  // Werte, für alles andere den bisherigen Wert.
  boolean update() override {
    startFade();
    return true;
  }

  // Für den Taster: direkt am Gerät umschalten (meldet den neuen Zustand an HomeKit)
  void toggle() {
    power->setVal(!power->getVal());
    startFade();
  }

  void startFade() {
    bool  on = power->getNewVal();
    float h  = hue->getNewVal<float>();
    float s  = sat->getNewVal<float>() / 100.0f;
    float v  = level->getNewVal<float>() / 100.0f;
    if (h >= 360.0f) h = 0.0f;   // 360° = 0° (sonst kommt Magenta statt Rot)

    float rgb[3];
    LedPin::HSVtoRGB(h, s, v, &rgb[0], &rgb[1], &rgb[2]);

    for (int i = 0; i < 3; i++) {
      from[i]   = cur[i];
      target[i] = on ? rgb[i] : 0.0f;
    }
    fadeStart = millis();
    fading = true;

    LOG1("LED: on=%d hue=%.0f sat=%.0f%% bri=%.0f%%\n", on, h, s * 100, v * 100);
  }

  void loop() override {
    if (!fading) return;
    if (millis() - lastStep < 10) return;   // max. 100 Schritte pro Sekunde
    lastStep = millis();
    float t = (FADE_MS == 0) ? 1.0f : (millis() - fadeStart) / (float)FADE_MS;
    if (t >= 1.0f) { t = 1.0f; fading = false; }
    for (int i = 0; i < 3; i++) {
      cur[i] = from[i] + (target[i] - from[i]) * t;
      const uint32_t maxDuty = (1u << PWM_BITS) - 1;
      float duty = powf(cur[i], GAMMA) * CHANNEL_SCALE[i];
      if (duty < 0) duty = 0;
      if (duty > 1) duty = 1;
      ledcWrite(pins[i], (uint32_t)(duty * maxDuty + 0.5f));
    }
  }
};

// Taster als "programmierbarer Schalter" in der Home-App
struct WallButton : Service::StatelessProgrammableSwitch {

  SpanCharacteristic *event;
  RgbStrip *strip;

  WallButton(int pin, RgbStrip *strip) : Service::StatelessProgrammableSwitch() {
    this->strip = strip;
    STEP("Taster: anlegen");
    event = new Characteristic::ProgrammableSwitchEvent();
    if (BUTTON_SINGLE_TOGGLES_LIGHT)
      event->setValidValues(2, 1, 2);   // Home-App bietet nur "doppelt" und "lang" an
    new SpanButton(pin);                // interner Pull-up, Taster nach GND
  }

  void button(int pin, int pressType) override {
    if (pressType == SpanButton::SINGLE && BUTTON_SINGLE_TOGGLES_LIGHT) {
      LOG1("Taster: 1x → Stripe umschalten\n");
      strip->toggle();
      return;
    }
    LOG1("Taster: Ereignis %d an HomeKit\n", pressType);
    event->setVal(pressType);           // SINGLE=0, DOUBLE=1, LONG=2 – gleiche Werte wie HomeKit
  }
};

void setup() {
  Serial.begin(115200);
  delay(200);
  STEP("setup() Start");

  homeSpan.setLogLevel(1);               // zeigt Farbänderungen im Seriellen Monitor
  homeSpan.setApSSID("LED-Stripe-Setup");
  homeSpan.enableAutoStartAP();          // ohne WLAN-Daten: Einrichtungs-WLAN öffnen
  if (strlen(WIFI_SSID) > 0)
    homeSpan.setWifiCredentials(WIFI_SSID, WIFI_PASSWORD);
  homeSpan.enableOTA(OTA_PASSWORD);      // Updates per WLAN
  homeSpan.enableWatchdog(30);           // hängt der ESP32 > 30 s → automatischer Neustart
  homeSpan.setHostNameSuffix("");        // im Netzwerk erreichbar als LED-Stripe.local
  if (STATUS_LED_PIN >= 0)
    homeSpan.setStatusPin(STATUS_LED_PIN);

  STEP("vor homeSpan.begin()");
  homeSpan.begin(Category::Lighting, "LED Stripe", "LED-Stripe", "ESP32 RGB LED Stripe");
  STEP("nach begin(), vor setPairingCode()");
  homeSpan.setPairingCode(PAIRING_CODE);  // erst NACH begin(), sonst wird er nicht gespeichert
  STEP("nach setPairingCode()");

  new SpanAccessory();
    new Service::AccessoryInformation();
      new Characteristic::Identify();
      new Characteristic::Name("LED Stripe");
      new Characteristic::Manufacturer("DIY");
      new Characteristic::Model("ESP32 RGB MOSFET");
      new Characteristic::FirmwareRevision("1.0");
    RgbStrip *strip = new RgbStrip();
    if (BUTTON_PIN >= 0)
      new WallButton(BUTTON_PIN, strip);
  STEP("setup() fertig, starte poll()");
}

void loop() {
  static int n = 0;
  if (n < 3) { Serial.printf(">>> SCHRITT: poll() Nr. %d Start\n", n); Serial.flush(); }
  homeSpan.poll();
  if (n < 3) { Serial.printf(">>> SCHRITT: poll() Nr. %d fertig\n", n); Serial.flush(); n++; }
}
