// Fushi Lens: a frozen game frame, its OCR lines, a character cursor, and the
// shared Fushi dictionary popup (the browser extension's nested-popup.html,
// copied in at build time, so lookups look and mine exactly like everywhere
// else in Fushi).
//
// This page is served by the plugin backend on 127.0.0.1 under a secret path.
// Everything it needs from the paired Fushi host goes through that backend
// (`../api/...`); the page never sees the host's address, certificate or token.
//
// Input: keyboard (testing in a desktop browser) or messages from the Decky
// frontend that embeds this page: {fushiLens: 'button', button: 'UP' | ...}.
(function () {
  'use strict';

  const ROOT = new URL('../', location.href); // .../s/<secret>/
  const MEDIA_BASE = ROOT.href.replace(/\/$/, ''); // dict-media builds `${base}/api/media/...`

  const frameImg = document.getElementById('frame');
  const boxesEl = document.getElementById('boxes');
  const statusEl = document.getElementById('status');
  const popupBox = document.getElementById('popup-box');
  const popupFrame = document.getElementById('popup');

  const state = {
    frameId: null,
    width: 0,
    height: 0,
    lines: [],
    line: 0,
    cursor: 0,
    matchLength: 0,
    popupOpen: false,
    lookupSeq: 0,
    screenshot: null, // base64 of the frame, built lazily for mining
  };

  // Popup CSS is sent once per revision (BUG-1718 contract), like background.js.
  let popupCss = { revision: '', body: null };
  // Host audio URLs are rewritten to go through the backend; mining must send
  // the host's own URL back so it can resolve its short-lived audio token.
  const audioOriginals = new Map();

  // ── helpers ──────────────────────────────────────────────────────────

  async function postJson(path, payload) {
    const res = await fetch(new URL(path, ROOT), {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload || {}),
    });
    let data = null;
    try { data = await res.json(); } catch (_) { /* non-JSON error body */ }
    return { ok: res.ok, status: res.status, data };
  }

  let statusTimer = 0;
  function showStatus(text, sticky) {
    statusEl.textContent = text;
    statusEl.classList.toggle('shown', !!text);
    clearTimeout(statusTimer);
    if (text && !sticky) statusTimer = setTimeout(() => statusEl.classList.remove('shown'), 2200);
  }

  function errorText(res) {
    const reason = res && res.data && res.data.error;
    if (reason === 'unpaired' || reason === 'unauthorized') return 'Not paired with Fushi. Pair in the Fushi Lens panel.';
    if (reason === 'unreachable') return 'Cannot reach your Fushi app.';
    if (reason === 'no_screen_ocr') return 'Your Fushi app is too old for screen OCR.';
    if (reason === 'ocr_unavailable') return 'Download the OCR models in Fushi first.';
    if (reason === 'lens_consent') return 'Allow Google Lens in Fushi on your PC, then try again.';
    if (reason === 'engine_failed') return "Google Lens failed. Check your PC's internet connection.";
    if (reason === 'tls') return 'Fushi\'s certificate changed. Pair again.';
    return 'Something went wrong' + (res && res.status ? ` (${res.status})` : '') + '.';
  }

  function localAudioUrl(hostUrl) {
    try {
      const u = new URL(hostUrl);
      if (u.pathname !== '/api/lookup/audio/file') return hostUrl;
      const local = new URL('api/lookup/audio/file' + u.search, ROOT).href;
      audioOriginals.set(local, hostUrl);
      return local;
    } catch (_) {
      return hostUrl;
    }
  }

  function restoreAudioUrls(value) {
    if (typeof value === 'string') return audioOriginals.get(value) || value;
    if (Array.isArray(value)) return value.map(restoreAudioUrls);
    if (value && typeof value === 'object') {
      const out = {};
      for (const [k, v] of Object.entries(value)) out[k] = restoreAudioUrls(v);
      return out;
    }
    return value;
  }

  // ── geometry ─────────────────────────────────────────────────────────

  function viewTransform() {
    const vw = window.innerWidth;
    const vh = window.innerHeight;
    if (!state.width || !state.height) return { scale: 1, ox: 0, oy: 0 };
    const scale = Math.min(vw / state.width, vh / state.height);
    return {
      scale,
      ox: (vw - state.width * scale) / 2,
      oy: (vh - state.height * scale) / 2,
    };
  }

  function toView(rect) {
    const t = viewTransform();
    return {
      left: t.ox + rect.left * t.scale,
      top: t.oy + rect.top * t.scale,
      width: (rect.right - rect.left) * t.scale,
      height: (rect.bottom - rect.top) * t.scale,
    };
  }

  // Rect of characters [start, end) of a line, in frame pixels. Uses the OCR
  // glyph boxes when present, otherwise splits the line box evenly.
  function spanRect(line, start, end) {
    const text = line.text;
    const glyphs = Array.isArray(line.glyphs) ? line.glyphs : null;
    if (glyphs && glyphs.length) {
      const hits = glyphs.filter((g) => g.end > start && g.start < end);
      if (hits.length) {
        return {
          left: Math.min(...hits.map((g) => g.rect.left)),
          top: Math.min(...hits.map((g) => g.rect.top)),
          right: Math.max(...hits.map((g) => g.rect.right)),
          bottom: Math.max(...hits.map((g) => g.rect.bottom)),
        };
      }
    }
    const b = line.box;
    const n = Math.max(1, Array.from(text).length);
    const vertical = (b.bottom - b.top) > (b.right - b.left) * 1.5;
    if (vertical) {
      const step = (b.bottom - b.top) / n;
      return { left: b.left, right: b.right, top: b.top + step * start, bottom: b.top + step * end };
    }
    const step = (b.right - b.left) / n;
    return { top: b.top, bottom: b.bottom, left: b.left + step * start, right: b.left + step * end };
  }

  // Cursor positions are code-unit offsets (what the host's glyph start/end
  // use), stepped by whole code points.
  function nextOffset(text, i, dir) {
    if (dir > 0) {
      const cp = text.codePointAt(i);
      return Math.min(text.length - 1, i + (cp > 0xffff ? 2 : 1));
    }
    if (i <= 0) return 0;
    const prev = text.charCodeAt(i - 1);
    return i - ((prev >= 0xdc00 && prev <= 0xdfff && i >= 2) ? 2 : 1);
  }

  // ── drawing ──────────────────────────────────────────────────────────

  function draw() {
    boxesEl.style.left = '0px';
    boxesEl.style.top = '0px';
    boxesEl.style.width = window.innerWidth + 'px';
    boxesEl.style.height = window.innerHeight + 'px';
    boxesEl.textContent = '';
    state.lines.forEach((line, i) => {
      const r = toView(line.box);
      const el = document.createElement('div');
      el.className = 'line' + (i === state.line ? ' current' : '');
      Object.assign(el.style, {
        left: r.left - 3 + 'px', top: r.top - 3 + 'px',
        width: r.width + 6 + 'px', height: r.height + 6 + 'px',
      });
      boxesEl.appendChild(el);
    });
    const line = state.lines[state.line];
    if (!line) return;
    if (state.matchLength > 1) {
      const m = toView(spanRect(line, state.cursor, state.cursor + state.matchLength));
      boxesEl.appendChild(glyphEl(m, 'glyph match'));
    }
    const end = nextOffset(line.text, state.cursor, 1);
    const c = toView(spanRect(line, state.cursor, end > state.cursor ? end : state.cursor + 1));
    boxesEl.appendChild(glyphEl(c, 'glyph'));
  }

  function glyphEl(r, cls) {
    const el = document.createElement('div');
    el.className = cls;
    Object.assign(el.style, {
      left: r.left - 1 + 'px', top: r.top - 1 + 'px',
      width: r.width + 2 + 'px', height: r.height + 2 + 'px',
    });
    return el;
  }

  function placePopup() {
    const line = state.lines[state.line];
    if (!line) return;
    const vw = window.innerWidth;
    const vh = window.innerHeight;
    const r = toView(spanRect(line, state.cursor, state.cursor + Math.max(1, state.matchLength)));
    const width = Math.min(620, vw - 24);
    const below = r.top + r.height / 2 < vh / 2;
    const room = below ? vh - (r.top + r.height) - 18 : r.top - 18;
    const height = Math.max(180, Math.min(vh * 0.62, room));
    const left = Math.max(12, Math.min(vw - width - 12, r.left + r.width / 2 - width / 2));
    const top = below
      ? Math.min(vh - height - 8, r.top + r.height + 10)
      : Math.max(8, r.top - height - 10);
    Object.assign(popupBox.style, {
      left: left + 'px', top: top + 'px', width: width + 'px', height: height + 'px',
    });
  }

  // ── popup bridge (nested-popup.html protocol) ────────────────────────

  let popupPort = null;
  let popupReady = false;
  let pendingRender = null;

  function sendPopup(message) {
    if (popupPort) popupPort.postMessage({ __fushiPopupFrame: true, ...message });
  }

  window.addEventListener('message', (event) => {
    const msg = event.data;
    if (event.source === popupFrame.contentWindow) {
      if (!msg || msg.__fushiPopupFrame !== true || msg.type !== 'ready') return;
      // Same origin: give the popup the media base through the backend proxy.
      // The token is a placeholder; the backend authenticates for real.
      try { popupFrame.contentWindow.__fushiDictMedia = { base: MEDIA_BASE, token: 'lens' }; } catch (_) {}
      const channel = new MessageChannel();
      popupPort = channel.port1;
      popupPort.onmessage = (e) => onPopupMessage(e.data);
      popupPort.start();
      popupFrame.contentWindow.postMessage({ __fushiPopupFrame: true, type: 'connect' }, location.origin, [channel.port2]);
      popupReady = true;
      if (pendingRender) { sendPopup({ type: 'render', data: pendingRender }); pendingRender = null; }
      return;
    }
    if (event.source === window.parent && msg && msg.fushiLens === 'button') onButton(String(msg.button || ''));
    if (event.source === window.parent && msg && msg.fushiLens === 'frame') loadFrame(String(msg.frameId || ''));
  });

  function onPopupMessage(msg) {
    if (!msg || msg.__fushiPopupFrame !== true) return;
    if (msg.type === 'close') { closePopup(); return; }
    if (msg.type !== 'call') return;
    Promise.resolve()
      .then(() => handleCall(msg.name, Array.isArray(msg.args) ? msg.args : []))
      .then(
        (result) => sendPopup({ type: 'reply', id: msg.id, result: result === undefined ? null : result }),
        (error) => sendPopup({ type: 'reply', id: msg.id, error: String(error && error.message || error) }),
      );
  }

  async function handleCall(name, args) {
    const a = args[0] || {};
    switch (name) {
      case 'mineEntry':
        return mine(a);
      case 'duplicateCheck': {
        const r = await postJson('api/duplicate', { expression: a.expression || '', reading: a.reading || '' });
        return !!(r.ok && r.data && r.data.duplicate === true);
      }
      case 'srsTermStatus': {
        const r = await postJson('api/srs/term-status', { expression: a.expression || '', reading: a.reading || '' });
        const s = r.ok && r.data ? r.data.status : null;
        return s && typeof s === 'object' ? s : null;
      }
      case 'srsTermStatusBatch': {
        const terms = Array.isArray(a.terms) ? a.terms : [];
        const r = await postJson('api/srs/term-status-batch', {
          terms: terms.map((t) => ({ expression: (t && t.expression) || '', reading: (t && t.reading) || '' })),
        });
        const list = r.ok && r.data ? r.data.statuses : null;
        if (r.status === 404) return { statuses: terms.map(() => null) };
        return Array.isArray(list) && list.length === terms.length ? { statuses: list } : null;
      }
      case 'resolveWordAudio': {
        const r = await postJson('api/lookup/audio', { expression: a.expression || '', reading: a.reading || '' });
        return r.ok && r.data && r.data.url ? localAudioUrl(r.data.url) : null;
      }
      case 'listWordAudioSources': {
        const r = await postJson('api/lookup/audio/list', { expression: a.expression || '', reading: a.reading || '' });
        const list = r.ok && r.data && Array.isArray(r.data.audioSources) ? r.data.audioSources : [];
        return list.map((s) => ({ ...s, url: s && s.url ? localAudioUrl(s.url) : s.url }));
      }
      case 'tapOutside':
        closePopup();
        return null;
      default:
        // popupRendered, textSelected, openLink, sentence drafts, favourites,
        // getDictAsset (scripted entries) ...: not offered in the Lens yet.
        return null;
    }
  }

  async function frameBase64() {
    if (state.screenshot) return state.screenshot;
    const blob = await (await fetch(new URL(`frame/${state.frameId}.jpg`, ROOT))).blob();
    const dataUrl = await new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = () => resolve(String(reader.result));
      reader.onerror = () => reject(reader.error);
      reader.readAsDataURL(blob);
    });
    state.screenshot = dataUrl.slice(dataUrl.indexOf(',') + 1);
    return state.screenshot;
  }

  async function mine(fields) {
    const line = state.lines[state.line];
    let screenshotBase64 = null;
    try { screenshotBase64 = await frameBase64(); } catch (_) { /* mine without picture */ }
    const r = await postJson('api/mine', {
      fields: restoreAudioUrls(fields),
      sentence: line ? line.text : '',
      ...(screenshotBase64 ? { screenshotBase64 } : {}),
    });
    const result = r.ok && r.data ? r.data.result : null;
    if (result === 'success') showStatus('✓ Card added' + (r.data.deckName ? ` to ${r.data.deckName}` : ''));
    else showStatus('✗ ' + ((r.data && (r.data.message || r.data.detail)) || errorText(r)), false);
    return {
      ankiConnect: result === 'success',
      noteId: null,
      message: r.data && typeof r.data.message === 'string' ? r.data.message : '',
      duplicate: result === 'duplicate',
    };
  }

  // ── lookup ───────────────────────────────────────────────────────────

  function mergePopupCss(data) {
    const revision = typeof data.dictionaryStylesRevision === 'string' ? data.dictionaryStylesRevision : null;
    if (revision === null) return data;
    if (data.dictionaryStyles && typeof data.dictionaryStyles === 'object') {
      popupCss = {
        revision,
        body: {
          dictionaryStyles: data.dictionaryStyles,
          globalDictCSS: data.globalDictCSS || '',
          customDictCSS: data.customDictCSS || {},
          dictionaryDisplayNames: data.dictionaryDisplayNames || {},
          dictionaryFontFaces: data.dictionaryFontFaces || [],
          dictionaryFontCss: data.dictionaryFontCss || '',
          dictionaryLanguages: data.dictionaryLanguages || {},
        },
      };
    } else if (popupCss.revision !== revision) {
      popupCss = { revision, body: null };
    }
    return popupCss.body ? { ...data, ...popupCss.body } : data;
  }

  async function lookup() {
    const line = state.lines[state.line];
    if (!line) return;
    const seq = ++state.lookupSeq;
    const term = line.text.slice(state.cursor);
    const r = await postJson('api/lookup/dictionary', {
      term,
      popupOnly: true,
      stylesRevision: popupCss.revision,
      colorScheme: 'dark',
    });
    if (seq !== state.lookupSeq) return; // a newer lookup won
    if (r.status === 404) { showStatus('Dictionary lookup is off on this Fushi host.'); return; }
    if (!r.ok || !r.data) { showStatus(errorText(r)); return; }
    const data = mergePopupCss(r.data);
    const best = data.result && Number.isInteger(data.result.bestLength) ? data.result.bestLength : 0;
    state.matchLength = best;
    draw();
    if (typeof data.popupJson !== 'string' || best <= 0) {
      closePopup(true);
      showStatus('No dictionary entry here.');
      return;
    }
    if (Array.isArray(data.audioSources)) {
      data.audioSources = data.audioSources.map((s) => (s && s.url ? { ...s, url: localAudioUrl(s.url) } : s));
    }
    data.glassBackdrop = false;
    placePopup();
    if (popupReady) sendPopup({ type: 'render', data });
    else pendingRender = data;
    popupBox.hidden = false;
    state.popupOpen = true;
  }

  function closePopup(keepMatch) {
    state.lookupSeq++;
    popupBox.hidden = true;
    state.popupOpen = false;
    if (!keepMatch) { state.matchLength = 0; draw(); }
  }

  function scrollPopup(dy) {
    try {
      const root = popupFrame.contentDocument.getElementById('fushi-nested-root');
      root.scrollBy({ top: dy, behavior: 'smooth' });
    } catch (_) { /* not loaded yet */ }
  }

  // ── navigation ───────────────────────────────────────────────────────

  function moveLine(dir) {
    if (!state.lines.length) return;
    state.line = (state.line + dir + state.lines.length) % state.lines.length;
    state.cursor = 0;
    state.matchLength = 0;
    draw();
  }

  function moveCursor(dir) {
    const line = state.lines[state.line];
    if (!line) return;
    const next = nextOffset(line.text, state.cursor, dir);
    if (next === state.cursor) return;
    state.cursor = next;
    state.matchLength = 0;
    draw();
    if (state.popupOpen) lookupSoon();
  }

  let lookupTimer = 0;
  function lookupSoon() {
    clearTimeout(lookupTimer);
    lookupTimer = setTimeout(lookup, 110);
  }

  function exit() {
    closePopup();
    if (window.parent !== window) window.parent.postMessage({ fushiLens: 'exit' }, '*');
  }

  function onButton(button) {
    switch (button) {
      case 'UP': if (state.popupOpen) scrollPopup(-140); else moveLine(-1); break;
      case 'DOWN': if (state.popupOpen) scrollPopup(140); else moveLine(1); break;
      case 'LEFT': moveCursor(-1); break;
      case 'RIGHT': moveCursor(1); break;
      case 'LB': moveLine(-1); if (state.popupOpen) lookupSoon(); break;
      case 'RB': moveLine(1); if (state.popupOpen) lookupSoon(); break;
      case 'A': if (state.popupOpen) closePopup(); else lookup(); break;
      case 'X': if (state.popupOpen) sendPopup({ type: 'mine', entryIndex: 0 }); break;
      case 'B': if (state.popupOpen) closePopup(); else exit(); break;
      default: break;
    }
  }

  const KEYS = {
    ArrowUp: 'UP', ArrowDown: 'DOWN', ArrowLeft: 'LEFT', ArrowRight: 'RIGHT',
    Enter: 'A', ' ': 'A', Escape: 'B', Backspace: 'B', x: 'X', m: 'X',
    PageUp: 'LB', PageDown: 'RB', '[': 'LB', ']': 'RB',
  };
  document.addEventListener('keydown', (e) => {
    const button = KEYS[e.key];
    if (!button) return;
    e.preventDefault();
    onButton(button);
  });

  window.addEventListener('resize', () => { draw(); if (state.popupOpen) placePopup(); });

  // ── frame + OCR ──────────────────────────────────────────────────────

  async function loadFrame(frameId) {
    if (!frameId) return;
    closePopup();
    Object.assign(state, {
      frameId, lines: [], line: 0, cursor: 0, matchLength: 0, screenshot: null,
    });
    draw();
    frameImg.src = new URL(`frame/${frameId}.jpg`, ROOT).href;
    showStatus('Reading text…', true);
    const started = performance.now();
    const r = await postJson('ocr', { frameId });
    if (state.frameId !== frameId) return;
    if (!r.ok || !r.data) { showStatus(errorText(r), true); return; }
    state.width = r.data.width;
    state.height = r.data.height;
    state.lines = (r.data.lines || []).filter((l) => l && typeof l.text === 'string' && l.text.trim());
    // Start on the lowest line: in most games that is the dialogue box.
    state.line = state.lines.reduce((best, l, i, all) => (l.box.bottom > all[best].box.bottom ? i : best), 0);
    draw();
    const ms = Math.round(performance.now() - started);
    showStatus(state.lines.length ? `${state.lines.length} lines · ${ms} ms` : 'No text found on screen.');
  }

  async function start() {
    const hash = new URLSearchParams(location.hash.slice(1));
    let frameId = hash.get('frame');
    if (!frameId && window.parent === window) {
      // Opened directly (desktop testing): capture now.
      const r = await postJson('capture');
      if (!r.ok) { showStatus(errorText(r), true); return; }
      frameId = r.data.frameId;
    }
    if (frameId) loadFrame(frameId);
  }
  window.addEventListener('hashchange', () => {
    const id = new URLSearchParams(location.hash.slice(1)).get('frame');
    if (id && id !== state.frameId) loadFrame(id);
  });

  window.__fushiLens = { onButton, loadFrame, state };
  start();
})();
