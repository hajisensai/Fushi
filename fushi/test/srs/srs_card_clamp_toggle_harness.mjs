// Runs the production SRS card shell with the built-in Fushi card's definitions page
// (narrow hybrid review layout, long main definition) in real headless Chrome and checks
// the "Show more" row under a clamped main definition: a plain text row spanning the full
// definitions width (no fill, no pill), clickable end to end, reachable with Tab and
// triggered with Enter, with a light highlight on hover / press, on a transparent page.
// Cases arrive on stdin from srs_card_clamp_toggle_test.dart.
// Exit codes: 0 = all cases passed, 1 = a case failed, 77 = no Chrome.
import fs from 'node:fs';
import path from 'node:path';
import { launchChromeDriver, resolveChrome } from '../../../tool/reader_pitch_headless/cdp_client.mjs';

if (!resolveChrome()) {
  console.log('Chrome unavailable');
  process.exit(77);
}
const { cases, shotDir } = JSON.parse(fs.readFileSync(0, 'utf8'));

const driver = await launchChromeDriver();
const send = driver.send;
const frame = 'new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)))';
const TRANSPARENT = 'rgba(0, 0, 0, 0)';

async function open(page, dpr = 1) {
  await send('Emulation.setDeviceMetricsOverride', {
    width: 390,
    height: 844,
    deviceScaleFactor: dpr,
    mobile: false,
  });
  return driver.evalOnPage(page.shell, `(async () => {
    ${page.calls}
    await ${frame};
    const btn = document.querySelector('.fc-clamp-toggle');
    if (!btn) return null;
    btn.scrollIntoView({ block: 'center' });
    await ${frame};
    const r = btn.getBoundingClientRect();
    return { x: r.left, y: r.top, w: r.width, h: r.height };
  })()`);
}

const state = `(() => {
  const main = document.querySelector('.fc-gloss--main');
  const btn = document.querySelector('.fc-clamp-toggle');
  return { unclamped: main.classList.contains('fc-gloss--unclamped'), hidden: btn.hidden };
})()`;

async function key(k, code, vk) {
  for (const type of ['keyDown', 'keyUp']) {
    await send('Input.dispatchKeyEvent', {
      type,
      key: k,
      code,
      windowsVirtualKeyCode: vk,
      text: type === 'keyDown' && k === 'Enter' ? '\r' : undefined,
    });
  }
}

async function click(x, y) {
  await send('Input.dispatchMouseEvent', { type: 'mouseMoved', x, y });
  for (const type of ['mousePressed', 'mouseReleased']) {
    await send('Input.dispatchMouseEvent', { type, x, y, button: 'left', clickCount: 1 });
  }
}

let passed = 0;
try {
  for (const [name, page] of Object.entries(cases)) {
    const fails = [];
    const check = (ok, label) => { if (!ok) fails.push(label); };

    // 1. Shape: plain text row, full width, ≥48px, transparent all the way up.
    const rect = await open(page);
    check(rect, 'show-more row rendered for a clamped main definition');
    if (rect) {
      const shape = await driver.evalHere(`(() => {
        const btn = document.querySelector('.fc-clamp-toggle');
        const main = document.querySelector('.fc-gloss--main');
        const cs = getComputedStyle(btn);
        const r = btn.getBoundingClientRect();
        const m = main.getBoundingClientRect();
        const opaque = [];
        for (let el = btn.parentElement; el; el = el.parentElement) {
          const bg = getComputedStyle(el).backgroundColor;
          if (bg !== ${JSON.stringify(TRANSPARENT)}) opaque.push(el.tagName + '.' + el.className + ' ' + bg);
        }
        return {
          tag: btn.tagName,
          hidden: btn.hidden,
          bg: cs.backgroundColor,
          image: cs.backgroundImage,
          border: cs.borderTopWidth,
          radius: parseFloat(cs.borderTopLeftRadius),
          w: r.width, h: r.height, mainW: m.width, mainL: m.left, l: r.left,
          label: getComputedStyle(btn, '::before').content,
          chevron: getComputedStyle(btn, '::after').borderBottomWidth,
          opaque,
        };
      })()`);
      check(shape.tag === 'BUTTON', 'native button (keyboard / gamepad focusable): ' + shape.tag);
      check(!shape.hidden, 'row shown while the main definition is clamped');
      check(shape.bg === TRANSPARENT && shape.image === 'none', 'no fill at rest: ' + shape.bg + ' ' + shape.image);
      check(shape.border === '0px', 'no outline border: ' + shape.border);
      check(shape.radius < shape.h / 2 - 4, 'not a pill: radius ' + shape.radius + ' h ' + shape.h);
      check(shape.h >= 48, 'hit height >= 48: ' + shape.h);
      check(Math.abs(shape.w - shape.mainW) < 1 && Math.abs(shape.l - shape.mainL) < 1,
        'spans the definition width: ' + shape.w + ' vs ' + shape.mainW);
      check(shape.label.includes(page.label), 'label ' + shape.label);
      check(shape.chevron === '2px', 'down chevron');
      check(shape.opaque.length === 0, 'transparent around the row: ' + shape.opaque.join(' | '));

      // 2. Hover / press feedback: a light accent highlight, still no pill.
      const cx = rect.x + rect.w / 2;
      const cy = rect.y + rect.h / 2;
      await send('Input.dispatchMouseEvent', { type: 'mouseMoved', x: cx, y: cy });
      await send('Input.dispatchMouseEvent', { type: 'mousePressed', x: cx, y: cy, button: 'left', clickCount: 1 });
      await new Promise((r) => setTimeout(r, 300));
      const pressedBg = await driver.evalHere(`getComputedStyle(document.querySelector('.fc-clamp-toggle')).backgroundColor`);
      check(pressedBg !== TRANSPARENT, 'press highlight: ' + pressedBg);
      // Release off the row so this press does not expand.
      await send('Input.dispatchMouseEvent', { type: 'mouseMoved', x: 2, y: 2, button: 'left' });
      await send('Input.dispatchMouseEvent', { type: 'mouseReleased', x: 2, y: 2, button: 'left', clickCount: 1 });
      check(!(await driver.evalHere(state)).unclamped, 'press released elsewhere does not expand');

      // 3. Whole row clickable: a real click at the far right end (where the pill had nothing).
      await click(rect.x + rect.w - 6, rect.y + rect.h / 2);
      await driver.evalHere(frame);
      const afterClick = await driver.evalHere(state);
      check(afterClick.unclamped && afterClick.hidden, 'click at right end expands: ' + JSON.stringify(afterClick));
    }

    // 4. Keyboard: Tab reaches the row, Enter expands.
    if (await open(page)) {
      // A control focused by a mouse click (not :focus-visible) does not take Enter: the
      // card's key bridge still forwards it to the host (flip / rate).
      const sum = await driver.evalHere(`(() => {
        window.__docSaw = 0;
        document.addEventListener('keydown', (e) => { if (e.code === 'Enter') window.__docSaw++; }, true);
        const s = document.querySelector('.fc-dict > summary, .fc-more > summary');
        if (!s) return null;
        s.scrollIntoView({ block: 'center' });
        const r = s.getBoundingClientRect();
        return { x: r.left + 8, y: r.top + r.height / 2 };
      })()`);
      if (sum) {
        await click(sum.x, sum.y);
        await key('Enter', 'Enter', 13);
        const bridged = await driver.evalHere(`window.__docSaw === 0`);
        check(bridged, 'Enter after a mouse click on a control still goes to the host bridge');
      }
      await driver.evalHere(`(document.activeElement && document.activeElement.blur(), window.focus(), true)`);
      let focused = false;
      for (let i = 0; i < 40 && !focused; i++) {
        await key('Tab', 'Tab', 9);
        focused = await driver.evalHere(`document.activeElement === document.querySelector('.fc-clamp-toggle')`);
      }
      check(focused, 'Tab reaches the row');
      const ring = await driver.evalHere(`getComputedStyle(document.querySelector('.fc-clamp-toggle')).outlineStyle`);
      check(ring !== 'none', 'keyboard focus ring: ' + ring);
      await key('Enter', 'Enter', 13);
      await driver.evalHere(frame);
      const afterEnter = await driver.evalHere(state);
      check(afterEnter.unclamped && afterEnter.hidden, 'Enter expands: ' + JSON.stringify(afterEnter));
    }

    // Pixel evidence (only when asked): the clamped tail + row at phone width, 2x.
    if (shotDir) {
      // Standalone page (same shell + host calls) for WebKit evidence on a Mac / iOS simulator.
      fs.mkdirSync(shotDir, { recursive: true });
      // The host calls go in their own file: inline they could contain `</script>`.
      fs.writeFileSync(path.join(shotDir, `expand_calls_${name}.js`), page.calls +
        '\n;setTimeout(function(){var b=document.querySelector(".fc-clamp-toggle");' +
        'if(b)b.scrollIntoView({block:"center"});},300);');
      fs.writeFileSync(path.join(shotDir, `expand_page_${name}.html`), page.shell
        .replace('<head>', '<head><meta name="viewport" content="width=device-width,initial-scale=1">') +
        `<script src="expand_calls_${name}.js"></script>`);
      const r = await open(page, 2);
      if (r) {
        const png = await driver.capture({ x: 0, y: Math.max(0, r.y - 220), width: 390, height: r.h + 300 });
        fs.mkdirSync(shotDir, { recursive: true });
        fs.writeFileSync(path.join(shotDir, `expand_chromium_${name}.png`), Buffer.from(png, 'base64'));
      }
    }

    if (fails.length) {
      console.log('FAIL ' + name + ': ' + fails.join('; '));
      process.exitCode = 1;
    } else {
      passed++;
    }
  }
} finally {
  driver.close();
}
if (!process.exitCode) console.log('PASS ' + passed + ' browser cases');
