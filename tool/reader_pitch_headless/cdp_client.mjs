// Minimal Chrome DevTools Protocol (CDP) client over WebSocket using only
// Node built-in modules (no puppeteer / no npm deps). Enough to: launch
// headless Chrome, open a page target, load an HTML string (served from a
// private loopback server, see startPageServer), and run
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

function getJson(url, tries = 24) {
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

/**
 * Hang guard for a single CDP command. CDP replies are the readiness signal;
 * this only fires when Chrome stops answering. It is sized against the
 * enclosing 90 s Dart budget rather than a guessed "normal" latency: on a
 * CPU-starved runner a healthy Chrome can take well over 10 s to answer the
 * first Page.navigate (it spawns the first renderer process), which the former
 * 10 s default reported as a failure.
 */
const CDP_COMMAND_HANG_GUARD_MS = 30000;

/** Tiny WebSocket client (text frames only) speaking just enough for CDP. */
class CdpSocket {
  constructor(wsUrl) {
    this.wsUrl = wsUrl;
    this.nextId = 1;
    this.pending = new Map();
    this.events = [];
    this.buf = Buffer.alloc(0);
  }

  async connect(retries = 12) {
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

  send(method, params = {}, timeoutMs = CDP_COMMAND_HANG_GUARD_MS) {
    const id = this.nextId++;
    const msg = JSON.stringify({ id, method, params });
    return new Promise((resolve, reject) => {
      // Per-command deadline. A CDP response frame can be lost or arbitrarily
      // delayed on a loaded/slow runner; without this the Promise would never
      // settle and the whole node process would hang past the Dart isolate's
      // 30s test timeout (surfacing as TimeoutException, not a harness skip).
      const timer = setTimeout(() => {
        if (this.pending.has(id)) {
          this.pending.delete(id);
          reject(new Error('CDP command timed out: ' + method));
        }
      }, timeoutMs);
      this.pending.set(id, {
        resolve: (v) => {
          clearTimeout(timer);
          resolve(v);
        },
        reject: (e) => {
          clearTimeout(timer);
          reject(e);
        },
      });
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
 * One hang guard for the whole cold-start sequence (spawn -> DevTools
 * listening -> page target -> Page.enable / Runtime.enable). It is not a
 * readiness wait: every step waits on Chrome's own signal (the
 * `DevTools listening on ws://...` stderr line that puppeteer also waits on,
 * which Chrome prints from the same ServerStarted callback that writes
 * DevToolsActivePort; then the CDP replies), and a spawn error or early exit
 * (by code or by signal) rejects at once with Chrome's stderr. The bound only
 * fires when Chrome is alive but never becomes ready. It is sized to the
 * enclosing budget (the Dart guards give the whole harness 90 s), not to a
 * guessed "normal" startup time: on a 4-core CI runner executing ~30k tests
 * with --coverage a cold Chrome start is CPU-starved, and the former stacked
 * per-step guesses (8 s port poll, then 10 s per enable command) each fired
 * while Chrome was merely slow.
 */
const CHROME_ATTACH_HANG_GUARD_MS = 60000;
const STDERR_TAIL_CHARS = 16384;

/**
 * Keep draining Chrome's stderr for its whole life (an undrained pipe would
 * eventually block Chrome's logging writes) while retaining a bounded tail
 * for failure messages.
 */
function captureStderr(proc) {
  let tail = '';
  proc.stderr.setEncoding('utf8');
  proc.stderr.on('data', (chunk) => {
    tail = (tail + chunk).slice(-STDERR_TAIL_CHARS);
  });
  // A broken pipe after we kill Chrome is expected; never crash the harness.
  proc.stderr.on('error', () => {});
  return { text: () => tail };
}

/**
 * Wait for Chrome to announce its browser DevTools WebSocket on stderr and
 * resolve with the port it bound (`--remote-debugging-port=0` = ephemeral, so
 * concurrent processes never collide). Rejects immediately if Chrome fails to
 * spawn or exits before becoming ready.
 */
function waitForDevToolsPort(proc, stderrLog, timeoutMs) {
  const startedAt = Date.now();
  return new Promise((resolve, reject) => {
    let settled = false;
    let scanned = '';
    const describe = () => {
      const tail = stderrLog.text().trim();
      return tail ? '\n--- chrome stderr (tail) ---\n' + tail : ' (chrome wrote no stderr)';
    };
    const finish = (err, port) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      proc.stderr.off('data', onData);
      proc.off('exit', onExit);
      proc.off('error', onError);
      if (err) reject(err);
      else resolve(port);
    };
    const onData = (chunk) => {
      scanned = (scanned + chunk).slice(-STDERR_TAIL_CHARS);
      const m = /DevTools listening on ws:\/\/[^\s/]+:(\d+)\//.exec(scanned);
      if (m) finish(null, Number(m[1]));
    };
    const onExit = (code, signal) => {
      finish(new Error('chrome exited before DevTools was ready (code ' + code +
        ', signal ' + signal + ', after ' + (Date.now() - startedAt) + 'ms)' + describe()));
    };
    const onError = (e) => {
      finish(new Error('chrome failed to spawn: ' + e.message));
    };
    const timer = setTimeout(() => {
      finish(new Error('chrome alive but DevTools not listening after ' +
        timeoutMs + 'ms' + describe()));
    }, timeoutMs);
    proc.stderr.on('data', onData);
    proc.once('exit', onExit);
    proc.once('error', onError);
    // The process may already be gone before the listeners were attached.
    if (proc.exitCode !== null || proc.signalCode !== null) {
      onExit(proc.exitCode, proc.signalCode);
    }
  });
}

/**
 * Sandbox flags for the pages the driver serves. Without `allow-same-origin`
 * the document gets an opaque origin, as a `data:` document does (storage and
 * cookies throw, `origin` is "null", a sandboxed child iframe stays
 * cross-origin to it); everything else a top-level `data:` page may do stays
 * allowed.
 */
const PAGE_SANDBOX_CSP =
  'sandbox allow-scripts allow-forms allow-modals allow-popups ' +
  'allow-popups-to-escape-sandbox allow-pointer-lock allow-downloads ' +
  'allow-presentation allow-orientation-lock allow-top-navigation';

/**
 * Serves each page the driver loads from a private loopback HTTP server.
 *
 * Why not a `data:` URL: the page travels inside the URL, so Chrome has to
 * carry, parse and percent-decode a URL three times the size of the HTML in
 * the browser process before the renderer even sees it. For the harnesses that
 * inline the production popup / reader scripts (~460 KB) that cost 1.4-2.3 s
 * per load on an idle 2026 desktop versus 0.1-0.2 s served over HTTP, and a
 * harness loads 20+ pages -- on a CPU-starved CI runner the popup sandbox
 * suite went past its 80 s budget from page loads alone. Each page gets a
 * fresh path (no cache) and stays servable while it is one of the last
 * [KEPT_PAGES] (Chrome may fetch a navigation again), with [PAGE_SANDBOX_CSP]
 * so its origin stays opaque like the `data:` page it replaces. Relative
 * subresources 404, which fails them the same way an unresolvable relative
 * URL in `data:` does.
 */
const KEPT_PAGES = 8;

async function startPageServer() {
  const pages = new Map();
  const served = new Set();
  let seq = 0;
  const server = http.createServer((req, res) => {
    const html = pages.get(req.url);
    if (html === undefined) {
      res.statusCode = 404;
      res.end();
      return;
    }
    served.add(req.url);
    res.setHeader('content-type', 'text/html; charset=utf-8');
    res.setHeader('cache-control', 'no-store');
    res.setHeader('content-security-policy', PAGE_SANDBOX_CSP);
    res.end(html);
  });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  const port = server.address().port;
  return {
    /** Registers `html` and returns the URL that serves it (once). */
    urlFor(html) {
      const p = `/page/${++seq}`;
      pages.set(p, html);
      for (const old of pages.keys()) {
        if (pages.size <= KEPT_PAGES) break;
        pages.delete(old);
        served.delete(old);
      }
      return `http://127.0.0.1:${port}${p}`;
    },
    /** Whether Chrome has fetched the page behind `url` at least once. */
    wasServed(url) {
      return served.has(new URL(url).pathname);
    },
    close() {
      pages.clear();
      try {
        server.closeAllConnections?.();
      } catch (_) {}
      server.close();
    },
  };
}

/**
 * Launch headless Chrome, open one page, return a driver with `evalOnPage(html, expr)`.
 * The driver loads `html` (served once from a private loopback server, see
 * [startPageServer]), waits for load, then evaluates `expr` (a JS expression
 * string returning a JSON value) and returns it.
 */
export async function launchChromeDriver() {
  const chromePath = resolveChrome();
  if (!chromePath) throw new Error('NO_CHROME');
  const pageServer = await startPageServer();
  const userDir = fs.mkdtempSync(path.join(os.tmpdir(), 'rph-chrome-'));
  const proc = spawn(
    chromePath,
    [
      '--headless=new',
      '--disable-gpu',
      '--no-sandbox',
      '--disable-dev-shm-usage',
      `--user-data-dir=${userDir}`,
      // Ephemeral port: let Chrome pick a free port and report it on stderr
      // ("DevTools listening on ws://..."). A fixed/random port in a shared
      // range races with concurrent processes (collision -> the loser never
      // binds -> ECONNREFUSED). Port 0 + reading the real port removes both
      // the collision and the connect-before-listen race.
      '--remote-debugging-port=0',
      '--remote-allow-origins=*',
      // Hermetic network: every host name except localhost fails to resolve
      // at once, and no system proxy is consulted. The reader CSS points its
      // fonts at the app's virtual host (https://fushi.local/...), which the
      // harnesses do not serve; on Windows a `.local` name goes to
      // mDNS / LLMNR and took ~27 s to fail, holding every such page's load
      // event that long (VN / highlight suites ran 100+ s, or were evaluated
      // half-loaded). The outcome -- the font request fails -- is unchanged,
      // it just fails in milliseconds (BUG-3779). `MAP *` matches IP literals too, so the
      // loopback the harness servers listen on is excluded explicitly.
      '--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE localhost, EXCLUDE 127.0.0.1',
      '--no-proxy-server',
      '--window-size=1280,800',
      'about:blank',
    ],
    // stderr is piped: it carries the readiness signal and, on failure, the
    // reason Chrome did not come up.
    { stdio: ['ignore', 'ignore', 'pipe'] }
  );
  const stderrLog = captureStderr(proc);
  const attachDeadline = Date.now() + CHROME_ATTACH_HANG_GUARD_MS;
  const attachRemaining = () => Math.max(1, attachDeadline - Date.now());

  let sock;
  try {
    const port = await waitForDevToolsPort(proc, stderrLog, attachRemaining());
    const targets = await getJson(`http://127.0.0.1:${port}/json`);
    const page = targets.find((t) => t.type === 'page');
    if (!page) throw new Error('no page target');
    sock = new CdpSocket(page.webSocketDebuggerUrl);
    await sock.connect();
    // Still part of cold start: these wait for the renderer to come up.
    await sock.send('Page.enable', {}, attachRemaining());
    await sock.send('Runtime.enable', {}, attachRemaining());
  } catch (e) {
    try {
      sock && sock.close();
    } catch (_) {}
    try {
      proc.kill();
    } catch (_) {}
    try {
      proc.stderr.destroy();
    } catch (_) {}
    try {
      fs.rmSync(userDir, { recursive: true, force: true });
    } catch (_) {}
    pageServer.close();
    throw e;
  }

  // Load `html` and wait for its load event. The load event is the readiness
  // signal; the bound is the same hang guard as a CDP command. A page that
  // never finishes loading fails here, naming why -- it used to be evaluated
  // anyway after 8 s, so a slow load surfaced later as an unrelated
  // "X is not defined" / "reading 'length' of undefined" from the harness.
  async function load(html) {
    sock.events.length = 0;
    const url = pageServer.urlFor(html);
    await sock.send('Page.navigate', { url });
    const deadline = Date.now() + CDP_COMMAND_HANG_GUARD_MS;
    while (!sock.events.some((e) => e.method === 'Page.loadEventFired')) {
      if (Date.now() > deadline) {
        throw new Error(`page load event did not fire within ${CDP_COMMAND_HANG_GUARD_MS} ms ` +
          `(${url}, ${html.length} chars, ${pageServer.wasServed(url) ? 'served' : 'never requested'})`);
      }
      await new Promise((r) => setTimeout(r, 20));
    }
  }

  async function evalOnPage(html, expr) {
    await load(html);
    // Give layout one more frame.
    await sock.send('Runtime.evaluate', {
      expression: 'new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)))',
      awaitPromise: true,
    });
    // A Promise result is awaited (cases that must wait for a frame / observer);
    // a plain value resolves unchanged.
    const res = await sock.send('Runtime.evaluate', {
      expression: `Promise.resolve((function(){ return (${expr}); })()).then((v) => JSON.stringify(v))`,
      awaitPromise: true,
      returnByValue: true,
    });
    if (res.exceptionDetails) {
      throw new Error('eval exception: ' + JSON.stringify(res.exceptionDetails));
    }
    return JSON.parse(res.result.value);
  }

  async function snap(html, preExpr, vw, vh) {
    if (vw && vh) {
      await sock.send('Emulation.setDeviceMetricsOverride', { width: vw, height: vh, deviceScaleFactor: 1, mobile: false });
    }
    await load(html);
    if (preExpr) {
      await sock.send('Runtime.evaluate', { expression: preExpr, returnByValue: true });
    }
    await sock.send('Runtime.evaluate', {
      expression: 'new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)))',
      awaitPromise: true,
    });
    const shot = await sock.send('Page.captureScreenshot', { format: 'png' });
    return shot.data;
  }

  // Evaluate on the page evalOnPage last loaded, without navigating.
  async function evalHere(expr) {
    const res = await sock.send('Runtime.evaluate', {
      expression: `Promise.resolve((function(){ return (${expr}); })()).then((v) => JSON.stringify(v))`,
      awaitPromise: true,
      returnByValue: true,
    });
    if (res.exceptionDetails) {
      throw new Error('eval exception: ' + JSON.stringify(res.exceptionDetails));
    }
    return JSON.parse(res.result.value);
  }

  // PNG (base64) of a rect of the current page given in client (getBoundingClientRect)
  // coordinates, at scale 1. The CDP clip is in document coordinates, which differ from
  // client ones whenever the viewport is scrolled — including a vertical-rl document wider
  // than the viewport, whose initial position is its right edge — so add the visual
  // layout viewport's page offset (client rects are relative to it).
  async function capture(clip) {
    const metrics = await sock.send('Page.getLayoutMetrics', {});
    const lv = metrics.cssLayoutViewport || metrics.layoutViewport || { pageX: 0, pageY: 0 };
    const shot = await sock.send('Page.captureScreenshot', {
      format: 'png',
      clip: { x: clip.x + lv.pageX, y: clip.y + lv.pageY, width: clip.width, height: clip.height, scale: 1 },
    });
    return shot.data;
  }

  function close() {
    try {
      sock && sock.close();
    } catch (_) {}
    try {
      proc.kill();
    } catch (_) {}
    try {
      proc.stderr.destroy();
    } catch (_) {}
    try {
      fs.rmSync(userDir, { recursive: true, force: true });
    } catch (_) {}
    pageServer.close();
  }

  return { evalOnPage, evalHere, capture, snap, close };
}
