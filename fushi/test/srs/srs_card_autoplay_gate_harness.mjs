// BUG-3546 follow-up: runs the production SRS card shell (srsCardShellHtml with the
// autoplay gate) in real headless Chrome started with
// --autoplay-policy=no-user-gesture-required — the policy the Windows card face
// (WebView2) effectively has — and checks that every way a card page can make a
// media element play is refused while the deck has autoplay off, that user
// clicks / keys still play, and that nothing is refused while autoplay is on.
// Also: the next card stops every page medium still sounding (N-JACNGS-K) and
// the shell's key bridge beats card-script keydown listeners (OO3O-3ljda).
// Payload is produced by srs_card_autoplay_gate_test.dart.
//
// Exit codes: 0 = all cases passed, 1 = a case failed, 77 = no Chrome.
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { resolveChrome } from '../../../tool/reader_pitch_headless/cdp_client.mjs';

const chromePath = resolveChrome();
if (!chromePath) {
  console.log('Chrome unavailable');
  process.exit(77);
}
const payload = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));

// 2 s, 440 Hz, mono 8 kHz 16-bit PCM WAV as a data: URL (no network, no files).
function toneWav() {
  const rate = 8000;
  const n = rate * 2;
  const buf = Buffer.alloc(44 + n * 2);
  buf.write('RIFF', 0);
  buf.writeUInt32LE(36 + n * 2, 4);
  buf.write('WAVE', 8);
  buf.write('fmt ', 12);
  buf.writeUInt32LE(16, 16);
  buf.writeUInt16LE(1, 20);
  buf.writeUInt16LE(1, 22);
  buf.writeUInt32LE(rate, 24);
  buf.writeUInt32LE(rate * 2, 28);
  buf.writeUInt16LE(2, 32);
  buf.writeUInt16LE(16, 34);
  buf.write('data', 36);
  buf.writeUInt32LE(n * 2, 40);
  for (let i = 0; i < n; i++) {
    buf.writeInt16LE(Math.round(8000 * Math.sin((i * 2 * Math.PI * 440) / rate)), 44 + i * 2);
  }
  return 'data:audio/wav;base64,' + buf.toString('base64');
}
const SRC = toneWav();

function getJson(url) {
  return new Promise((resolve, reject) => {
    http
      .get(url, (res) => {
        let b = '';
        res.on('data', (d) => (b += d));
        res.on('end', () => resolve(JSON.parse(b)));
      })
      .on('error', reject);
  });
}

async function launch() {
  const userDir = fs.mkdtempSync(path.join(os.tmpdir(), 'srs-autoplay-chrome-'));
  const proc = spawn(
    chromePath,
    [
      '--headless=new',
      '--disable-gpu',
      '--no-sandbox',
      '--disable-dev-shm-usage',
      `--user-data-dir=${userDir}`,
      '--remote-debugging-port=0',
      '--remote-allow-origins=*',
      '--window-size=800,600',
      '--autoplay-policy=no-user-gesture-required',
      'about:blank',
    ],
    { stdio: ['ignore', 'ignore', 'pipe'] },
  );
  const port = await new Promise((resolve, reject) => {
    let log = '';
    const timer = setTimeout(() => reject(new Error('Chrome did not start: ' + log)), 30000);
    proc.stderr.on('data', (d) => {
      log += d;
      const m = log.match(/DevTools listening on ws:\/\/[^:]+:(\d+)\//);
      if (m) {
        clearTimeout(timer);
        resolve(m[1]);
      }
    });
    proc.once('exit', (code) => {
      clearTimeout(timer);
      reject(new Error('Chrome exited (' + code + '): ' + log));
    });
  });
  const targets = await getJson(`http://127.0.0.1:${port}/json`);
  const ws = new WebSocket(targets.find((t) => t.type === 'page').webSocketDebuggerUrl);
  await new Promise((resolve, reject) => {
    ws.addEventListener('open', resolve, { once: true });
    ws.addEventListener('error', reject, { once: true });
  });
  let nextId = 0;
  const pending = new Map();
  const events = [];
  ws.addEventListener('message', (m) => {
    const msg = JSON.parse(m.data);
    if (msg.id && pending.has(msg.id)) {
      pending.get(msg.id)(msg);
      pending.delete(msg.id);
    } else {
      events.push(msg);
    }
  });
  const send = (method, params = {}) =>
    new Promise((resolve) => {
      const id = ++nextId;
      pending.set(id, resolve);
      ws.send(JSON.stringify({ id, method, params }));
    });
  await send('Page.enable');
  await send('Runtime.enable');
  return {
    async load(html) {
      events.length = 0;
      await send('Page.navigate', { url: 'data:text/html;charset=utf-8,' + encodeURIComponent(html) });
      const deadline = Date.now() + 8000;
      while (Date.now() < deadline && !events.some((e) => e.method === 'Page.loadEventFired')) {
        await new Promise((r) => setTimeout(r, 20));
      }
    },
    async evaluate(expr) {
      const res = await send('Runtime.evaluate', {
        expression: `Promise.resolve((async () => (${expr}))()).then((v) => JSON.stringify(v))`,
        awaitPromise: true,
        returnByValue: true,
      });
      if (res.result.exceptionDetails) {
        throw new Error('eval exception: ' + JSON.stringify(res.result.exceptionDetails));
      }
      return JSON.parse(res.result.result.value);
    },
    // A real (trusted) click / key press through Chrome's input pipeline.
    async click(x, y) {
      await send('Input.dispatchMouseEvent', { type: 'mouseMoved', x, y });
      for (const type of ['mousePressed', 'mouseReleased']) {
        await send('Input.dispatchMouseEvent', { type, x, y, button: 'left', clickCount: 1 });
      }
    },
    async pressKeyA() {
      for (const type of ['keyDown', 'keyUp']) {
        await send('Input.dispatchKeyEvent', {
          type,
          key: 'a',
          code: 'KeyA',
          windowsVirtualKeyCode: 65,
          text: type === 'keyDown' ? 'a' : undefined,
        });
      }
    },
    async pressSpace() {
      for (const type of ['keyDown', 'keyUp']) {
        await send('Input.dispatchKeyEvent', {
          type,
          key: ' ',
          code: 'Space',
          windowsVirtualKeyCode: 32,
          text: type === 'keyDown' ? ' ' : undefined,
        });
      }
    },
    close() {
      try {
        ws.close();
      } catch (_) {}
      try {
        proc.kill();
      } catch (_) {}
      try {
        fs.rmSync(userDir, { recursive: true, force: true, maxRetries: 3 });
      } catch (_) {}
    },
  };
}

// Every way a card page can start playback by itself. Each body returns the
// media element it started; the harness then waits and reads `paused`.
const PAGE_PATHS = {
  'play() from a canplay-style callback': `const a = new Audio(SRC); host.appendChild(a); a.play().catch(() => {}); return a;`,
  'inserted with the autoplay attribute': `const a = document.createElement('audio'); a.src = SRC; a.autoplay = true; host.appendChild(a); return a;`,
  'el.autoplay = true after insertion': `const a = document.createElement('audio'); a.src = SRC; host.appendChild(a); await tick(); a.autoplay = true; return a;`,
  "setAttribute('autoplay') after insertion": `const a = document.createElement('audio'); a.src = SRC; host.appendChild(a); await tick(); a.setAttribute('autoplay', ''); return a;`,
  "toggleAttribute('autoplay') after insertion": `const a = document.createElement('audio'); a.src = SRC; host.appendChild(a); await tick(); a.toggleAttribute('autoplay'); return a;`,
  'detached new Audio() with autoplay = true': `const a = new Audio(); a.autoplay = true; a.src = SRC; window.__keep = a; return a;`,
  "detached element with setAttribute('autoplay')": `const a = document.createElement('audio'); a.setAttribute('autoplay', ''); a.src = SRC; window.__keep = a; return a;`,
  'autoplay media inside a shadow root': `const h = document.createElement('div'); host.appendChild(h); const s = h.attachShadow({ mode: 'closed' }); s.innerHTML = '<audio autoplay src="' + SRC + '"></audio>'; return s.firstChild;`,
  'play() through another realm (iframe) prototype': `const f = document.createElement('iframe'); host.appendChild(f); const p = f.contentWindow.HTMLMediaElement.prototype.play; const a = new Audio(SRC); host.appendChild(a); try { p.call(a).catch(() => {}); } catch (_) {} return a;`,
  // Native controls are only trusted together with a live user activation.
  'another-realm play() on <audio controls> without a user gesture': `const f = document.createElement('iframe'); host.appendChild(f); const p = f.contentWindow.HTMLMediaElement.prototype.play; const a = new Audio(SRC); a.controls = true; host.appendChild(a); try { p.call(a).catch(() => {}); } catch (_) {} return a;`,
  'setAttribute through another realm (iframe) prototype': `const f = document.createElement('iframe'); host.appendChild(f); const set = f.contentWindow.Element.prototype.setAttribute; const a = document.createElement('audio'); a.src = SRC; host.appendChild(a); await tick(); set.call(a, 'autoplay', ''); return a;`,
};

const PRELUDE = `
  const SRC = ${JSON.stringify(SRC)};
  const tick = () => new Promise((r) => setTimeout(r, 0));
  const settle = () => new Promise((r) => setTimeout(r, 700));
  const host = document.createElement('div');
  host.style.cssText = 'position:fixed;left:0;top:0;width:400px;height:200px;z-index:9';
  document.body.appendChild(host);
`;

const driver = await launch();
const failures = [];
let passed = 0;
function check(ok, label) {
  if (ok) passed++;
  else failures.push(label);
}

async function runPagePath(name, body, autoplayOn) {
  await driver.load(payload.shell);
  return driver.evaluate(`(async () => {
    ${autoplayOn ? payload.on : payload.off}
    ${PRELUDE}
    const el = await (async () => { ${body} })();
    await settle();
    return { paused: el.paused, time: el.currentTime };
  })()`);
}

try {
  for (const [name, body] of Object.entries(PAGE_PATHS)) {
    // Autoplay on: the same path really plays here (proves the Chrome policy
    // lets page media play without a gesture, so the "off" case is not hollow).
    const on = await runPagePath(name, body, true);
    check(on.paused === false, `on: ${name} should play, got ${JSON.stringify(on)}`);
    const off = await runPagePath(name, body, false);
    check(off.paused === true && off.time === 0, `off: ${name} must stay silent, got ${JSON.stringify(off)}`);
  }

  // Autoplay off: a user click whose handler calls play() plays; a timer
  // play() after that click does not.
  await driver.load(payload.shell);
  await driver.evaluate(`(async () => {
    ${payload.off}
    ${PRELUDE}
    const a = new Audio(SRC); host.appendChild(a); window.__a = a;
    const b = document.createElement('button'); b.textContent = 'play';
    b.style.cssText = 'position:absolute;left:0;top:0;width:120px;height:40px';
    b.onclick = () => { a.play().catch(() => {}); };
    host.appendChild(b); b.focus();
    window.__b = b;
    return true;
  })()`);
  await driver.click(40, 20);
  const clicked = await driver.evaluate(`(async () => { await new Promise((r) => setTimeout(r, 700)); return { paused: __a.paused }; })()`);
  check(clicked.paused === false, `off: user click -> play() must play, got ${JSON.stringify(clicked)}`);
  const later = await driver.evaluate(`(async () => {
    const a2 = new Audio(${JSON.stringify(SRC)}); document.body.appendChild(a2);
    let refused = null;
    await a2.play().then(() => { refused = false; }, (e) => { refused = e.name; });
    return { refused, paused: a2.paused };
  })()`);
  check(later.refused === 'NotAllowedError' && later.paused === true, `off: play() after the click dispatch is refused, got ${JSON.stringify(later)}`);

  // Autoplay off: a key press handled by the card's own script (keyboard
  // user) plays. Not Enter / Space: the shell's key bridge owns those (they
  // flip / rate the card and never reach the page).
  await driver.load(payload.shell);
  await driver.evaluate(`(async () => {
    ${payload.off}
    ${PRELUDE}
    const a = new Audio(SRC); host.appendChild(a); window.__a = a;
    const b = document.createElement('button'); b.textContent = 'play';
    b.onkeydown = (e) => { if (e.key === 'a') a.play().catch(() => {}); };
    host.appendChild(b); b.focus();
    return document.activeElement === b;
  })()`);
  await driver.pressKeyA();
  const keyed = await driver.evaluate(`(async () => { await new Promise((r) => setTimeout(r, 700)); return { paused: __a.paused }; })()`);
  check(keyed.paused === false, `off: key press -> play() must play, got ${JSON.stringify(keyed)}`);

  // Autoplay off: the native play button of <audio controls> (no page play()
  // call; the play event arrives after the gesture flag is reset).
  await driver.load(payload.shell);
  const box = await driver.evaluate(`(async () => {
    ${payload.off}
    ${PRELUDE}
    const a = document.createElement('audio'); a.controls = true; a.src = SRC;
    a.style.cssText = 'position:absolute;left:0;top:0;width:300px;height:54px';
    host.appendChild(a); window.__a = a;
    await new Promise((r) => { if (a.readyState >= 1) r(); else a.addEventListener('loadedmetadata', r, { once: true }); });
    await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
    const rect = a.getBoundingClientRect();
    return { x: rect.left, y: rect.top, h: rect.height };
  })()`);
  await driver.click(box.x + 22, box.y + box.h / 2);
  const native = await driver.evaluate(`(async () => { await new Promise((r) => setTimeout(r, 700)); return { paused: __a.paused }; })()`);
  check(native.paused === false, `off: native controls play button must play, got ${JSON.stringify(native)}`);

  // N-JACNGS-K: the next card (or the flip) stops every page medium still
  // sounding — also ones the content swap cannot reach (a detached
  // new Audio(), a shadow root), not only <audio> under the card root.
  await driver.load(payload.shell);
  const swapped = await driver.evaluate(`(async () => {
    ${payload.on}
    ${PRELUDE}
    const inDoc = new Audio(SRC); document.getElementById('fushi-card-root').appendChild(inDoc);
    const detached = new Audio(SRC); window.__keep = detached;
    const h = document.createElement('div'); document.getElementById('fushi-card-root').appendChild(h);
    const s = h.attachShadow({ mode: 'closed' }); s.innerHTML = '<audio src="' + SRC + '"></audio>';
    const shadowed = s.firstChild;
    for (const m of [inDoc, detached, shadowed]) m.play().catch(() => {});
    await settle();
    const before = [inDoc, detached, shadowed].map((m) => m.paused);
    ${payload.next}
    await settle();
    return { before, after: [inDoc, detached, shadowed].map((m) => m.paused) };
  })()`);
  check(
    JSON.stringify(swapped.before) === '[false,false,false]' &&
      JSON.stringify(swapped.after) === '[true,true,true]',
    `next card must stop all page media, got ${JSON.stringify(swapped)}`,
  );

  // OO3O-3ljda: the shell's key bridge (installed in <head>, before any card
  // content) hands Space back to the host even when the card template's own
  // script hooks keydown on window capture and stops propagation.
  await driver.load(payload.shell);
  await driver.evaluate(`(async () => {
    window.__calls = [];
    window.flutter_inappwebview = { callHandler: (n, a) => { window.__calls.push([n, a]); } };
    ${payload.on}
    window.addEventListener('keydown', (e) => { e.stopImmediatePropagation(); e.stopPropagation(); }, true);
    document.addEventListener('keydown', (e) => { e.stopPropagation(); }, true);
    return true;
  })()`);
  await driver.pressSpace();
  const bridged = await driver.evaluate(`(async () => { await new Promise((r) => setTimeout(r, 100)); return window.__calls; })()`);
  check(
    bridged.some((c) => c[0] === 'onSrsReviewKey' && c[1] === 'Space'),
    `Space must reach the host bridge despite card script listeners, got ${JSON.stringify(bridged)}`,
  );
} finally {
  driver.close();
}

if (failures.length) {
  for (const f of failures) console.log('FAIL ' + f);
  process.exitCode = 1;
} else {
  console.log('PASS ' + passed + ' browser checks');
}
