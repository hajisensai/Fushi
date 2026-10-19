// asbplayer「Anki Export」对话框里查不了词的两层根因守卫。
//
// ① 对话框是铺满视口、吃掉全部指针事件的 about:blank iframe，主 content script 只进顶层页 →
//    Shift 悬停一次都到不了取词器。修法：frame-gate.js（all_frames + match_about_blank）只在
//    about: 子 frame 里等 Shift，再请 background 把主 content script 整套注入那一个 frame；
//    侧边栏 / toast 的 tabs.sendMessage 钉 frameId 0，内嵌实例不抢答、不重复弹。
// ② 字段是 <textarea> / <input>：控件里的字不是 DOM 文本节点，caret API 取不到（旧版实测全
//    null）。修法：selection.js 在复刻样式的透明镜像 div 上取词。②要真排版，用真 Chrome 跑。
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const { execFileSync } = require('node:child_process');

const MANIFEST = JSON.parse(fs.readFileSync(path.join(__dirname, 'manifest.json'), 'utf8'));
const flush = async () => { for (let i = 0; i < 6; i++) await new Promise((r) => setImmediate(r)); };

test('manifest：主 content script 仍只进顶层页；frame-gate 单独一组进 about:blank 子 frame', () => {
  const main = MANIFEST.content_scripts[0];
  assert.ok(main.matches.includes('<all_urls>'));
  assert.ok(!main.all_frames, '整套脚本不能进所有 frame（广告 / 嵌入页会多一份实例）');
  const gate = MANIFEST.content_scripts.find((g) => g.js && g.js.includes('frame-gate.js'));
  assert.ok(gate, '必须有 frame-gate.js 一组');
  assert.deepStrictEqual(gate.js, ['frame-gate.js'], 'all_frames 那组只许放闸门本身');
  assert.strictEqual(gate.all_frames, true);
  assert.strictEqual(gate.match_about_blank, true);
  assert.strictEqual(gate.match_origin_as_fallback, true);
});

function loadGate(opts) {
  const listeners = {};
  const sent = [];
  const win = {};
  win.top = opts.top ? win : {};
  if (opts.alreadyInjected) win.__fushiExtension = true;
  const sandbox = {
    window: win,
    location: { protocol: opts.protocol },
    document: {
      addEventListener(type, fn) { (listeners[type] = listeners[type] || []).push(fn); },
      removeEventListener(type, fn) { listeners[type] = (listeners[type] || []).filter((f) => f !== fn); },
    },
    chrome: { runtime: { sendMessage(msg, cb) { sent.push(msg); if (cb) cb(); }, lastError: undefined } },
  };
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, 'frame-gate.js'), 'utf8'), sandbox, { filename: 'frame-gate.js' });
  return {
    sent,
    count(type) { return (listeners[type] || []).length; },
    fire(type, e) { for (const fn of (listeners[type] || []).slice()) fn(e); },
  };
}

test('frame-gate：顶层页 / http 子 frame / 已注入的 frame 一律不挂监听', () => {
  for (const o of [{ top: true, protocol: 'about:' }, { top: false, protocol: 'https:' }, { top: false, protocol: 'about:', alreadyInjected: true }]) {
    const h = loadGate(o);
    assert.strictEqual(h.count('keydown') + h.count('mousemove'), 0, JSON.stringify(o));
  }
});

test('frame-gate：about: 子 frame 里按 Shift 才请求注入，只请求一次，之后摘掉监听', () => {
  const h = loadGate({ top: false, protocol: 'about:' });
  h.fire('mousemove', { shiftKey: false });
  h.fire('keydown', { key: 'a' });
  assert.strictEqual(h.sent.length, 0, '不按 Shift 不注入（不查词的对话框零成本）');
  h.fire('keydown', { key: 'Shift' });
  h.fire('mousemove', { shiftKey: true });
  assert.strictEqual(h.sent.length, 1);
  assert.strictEqual(h.sent[0].type, 'fushiInjectEmbeddedFrame');
  assert.strictEqual(h.count('keydown') + h.count('mousemove'), 0);
  const m = loadGate({ top: false, protocol: 'about:' });
  m.fire('mousemove', { shiftKey: true });
  assert.strictEqual(m.sent.length, 1, 'Shift 悬停同样唤起');
});

function loadBackground(probeResult) {
  const calls = [];
  const messageListeners = [];
  const permissive = () => new Proxy(function () {}, {
    get(_t, key) {
      if (key === 'then' || key === Symbol.toPrimitive) return undefined;
      if (key === 'addListener' || key === 'removeListener') return function () {};
      return permissive();
    },
    apply() { return Promise.resolve({}); },
  });
  const scripting = {
    executeScript(opts) {
      calls.push({ fn: 'executeScript', target: opts.target, files: opts.files, probe: !!opts.func });
      return Promise.resolve(opts.func ? [{ result: probeResult }] : [{}]);
    },
    insertCSS(opts) { calls.push({ fn: 'insertCSS', target: opts.target, files: opts.files }); return Promise.resolve(); },
  };
  const chromeMock = new Proxy({}, {
    get(_t, key) {
      if (key === 'scripting') return scripting;
      if (key === 'runtime') {
        return new Proxy({}, {
          get(_t2, k2) {
            if (k2 === 'onMessage') return { addListener(fn) { messageListeners.push(fn); } };
            if (k2 === 'getManifest') return () => MANIFEST;
            return permissive();
          },
        });
      }
      return permissive();
    },
  });
  const sandbox = {
    fushiT: require('./scripts/i18n-fixture.js').makeFushiT(),
    chrome: chromeMock, console, fetch: () => Promise.resolve({ ok: false }),
    setTimeout, clearTimeout, setInterval: () => 1, clearInterval,
    URL, TextEncoder, TextDecoder, Promise, Date, Number, String,
    crypto: require('node:crypto').webcrypto,
    btoa: (s) => Buffer.from(s, 'binary').toString('base64'),
    atob: (s) => Buffer.from(s, 'base64').toString('binary'),
  };
  sandbox.self = sandbox;
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, 'background.js'), 'utf8'), sandbox, { filename: 'background.js' });
  return {
    calls,
    send(msg, sender) {
      const responses = [];
      for (const fn of messageListeners) fn(msg, sender, (v) => responses.push(v));
      return responses;
    },
  };
}

test('background：fushiInjectEmbeddedFrame 把主 content script 整套注入发请求的那一个 frame', async () => {
  const h = loadBackground(false);
  const responses = h.send({ type: 'fushiInjectEmbeddedFrame' }, { tab: { id: 5 }, frameId: 3 });
  await flush();
  const main = MANIFEST.content_scripts[0];
  for (const c of h.calls) assert.strictEqual(JSON.stringify(c.target), JSON.stringify({ tabId: 5, frameIds: [3] }));
  assert.ok(h.calls[0].probe, '先探测是否已注入');
  const js = h.calls.find((c) => c.fn === 'executeScript' && c.files);
  assert.strictEqual(JSON.stringify(js.files), JSON.stringify(main.js));
  const css = h.calls.find((c) => c.fn === 'insertCSS');
  assert.strictEqual(JSON.stringify(css.files), JSON.stringify(main.css));
  assert.strictEqual(responses.length, 1);
  assert.strictEqual(responses[0].ok, true);
});

test('background：已注入的 frame 不重复注入；顶层 frame（frameId 0）不走这条路', async () => {
  const h = loadBackground(true);
  h.send({ type: 'fushiInjectEmbeddedFrame' }, { tab: { id: 5 }, frameId: 3 });
  await flush();
  assert.strictEqual(h.calls.length, 1, '只有探测');
  const top = loadBackground(false);
  top.send({ type: 'fushiInjectEmbeddedFrame' }, { tab: { id: 5 }, frameId: 0 });
  await flush();
  assert.strictEqual(top.calls.length, 0);
});

test('侧边栏与 background 发往页面的 tabs.sendMessage 都钉 frameId 0（内嵌实例不抢答 / 不重复弹）', () => {
  for (const file of ['side-panel.js', 'background.js']) {
    const src = fs.readFileSync(path.join(__dirname, file), 'utf8');
    const re = /chrome\.tabs\.sendMessage\(/g;
    let m;
    let n = 0;
    while ((m = re.exec(src)) !== null) {
      n++;
      const call = src.slice(m.index, m.index + 400);
      assert.ok(/\{\s*frameId:\s*0\s*\}/.test(call), file + ' 第 ' + n + ' 处 tabs.sendMessage 没钉 frameId 0');
    }
    assert.ok(n > 0, file);
  }
});

// ── ② 真 Chrome 排版：textarea / input 里取词 ──
function findChrome() {
  const candidates = [
    process.env.CHROME_PATH,
    'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
    'C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe',
    '/usr/bin/google-chrome', '/usr/bin/google-chrome-stable', '/usr/bin/chromium', '/usr/bin/chromium-browser',
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  ];
  return candidates.find((p) => p && fs.existsSync(p)) || null;
}

const PROBE_HTML = `<!doctype html><html><head><meta charset="utf-8"><style>
body{margin:0;font-family:monospace}
textarea,input{position:absolute;left:40px;font:20px/30px monospace;padding:10px;border:1px solid #888;box-sizing:border-box;width:400px}
textarea{top:40px;height:110px}
input{top:200px;height:52px}
</style></head><body>
<textarea id="t">ab日本語です。
二行目の文字</textarea>
<input id="i" value="xyまさか街には">
<input id="p" type="password" value="ひみつ" style="top:280px">
<pre id="out"></pre>
<script>window.flutter_inappwebview={callHandler(){}};</script>
<script src="selection.js"></script>
<script>
const ctx=document.createElement('canvas').getContext('2d');ctx.font='20px monospace';
const res=[];
function point(el,line,col){
  const r=el.getBoundingClientRect();
  const lh=el.tagName==='INPUT'?(r.height-22):30;
  const lineText=el.value.split('\\n')[line];
  return {lineText,x:r.left+11+ctx.measureText(lineText.slice(0,col)).width+ctx.measureText(lineText[col]).width/2,y:r.top+11+line*lh+lh/2};
}
function probe(id,line,col){
  const el=document.getElementById(id);
  const p=point(el,line,col);
  const hit=fushiSelection.getCharacterAtPoint(p.x,p.y);
  const out={id,want:p.lineText[col],got:hit?hit.node.textContent[hit.offset]:null};
  if(hit){
    out.sel=fushiSelection.selectFromPosition(hit.node,hit.offset,8,p.x,p.y);
    out.sent=fushiSelection.getSentence(hit.node,hit.offset);
    const rect=fushiSelection.getSelectionRect(p.x,p.y);
    out.rectOk=!!rect&&p.x>=rect.x&&p.x<=rect.x+rect.width&&p.y>=rect.y&&p.y<=rect.y+rect.height;
  }
  out.imposters=document.querySelectorAll('.fushi-form-imposter').length;
  res.push(out);
}
try{
  probe('t',0,2);probe('t',1,3);probe('i',0,2);probe('i',0,6);probe('p',0,0);
  fushiSelection.getCharacterAtPoint(5,5);
  res.push({offControl:document.querySelectorAll('.fushi-form-imposter').length});
  probe('i',0,2);
  const hitEl=document.elementFromPoint(point(document.getElementById('i'),0,2).x,point(document.getElementById('i'),0,2).y);
  res.push({clickGoesToInput:hitEl&&hitEl.id==='i'});
  fushiSelection.clearSelection();
  res.push({afterClear:document.querySelectorAll('.fushi-form-imposter').length});
}catch(e){res.push({error:String(e&&e.stack||e)});}
document.getElementById('out').textContent='RESULT'+JSON.stringify(res)+'END';
</script></body></html>`;

test('真 Chrome：textarea / input 里能取词（镜像 div），密码框不取，镜像不挡点击、移开即清', { timeout: 90000 }, (t) => {
  const chrome = findChrome();
  if (!chrome) { t.skip('no Chrome found (set CHROME_PATH)'); return; }
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'fushi-form-lookup-'));
  try {
    fs.copyFileSync(path.join(__dirname, 'vendor', 'selection.js'), path.join(dir, 'selection.js'));
    fs.writeFileSync(path.join(dir, 'probe.html'), PROBE_HTML);
    const url = 'file:///' + path.join(dir, 'probe.html').replace(/\\/g, '/').replace(/^\//, '');
    const dom = execFileSync(chrome, [
      '--headless=new', '--disable-gpu', '--no-first-run', '--no-sandbox',
      '--user-data-dir=' + path.join(dir, 'ud'), '--allow-file-access-from-files', '--dump-dom', url,
    ], { encoding: 'utf8', timeout: 60000, stdio: ['ignore', 'pipe', 'ignore'] });
    const m = dom.match(/RESULT([\s\S]*?)END/);
    assert.ok(m, 'probe page produced no result');
    const res = JSON.parse(m[1].replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"'));
    const err = res.find((r) => r.error);
    assert.ok(!err, err && err.error);
    const byWant = res.filter((r) => r.id);
    const expect = [
      ['t', '日', '日本語です', 'ab日本語です。'],
      ['t', 'の', 'の文字', '二行目の文字'],
      ['i', 'ま', 'まさか街には', 'xyまさか街には'],
      ['i', 'に', 'には', 'xyまさか街には'],
    ];
    for (let i = 0; i < expect.length; i++) {
      const [id, ch, sel, sent] = expect[i];
      const r = byWant[i];
      assert.strictEqual(r.id, id);
      assert.strictEqual(r.got, ch, id + ' 命中字');
      assert.strictEqual(r.sel, sel, id + ' 选词');
      assert.strictEqual(r.sent, sent, id + ' 句子不越出字段');
      assert.strictEqual(r.rectOk, true, id + ' 锚点矩形盖住鼠标点');
      assert.strictEqual(r.imposters, 1, '同时只有一个镜像');
    }
    assert.strictEqual(byWant[4].id, 'p');
    assert.strictEqual(byWant[4].got, null, '密码框不取词');
    assert.strictEqual(res.find((r) => 'offControl' in r).offControl, 0, '移开控件即清镜像');
    assert.strictEqual(res.find((r) => 'clickGoesToInput' in r).clickGoesToInput, true, '镜像不挡点击输入');
    assert.strictEqual(res.find((r) => 'afterClear' in r).afterClear, 0, 'clearSelection 清镜像');
  } finally {
    try { fs.rmSync(dir, { recursive: true, force: true }); } catch (_) {}
  }
});
