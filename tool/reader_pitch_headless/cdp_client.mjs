// Minimal Chrome DevTools Protocol (CDP) client over WebSocket using only
// Node built-in modules (no puppeteer / no npm deps). Enough to: launch
// headless Chrome, open a page target, navigate to a data: URL, and run
// Runtime.evaluate to read back JSON-serialisable layout numbers.
//
// Used by TODO-753 horizontal sub-pixel pageStep harness + flutter guard.

import { spawn } from 'node:child_process';
import http from 'node:http';
import net from 'node:net';
import crypto from 'node:crypto';
import os from 'node:os';
import fs from 'node:fs';
import path from 'node:path';

/** Resolve a Chrome/Chromium executable across platforms. Returns null if none. */
export function resolveChrome() {
  const env = process.env.CHROME_PATH || process.env.PUPPETEER_EXECUTABLE_PATH;
  const candidates = [
    env,
    'C:/Program Files/Google/Chrome/Application/chrome.exe',
    'C:/Program Files (x86)/Google/Chrome/Application/chrome.exe',
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    '/usr/bin/google-chrome',
    '/usr/bin/google-chrome-stable',
    '/usr/bin/chromium',
    '/usr/bin/chromium-browser',
  ].filter(Boolean);
  for (const c of candidates) {
    try {
      if (fs.existsSync(c)) return c;
    } catch (_) {
      // ignore
    }
  }
  return null;
}

function getJson(url, tries = 60) {
  return new Promise((resolve, reject) => {
    const attempt = (n) => {
      http
        .get(url, (res) => {
          let b = '';
          res.on('data', (d) => (b += d));
          res.on('end', () => {
            try {
              resolve(JSON.parse(b));
            } catch (e) {
              reject(e);
            }
          });
        })
        .on('error', (e) => {
          if (n <= 0) return reject(e);
          setTimeout(() => attempt(n - 1), 250);
        });
    };
    attempt(tries);
  });
}

/** Tiny WebSocket client (text frames only) speaking just enough for CDP. */
class CdpSocket {
  constructor(wsUrl) {
    this.wsUrl = wsUrl;
    this.nextId = 1;
    this.pending = new Map();
    this.events = [];
    this.buf = Buffer.alloc(0);
  }

  async connect(retries = 20) {
    for (let i = 0; ; i++) {
      try {
        await this._connectOnce();
        return;
      } catch (e) {
        if (i >= retries || e.code !== 'ECONNREFUSED') throw e;
        await new Promise((r) => setTimeout(r, 150));
      }
    }
  }

  _connectOnce() {
    const u = new URL(this.wsUrl);
    return new Promise((resolve, reject) => {
      const key = crypto.randomBytes(16).toString('base64');
      const sock = net.connect(
        Number(u.port),
        u.hostname,
        () => {
          const req =
            `GET ${u.pathname}${u.search} HTTP/1.1\r\n` +
            `Host: ${u.host}\r\n` +
            'Upgrade: websocket\r\n' +
            'Connection: Upgrade\r\n' +
            `Sec-WebSocket-Key: ${key}\r\n` +
            'Sec-WebSocket-Version: 13\r\n\r\n';
          sock.write(req);
        }
      );
      this.sock = sock;
      let handshakeDone = false;
      sock.on('data', (chunk) => {
        if (!handshakeDone) {
          this.buf = Buffer.concat([this.buf, chunk]);
          const sep = this.buf.indexOf('\r\n\r\n');
          if (sep === -1) return;
          const header = this.buf.slice(0, sep).toString();
          if (!/101/.test(header)) {
            reject(new Error('WS handshake failed: ' + header.split('\r\n')[0]));
            return;
          }
          handshakeDone = true;
          this.buf = this.buf.slice(sep + 4);
          resolve();
          this._drain();
        } else {
          this.buf = Buffer.concat([this.buf, chunk]);
          this._drain();
        }
      });
      sock.on('error', reject);
    });
  }

  _drain() {
    // Parse server->client text frames (no masking from server).
    while (this.buf.length >= 2) {
      const b0 = this.buf[0];
      const b1 = this.buf[1];
      const opcode = b0 & 0x0f;
      const masked = (b1 & 0x80) !== 0;
      let len = b1 & 0x7f;
      let offset = 2;
      if (len === 126) {
        if (this.buf.length < 4) return;
        len = this.buf.readUInt16BE(2);
        offset = 4;
      } else if (len === 127) {
        if (this.buf.length < 10) return;
        len = Number(this.buf.readBigUInt64BE(2));
        offset = 10;
      }
      if (masked) offset += 4;
      if (this.buf.length < offset + len) return;
      const payload = this.buf.slice(offset, offset + len);
      this.buf = this.buf.slice(offset + len);
      if (opcode === 0x8) {
        // close
        try {
          this.sock.end();
        } catch (_) {}
        return;
      }
      if (opcode === 0x1 || opcode === 0x0) {
        try {
          const msg = JSON.parse(payload.toString());
          if (msg.id && this.pending.has(msg.id)) {
            const { resolve, reject } = this.pending.get(msg.id);
            this.pending.delete(msg.id);
            if (msg.error) reject(new Error(JSON.stringify(msg.error)));
            else resolve(msg.result);
          } else if (msg.method) {
            this.events.push(msg);
          }
        } catch (_) {
          // ignore non-JSON
        }
      }
    }
  }

  _sendFrame(text) {
    const payload = Buffer.from(text);
    const len = payload.length;
    let header;
    if (len < 126) {
      header = Buffer.from([0x81, 0x80 | len]);
    } else if (len < 65536) {
      header = Buffer.alloc(4);
      header[0] = 0x81;
      header[1] = 0x80 | 126;
      header.writeUInt16BE(len, 2);
    } else {
      header = Buffer.alloc(10);
      header[0] = 0x81;
      header[1] = 0x80 | 127;
      header.writeBigUInt64BE(BigInt(len), 2);
    }
    const mask = crypto.randomBytes(4);
    const masked = Buffer.alloc(len);
    for (let i = 0; i < len; i++) masked[i] = payload[i] ^ mask[i % 4];
    this.sock.write(Buffer.concat([header, mask, masked]));
  }

  send(method, params = {}) {
    const id = this.nextId++;
    const msg = JSON.stringify({ id, method, params });
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this._sendFrame(msg);
    });
  }

  close() {
    try {
      this.sock.end();
    } catch (_) {}
  }
}

/**
 * Launch headless Chrome, open one page, return a driver with `evalOnPage(html, expr)`.
 * The driver navigates to a data: URL built from `html`, waits for load, then
 * evaluates `expr` (a JS expression string returning a JSON value) and returns it.
 */
export async function launchChromeDriver() {
  const chromePath = resolveChrome();
  if (!chromePath) throw new Error('NO_CHROME');
  const port = 9000 + Math.floor(Math.random() * 1000);
  const userDir = fs.mkdtempSync(path.join(os.tmpdir(), 'rph-chrome-'));
  const proc = spawn(
    chromePath,
    [
      '--headless=new',
      '--disable-gpu',
      '--no-sandbox',
      '--disable-dev-shm-usage',
      `--user-data-dir=${userDir}`,
      `--remote-debugging-port=${port}`,
      '--remote-allow-origins=*',
      '--window-size=1280,800',
      'about:blank',
    ],
    { stdio: 'ignore' }
  );

  let sock;
  try {
    const targets = await getJson(`http://127.0.0.1:${port}/json`);
    const page = targets.find((t) => t.type === 'page');
    if (!page) throw new Error('no page target');
    sock = new CdpSocket(page.webSocketDebuggerUrl);
    await sock.connect();
    await sock.send('Page.enable');
    await sock.send('Runtime.enable');
  } catch (e) {
    try {
      proc.kill();
    } catch (_) {}
    throw e;
  }

  async function evalOnPage(html, expr) {
    const dataUrl = 'data:text/html;charset=utf-8,' + encodeURIComponent(html);
    sock.events.length = 0;
    await sock.send('Page.navigate', { url: dataUrl });
    // Wait for load event.
    const deadline = Date.now() + 8000;
    while (Date.now() < deadline) {
      if (sock.events.some((e) => e.method === 'Page.loadEventFired')) break;
      await new Promise((r) => setTimeout(r, 30));
    }
    // Give layout one more frame.
    await sock.send('Runtime.evaluate', {
      expression: 'new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)))',
      awaitPromise: true,
    });
    const res = await sock.send('Runtime.evaluate', {
      expression: `JSON.stringify((function(){ return (${expr}); })())`,
      returnByValue: true,
    });
    if (res.exceptionDetails) {
      throw new Error('eval exception: ' + JSON.stringify(res.exceptionDetails));
    }
    return JSON.parse(res.result.value);
  }

  function close() {
    try {
      sock && sock.close();
    } catch (_) {}
    try {
      proc.kill();
    } catch (_) {}
    try {
      fs.rmSync(userDir, { recursive: true, force: true });
    } catch (_) {}
  }

  return { evalOnPage, close };
}
