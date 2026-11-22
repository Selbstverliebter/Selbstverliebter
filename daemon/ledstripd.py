#!/usr/bin/env python3
"""
ledstripd – kleiner, robuster Dienst für einen RGB-LED-Stripe am Raspberry Pi.

* steuert drei GPIOs per PWM (über MOSFETs)
* merkt sich den letzten Zustand (an/aus, Farbe, Helligkeit) dauerhaft auf der SD-Karte
* stellt den Zustand nach einem Neustart wieder her
* bietet eine winzige HTTP-API für das Homebridge-Plugin

Apple Home geht auf zwei Wegen:
  a) direkt: der Dienst ist selbst ein HomeKit-Gerät (HAP-python) → kein Homebridge nötig,
     ideal für schwache Pis wie den Pi Zero W  ("homekit": {"enabled": true})
  b) über Homebridge + Plugin homebridge-ledstrip-local (HTTP-API unten)

API:
  GET  /state   -> {"on": true, "hue": 30, "saturation": 80, "brightness": 60}
  POST /state   <- beliebige Teilmenge davon als JSON, z. B. {"on": true}
  GET  /health  -> {"ok": true, "backend": "lgpio"}
"""

import colorsys
import json
import logging
import os
import signal
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

log = logging.getLogger("ledstripd")

DEFAULT_CONFIG = {
    # BCM-GPIO-Nummern (nicht die physischen Pin-Nummern!)
    "pins": {"red": 17, "green": 22, "blue": 24},
    "backend": "auto",            # "auto" | "lgpio" | "pigpio" | "dummy"
    "pwm_frequency": 800,         # Hz
    "gamma": 2.0,                 # Helligkeitskurve, damit 10 % auch wie 10 % aussehen
    "fade_ms": 400,               # weiches Überblenden, 0 = aus
    "power_on_behavior": "last",  # nach Neustart: "last" | "off" | "on"
    "listen": "127.0.0.1",
    "port": 8765,
    "state_file": "/var/lib/ledstrip/state.json",
    "default_state": {"on": False, "hue": 30, "saturation": 70, "brightness": 60},
    # Optional: Farbkorrektur pro Kanal (0..1), falls Weiß z. B. zu blau wirkt
    "channel_scale": {"red": 1.0, "green": 1.0, "blue": 1.0},
    # Direktes HomeKit ohne Homebridge
    "homekit": {
        "enabled": False,
        "name": "LED Stripe",
        "port": 51826,
        "pincode": None,          # "XXX-XX-XXX"; None = zufällig erzeugen
        "persist_file": "/var/lib/ledstrip/homekit.state",
        "pairing_file": "/var/lib/ledstrip/pairing.txt",
    },
}


# --------------------------------------------------------------------------- #
# GPIO-Backends
# --------------------------------------------------------------------------- #
class DummyBackend:
    name = "dummy"

    def __init__(self, pins, freq):
        self.pins = pins
        self.last = {}

    def set(self, pin, duty):  # duty 0.0 .. 1.0
        self.last[pin] = duty

    def close(self):
        pass


class LgpioBackend:
    """Funktioniert auf allen Pis inkl. Pi 5 (Raspberry Pi OS Bookworm/Trixie)."""

    name = "lgpio"

    def __init__(self, pins, freq):
        import lgpio  # noqa: WPS433

        self.lgpio = lgpio
        self.freq = freq
        self.h = self._open_chip()
        for pin in pins:
            lgpio.gpio_claim_output(self.h, pin, 0)
        self.last = {}

    def _open_chip(self):
        lg = self.lgpio
        # Pi 0-4: gpiochip0. Pi 5: je nach Kernel gpiochip0 oder gpiochip4.
        for chip in (0, 4, 1, 2, 3):
            try:
                h = lg.gpiochip_open(chip)
            except Exception:
                continue
            try:
                info = lg.gpio_get_chip_info(h)
                label = str(info[3]) if len(info) > 3 else ""
            except Exception:
                label = ""
            if "pinctrl" in label or chip == 0 and not label:
                log.info("lgpio: benutze gpiochip%d (%s)", chip, label)
                return h
            lg.gpiochip_close(h)
        raise RuntimeError("Kein passender gpiochip gefunden")

    def set(self, pin, duty):
        duty = max(0.0, min(1.0, duty))
        if self.last.get(pin) == duty:
            return
        self.last[pin] = duty
        if duty <= 0.0:
            self.lgpio.tx_pwm(self.h, pin, 0, 0)
            self.lgpio.gpio_write(self.h, pin, 0)
        elif duty >= 1.0:
            self.lgpio.tx_pwm(self.h, pin, 0, 0)
            self.lgpio.gpio_write(self.h, pin, 1)
        else:
            self.lgpio.tx_pwm(self.h, pin, self.freq, duty * 100.0)

    def close(self):
        for pin in list(self.last):
            try:
                self.set(pin, 0.0)
            except Exception:
                pass
        try:
            self.lgpio.gpiochip_close(self.h)
        except Exception:
            pass


class PigpioBackend:
    """Sauberstes PWM (DMA-basiert), aber nur Pi 0-4 und braucht laufendes pigpiod."""

    name = "pigpio"

    def __init__(self, pins, freq):
        import pigpio  # noqa: WPS433

        self.pigpio = pigpio
        self.pins = pins
        self.freq = freq
        self.pi = None
        self._connect()
        self.last = {}

    def _connect(self):
        pi = self.pigpio.pi()
        if not pi.connected:
            raise RuntimeError("pigpiod nicht erreichbar")
        for pin in self.pins:
            pi.set_mode(pin, self.pigpio.OUTPUT)
            pi.set_PWM_frequency(pin, self.freq)
            pi.set_PWM_range(pin, 1000)
        self.pi = pi

    def set(self, pin, duty):
        duty = max(0.0, min(1.0, duty))
        value = int(round(duty * 1000))
        try:
            self.pi.set_PWM_dutycycle(pin, value)
        except Exception:
            # pigpiod wurde neu gestartet -> neu verbinden und nochmal versuchen
            log.warning("pigpio-Verbindung verloren, verbinde neu")
            self._connect()
            self.pi.set_PWM_dutycycle(pin, value)

    def close(self):
        try:
            for pin in self.pins:
                self.pi.set_PWM_dutycycle(pin, 0)
            self.pi.stop()
        except Exception:
            pass


def make_backend(kind, pins, freq):
    order = {
        "auto": ["pigpio", "lgpio"],
        "lgpio": ["lgpio"],
        "pigpio": ["pigpio"],
        "dummy": ["dummy"],
    }[kind]
    classes = {"lgpio": LgpioBackend, "pigpio": PigpioBackend, "dummy": DummyBackend}
    errors = []
    for name in order:
        try:
            backend = classes[name](pins, freq)
            log.info("GPIO-Backend: %s", name)
            return backend
        except Exception as exc:  # pragma: no cover - hängt von Hardware ab
            errors.append(f"{name}: {exc}")
    raise RuntimeError("Kein GPIO-Backend nutzbar: " + "; ".join(errors))


# --------------------------------------------------------------------------- #
# Zustand + Ausgabe
# --------------------------------------------------------------------------- #
def clamp(v, lo, hi):
    return max(lo, min(hi, v))


def sanitize_state(raw, base):
    s = dict(base)
    if "on" in raw:
        s["on"] = bool(raw["on"])
    if "hue" in raw:
        s["hue"] = clamp(float(raw["hue"]), 0.0, 360.0)
    if "saturation" in raw:
        s["saturation"] = clamp(float(raw["saturation"]), 0.0, 100.0)
    if "brightness" in raw:
        s["brightness"] = clamp(float(raw["brightness"]), 0.0, 100.0)
    return s


class LedStrip:
    def __init__(self, cfg, backend):
        self.cfg = cfg
        self.backend = backend
        self.pins = cfg["pins"]
        self.scale = cfg.get("channel_scale", {})
        self.lock = threading.Lock()
        self.state = self._load_state()
        self.current = (0.0, 0.0, 0.0)
        self.target = self._target_rgb()
        self._wake = threading.Event()
        self._stop = threading.Event()
        self._save_timer = None
        self.listeners = []  # werden bei jeder Änderung mit dem neuen Zustand aufgerufen
        self._fade_from = self.current
        self._fade_start = time.monotonic()
        self.thread = threading.Thread(target=self._render_loop, daemon=True)
        self.thread.start()
        self._wake.set()

    # ---- Persistenz ------------------------------------------------------- #
    def _load_state(self):
        default = sanitize_state(self.cfg["default_state"], {
            "on": False, "hue": 0, "saturation": 0, "brightness": 100})
        path = self.cfg["state_file"]
        saved = default
        try:
            with open(path, encoding="utf-8") as fh:
                saved = sanitize_state(json.load(fh), default)
            log.info("Letzten Zustand geladen: %s", saved)
        except FileNotFoundError:
            log.info("Noch kein gespeicherter Zustand, nehme Standard")
        except Exception as exc:
            log.warning("Zustandsdatei kaputt (%s), nehme Standard", exc)

        behavior = self.cfg.get("power_on_behavior", "last")
        if behavior == "off":
            saved["on"] = False
        elif behavior == "on":
            saved["on"] = True
        return saved

    def _save_now(self):
        path = self.cfg["state_file"]
        with self.lock:
            data = dict(self.state)
        try:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            tmp = path + ".tmp"
            with open(tmp, "w", encoding="utf-8") as fh:
                json.dump(data, fh)
                fh.flush()
                os.fsync(fh.fileno())
            os.replace(tmp, path)  # atomar: nie eine halbe Datei nach Stromausfall
        except Exception as exc:
            log.error("Konnte Zustand nicht speichern: %s", exc)

    def _schedule_save(self):
        # Erst speichern, wenn 3 s lang nichts mehr geändert wurde (schont die SD-Karte,
        # beim Schieben am Helligkeitsregler kommen sonst dutzende Schreibvorgänge).
        if self._save_timer:
            self._save_timer.cancel()
        self._save_timer = threading.Timer(3.0, self._save_now)
        self._save_timer.daemon = True
        self._save_timer.start()

    # ---- Farbe ------------------------------------------------------------ #
    def _target_rgb(self):
        s = self.state
        if not s["on"]:
            return (0.0, 0.0, 0.0)
        r, g, b = colorsys.hsv_to_rgb(s["hue"] / 360.0, s["saturation"] / 100.0, 1.0)
        v = s["brightness"] / 100.0
        return (r * v, g * v, b * v)

    def _write(self, rgb):
        gamma = float(self.cfg.get("gamma", 1.0))
        for (name, value) in zip(("red", "green", "blue"), rgb):
            duty = (value ** gamma) * float(self.scale.get(name, 1.0))
            self.backend.set(self.pins[name], duty)

    def _render_loop(self):
        fade = max(0, int(self.cfg.get("fade_ms", 0))) / 1000.0
        while not self._stop.is_set():
            self._wake.wait(timeout=5.0)
            self._wake.clear()
            while True:
                with self.lock:
                    target = self.target
                    start = self._fade_start
                    origin = self._fade_from
                t = 1.0 if fade == 0 else clamp((time.monotonic() - start) / fade, 0.0, 1.0)
                cur = tuple(o + (tg - o) * t for o, tg in zip(origin, target))
                try:
                    self._write(cur)
                except Exception as exc:
                    log.error("GPIO-Fehler: %s", exc)
                with self.lock:
                    self.current = cur
                if t >= 1.0 or self._stop.is_set():
                    break
                time.sleep(0.02)

    # ---- öffentliche API ------------------------------------------------- #
    def get(self):
        with self.lock:
            return dict(self.state)

    def update(self, patch):
        with self.lock:
            new = sanitize_state(patch, self.state)
            # Wenn jemand die Helligkeit auf 0 zieht, merken wir uns trotzdem die
            # vorherige Helligkeit nicht als 0 – sonst ginge das Licht beim nächsten
            # "An" nicht mehr an.
            if new["brightness"] <= 0:
                new["on"] = False
                new["brightness"] = self.state["brightness"] or 100
            changed = new != self.state
            self.state = new
            self._fade_from = self.current
            self._fade_start = time.monotonic()
            self.target = self._target_rgb()
        self._wake.set()
        state = self.get()
        if changed:
            log.info("Neuer Zustand: %s", new)
            self._schedule_save()
        for listener in list(self.listeners):
            try:
                listener(state)
            except Exception as exc:
                log.error("Listener-Fehler: %s", exc)
        return state

    def shutdown(self):
        self._stop.set()
        self._wake.set()
        if self._save_timer:
            self._save_timer.cancel()
        self._save_now()
        self.backend.close()


# --------------------------------------------------------------------------- #
# HTTP
# --------------------------------------------------------------------------- #
def make_handler(strip):
    class Handler(BaseHTTPRequestHandler):
        server_version = "ledstripd/1.0"

        def _send(self, code, payload):
            body = json.dumps(payload).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):  # noqa: N802
            if self.path == "/state":
                self._send(200, strip.get())
            elif self.path == "/health":
                self._send(200, {"ok": True, "backend": strip.backend.name})
            else:
                self._send(404, {"error": "not found"})

        def do_POST(self):  # noqa: N802
            if self.path != "/state":
                self._send(404, {"error": "not found"})
                return
            try:
                length = int(self.headers.get("Content-Length", 0))
                patch = json.loads(self.rfile.read(length) or b"{}")
                if not isinstance(patch, dict):
                    raise ValueError("JSON-Objekt erwartet")
                self._send(200, strip.update(patch))
            except Exception as exc:
                self._send(400, {"error": str(exc)})

        def log_message(self, fmt, *args):
            log.debug("%s - %s", self.address_string(), fmt % args)

    return Handler


# --------------------------------------------------------------------------- #
# HomeKit direkt (HAP-python)
# --------------------------------------------------------------------------- #
HK_TO_KEY = {"On": "on", "Brightness": "brightness", "Hue": "hue", "Saturation": "saturation"}


def make_homekit_driver(cfg, strip):
    from pyhap.accessory import Accessory
    from pyhap.accessory_driver import AccessoryDriver
    from pyhap.const import CATEGORY_LIGHTBULB

    hk = cfg["homekit"]

    class LightAccessory(Accessory):
        category = CATEGORY_LIGHTBULB

        def __init__(self, driver, name):
            super().__init__(driver, name)
            self.set_info_service(
                manufacturer="DIY", model="RGB LED Stripe (MOSFET)",
                serial_number="ledstrip-1", firmware_revision="1.0")
            s = strip.get()
            serv = self.add_preload_service(
                "Lightbulb", chars=["On", "Brightness", "Hue", "Saturation"])
            self.chars = {
                "On": serv.configure_char("On", value=bool(s["on"])),
                "Brightness": serv.configure_char("Brightness", value=round(s["brightness"])),
                "Hue": serv.configure_char("Hue", value=round(s["hue"])),
                "Saturation": serv.configure_char("Saturation", value=round(s["saturation"])),
            }
            # Alle Werte eines HomeKit-Befehls kommen hier GEMEINSAM an
            # (z. B. Hue + Saturation + On) → ein einziges Update, kein Weiß-Blitzen.
            serv.setter_callback = self._on_set
            strip.listeners.append(self._on_state)

        def _on_set(self, values):
            patch = {HK_TO_KEY[k]: v for k, v in values.items() if k in HK_TO_KEY}
            log.info("HomeKit: %s", patch)
            strip.update(patch)

        def _on_state(self, s):
            # Änderungen von außen (curl, Korrekturen) an HomeKit melden
            new = {"On": bool(s["on"]), "Brightness": round(s["brightness"]),
                   "Hue": round(s["hue"]), "Saturation": round(s["saturation"])}
            for name, value in new.items():
                if self.chars[name].value != value:
                    self.chars[name].set_value(value)

    kwargs = {"port": int(hk["port"]), "persist_file": hk["persist_file"]}
    if hk.get("pincode"):
        kwargs["pincode"] = str(hk["pincode"]).encode()
    os.makedirs(os.path.dirname(hk["persist_file"]), exist_ok=True)
    driver = AccessoryDriver(**kwargs)
    acc = LightAccessory(driver, hk["name"])
    driver.add_accessory(accessory=acc)
    write_pairing_info(hk["pairing_file"], driver, acc)
    return driver


def wait_for_network(timeout=120):
    """Beim Booten ist das WLAN oft noch nicht da. HomeKit würde sonst mit der
    Adresse 127.0.0.1 angekündigt und wäre vom iPhone aus nicht erreichbar."""
    import socket
    deadline = time.monotonic() + timeout
    while True:
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
                sock.connect(("10.255.255.255", 1))
                ip = sock.getsockname()[0]
        except OSError:
            ip = "127.0.0.1"
        if not ip.startswith("127.") or time.monotonic() > deadline:
            log.info("Netzwerk-Adresse: %s", ip)
            return ip
        log.info("Warte auf Netzwerk …")
        time.sleep(2)


def write_pairing_info(path, driver, acc):
    if driver.state.paired:
        text = "Schon mit Apple Home gekoppelt.\n"
    else:
        code = driver.state.pincode.decode()
        text = (
            "In der Home-App: + → Gerät hinzufügen → QR-Code scannen\n"
            f"oder 'Weitere Optionen' / Code manuell eingeben:  {code}\n\n"
        )
        try:
            import pyqrcode
            text += pyqrcode.create(acc.xhm_uri()).terminal(quiet_zone=1) + "\n"
        except Exception:
            text += f"(QR-Code-Inhalt: {acc.xhm_uri()})\n"
    try:
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(text)
    except Exception as exc:
        log.warning("Konnte %s nicht schreiben: %s", path, exc)
    log.info("Kopplung: %s", text.splitlines()[0])


def load_config(path):
    cfg = json.loads(json.dumps(DEFAULT_CONFIG))
    if path and os.path.exists(path):
        with open(path, encoding="utf-8") as fh:
            user = json.load(fh)
        for key, value in user.items():
            if isinstance(value, dict) and isinstance(cfg.get(key), dict):
                cfg[key].update(value)
            else:
                cfg[key] = value
    return cfg


def main():
    logging.basicConfig(
        level=os.environ.get("LOG_LEVEL", "INFO"),
        format="%(levelname)s %(message)s",
    )
    cfg_path = sys.argv[1] if len(sys.argv) > 1 else "/etc/ledstrip/config.json"
    cfg = load_config(cfg_path)
    pins = [cfg["pins"]["red"], cfg["pins"]["green"], cfg["pins"]["blue"]]
    backend = make_backend(cfg["backend"], pins, int(cfg["pwm_frequency"]))
    strip = LedStrip(cfg, backend)

    server = ThreadingHTTPServer((cfg["listen"], int(cfg["port"])), make_handler(strip))
    server.daemon_threads = True
    log.info("Lausche auf http://%s:%s", cfg["listen"], cfg["port"])

    try:
        if cfg["homekit"].get("enabled"):
            wait_for_network()
            driver = make_homekit_driver(cfg, strip)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            signal.signal(signal.SIGTERM, driver.signal_handler)
            signal.signal(signal.SIGINT, driver.signal_handler)
            driver.start()  # blockiert bis SIGTERM
            server.shutdown()
        else:
            def stop(*_):
                log.info("Beende …")
                threading.Thread(target=server.shutdown, daemon=True).start()

            signal.signal(signal.SIGTERM, stop)
            signal.signal(signal.SIGINT, stop)
            server.serve_forever()
    finally:
        strip.shutdown()


if __name__ == "__main__":
    main()
