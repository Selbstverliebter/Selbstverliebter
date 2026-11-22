'use strict';

/*
 * homebridge-ledstrip-local
 *
 * Dünnes Homebridge-Plugin für den lokalen Dienst "ledstripd".
 * Der Dienst merkt sich den Zustand; dieses Plugin reicht nur durch.
 *
 * Wichtig gegen das alte "immer weiß + 100 %"-Problem:
 *  - "An" schickt NUR {on:true}, nie eine Farbe → die letzte Farbe bleibt.
 *  - Hue/Saturation/Brightness, die HomeKit in schneller Folge schickt,
 *    werden 60 ms gesammelt und als EIN Befehl gesendet.
 *  - Abfragen werden sofort aus dem Cache beantwortet → keine
 *    "Keine Antwort"-Meldungen, auch wenn der Dienst kurz neu startet.
 */

const http = require('http');

const PLUGIN_NAME = 'homebridge-ledstrip-local';
const ACCESSORY_NAME = 'LedStripLocal';

module.exports = (api) => {
  api.registerAccessory(PLUGIN_NAME, ACCESSORY_NAME, LedStripAccessory);
};

function request(baseUrl, method, path, body, timeoutMs) {
  return new Promise((resolve, reject) => {
    const url = new URL(path, baseUrl);
    const data = body ? Buffer.from(JSON.stringify(body)) : null;
    const req = http.request(
      url,
      {
        method,
        timeout: timeoutMs,
        headers: data
          ? { 'Content-Type': 'application/json', 'Content-Length': data.length }
          : {},
      },
      (res) => {
        let raw = '';
        res.setEncoding('utf8');
        res.on('data', (c) => (raw += c));
        res.on('end', () => {
          if (res.statusCode !== 200) {
            reject(new Error(`HTTP ${res.statusCode}: ${raw}`));
            return;
          }
          try {
            resolve(JSON.parse(raw));
          } catch (e) {
            reject(e);
          }
        });
      },
    );
    req.on('timeout', () => req.destroy(new Error('Timeout')));
    req.on('error', reject);
    if (data) req.write(data);
    req.end();
  });
}

class LedStripAccessory {
  constructor(log, config, api) {
    this.log = log;
    this.api = api;
    this.name = config.name || 'LED Stripe';
    this.url = config.url || 'http://127.0.0.1:8765';
    this.pollSeconds = Number(config.pollSeconds || 15);

    const { Service, Characteristic } = api.hap;
    this.Characteristic = Characteristic;

    // Startwerte bis zur ersten Antwort des Dienstes
    this.state = { on: false, hue: 30, saturation: 70, brightness: 60 };
    this.pending = {};
    this.flushTimer = null;

    this.info = new Service.AccessoryInformation()
      .setCharacteristic(Characteristic.Manufacturer, 'DIY')
      .setCharacteristic(Characteristic.Model, 'RGB LED Stripe (MOSFET)')
      .setCharacteristic(Characteristic.SerialNumber, 'ledstrip-local-1');

    this.light = new Service.Lightbulb(this.name);

    this.bind(Characteristic.On, 'on', (v) => Boolean(v));
    this.bind(Characteristic.Brightness, 'brightness', (v) => Number(v));
    this.bind(Characteristic.Hue, 'hue', (v) => Number(v));
    this.bind(Characteristic.Saturation, 'saturation', (v) => Number(v));

    this.refresh();
    this.pollTimer = setInterval(() => this.refresh(), this.pollSeconds * 1000);
    api.on('shutdown', () => clearInterval(this.pollTimer));
  }

  bind(characteristic, key, convert) {
    this.light
      .getCharacteristic(characteristic)
      .onGet(() => this.state[key])
      .onSet((value) => {
        const v = convert(value);
        this.state[key] = v;
        this.pending[key] = v;
        this.scheduleFlush();
      });
  }

  scheduleFlush() {
    if (this.flushTimer) clearTimeout(this.flushTimer);
    this.flushTimer = setTimeout(() => this.flush(), 60);
  }

  async flush(attempt = 1) {
    this.flushTimer = null;
    const patch = this.pending;
    this.pending = {};
    if (Object.keys(patch).length === 0) return;
    try {
      const newState = await request(this.url, 'POST', '/state', patch, 3000);
      this.apply(newState);
    } catch (e) {
      if (attempt < 4) {
        this.log.warn(`ledstripd nicht erreichbar (${e.message}), Versuch ${attempt + 1} …`);
        // Neuere Änderungen gewinnen, ältere werden nachgereicht
        this.pending = { ...patch, ...this.pending };
        setTimeout(() => this.flush(attempt + 1), 1000 * attempt);
      } else {
        this.log.error(`Konnte LED-Stripe nicht schalten: ${e.message}`);
      }
    }
  }

  async refresh() {
    if (this.flushTimer || Object.keys(this.pending).length) return;
    try {
      this.apply(await request(this.url, 'GET', '/state', null, 3000));
    } catch (e) {
      this.log.debug(`Status-Abfrage fehlgeschlagen: ${e.message}`);
    }
  }

  apply(s) {
    const C = this.Characteristic;
    const map = [
      ['on', C.On, Boolean(s.on)],
      ['brightness', C.Brightness, Math.round(s.brightness)],
      ['hue', C.Hue, Math.round(s.hue)],
      ['saturation', C.Saturation, Math.round(s.saturation)],
    ];
    for (const [key, ch, value] of map) {
      if (this.state[key] !== value) {
        this.state[key] = value;
        this.light.updateCharacteristic(ch, value);
      }
    }
  }

  getServices() {
    return [this.info, this.light];
  }
}
