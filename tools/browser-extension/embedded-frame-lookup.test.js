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
const zlib = require('node:zlib');

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
    chrome: {
      runtime: { sendMessage(msg, cb) { sent.push(msg); if (cb) cb(); }, lastError: undefined },
      storage: { local: { get(_key, cb) { if (cb) cb(opts.stored || {}); } } },
    },
  };
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, 'frame-gate.js'), 'utf8'), sandbox, { filename: 'frame-gate.js' });
  return {
    sent,
    count(type) { return (listeners[type] || []).length; },
    fire(type, e) { for (const fn of (listeners[type] || []).slice()) fn(e); },
  };
}

function loadGateWithStorage(stored) {
  return loadGate({ top: false, protocol: 'about:', stored });
}

test('frame-gate：顶层页 / http 子 frame / 已注入的 frame 一律不挂监听', () => {
  for (const o of [{ top: true, protocol: 'about:' }, { top: false, protocol: 'https:' }, { top: false, protocol: 'about:', alreadyInjected: true }]) {
    const h = loadGate(o);
    assert.strictEqual(h.count('keydown') + h.count('mousemove'), 0, JSON.stringify(o));
  }
});

test('frame-gate：about: 子 frame 里只有 Shift 悬停（查词手势）才请求注入，只请求一次，之后摘掉监听', () => {
  const h = loadGate({ top: false, protocol: 'about:' });
  assert.strictEqual(h.count('keydown'), 0, '不监听键盘：单按 Shift 不是查词意图');
  h.fire('mousemove', { shiftKey: false, buttons: 0 });
  assert.strictEqual(h.sent.length, 0, '不按 Shift 不注入（不查词的对话框零成本）');
  h.fire('keydown', { key: 'Shift', shiftKey: true });
  assert.strictEqual(h.sent.length, 0, '编辑器 iframe 里打大写字母（单按 Shift）不注入');
  h.fire('mousemove', { shiftKey: true, buttons: 1 });
  assert.strictEqual(h.sent.length, 0, 'Shift + 按住鼠标拖动是扩选文字，不是查词');
  // asbplayer「Anki Export」对话框：按住 Shift 把指针挪到 Sentence 字段上。
  h.fire('mousemove', { shiftKey: true, buttons: 0 });
  assert.strictEqual(h.sent.length, 1);
  assert.strictEqual(h.sent[0].type, 'fushiInjectEmbeddedFrame');
  assert.strictEqual(h.count('keydown') + h.count('mousemove'), 0);
  h.fire('mousemove', { shiftKey: true, buttons: 0 });
  assert.strictEqual(h.sent.length, 1, '只请求一次');
});

test('frame-gate 注入后 content.js 认的就是同一个手势：同一个可配置触发键（默认 Shift）', () => {
  const src = fs.readFileSync(path.join(__dirname, 'content.js'), 'utf8');
  assert.match(src, /let fushiScanModifier = 'shift';/);
  assert.match(src, /document\.addEventListener\('mousemove', \(e\) => \{[\s\S]{0,200}if \(!fushiScanModifierHeld\(e, fushiScanModifier\)\)/,
    'content.js 的悬停查词按 mousemove 时触发键是否按着判（闸门唤起后按住触发键再挪一下即查词）');
});

test('frame-gate 跟随设置里的触发键（scanModifier）；none 仍要 Shift 唤起', () => {
  for (const [stored, prop, other] of [
    [{}, 'shiftKey', 'ctrlKey'],
    [{ scanModifier: 'ctrl' }, 'ctrlKey', 'shiftKey'],
    [{ scanModifier: 'alt' }, 'altKey', 'shiftKey'],
    [{ scanModifier: 'none' }, 'shiftKey', 'altKey'],
  ]) {
    const h = loadGateWithStorage(stored);
    h.fire('mousemove', { [other]: true, buttons: 0 });
    assert.strictEqual(h.sent.length, 0, JSON.stringify(stored) + ' 非触发键不唤起');
    h.fire('mousemove', { [prop]: true, buttons: 0 });
    assert.strictEqual(h.sent.length, 1, JSON.stringify(stored) + ' 触发键悬停唤起');
  }
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

// ── ③ 真 Chrome 像素：镜像上的选区高亮看得见、真字透得出来、控件值 / 焦点 / 点击都不受影响 ──
// 最小 PNG 解码（8 bit RGB / RGBA，无隔行；headless Chrome 截图即此形态）。
function decodePng(buf) {
  let pos = 8;
  let width = 0, height = 0, colorType = 0;
  const idat = [];
  while (pos < buf.length) {
    const len = buf.readUInt32BE(pos);
    const type = buf.toString('ascii', pos + 4, pos + 8);
    const data = buf.subarray(pos + 8, pos + 8 + len);
    if (type === 'IHDR') { width = data.readUInt32BE(0); height = data.readUInt32BE(4); colorType = data[9]; assert.strictEqual(data[8], 8); assert.strictEqual(data[12], 0); }
    else if (type === 'IDAT') idat.push(data);
    else if (type === 'IEND') break;
    pos += 12 + len;
  }
  const bpp = colorType === 6 ? 4 : colorType === 2 ? 3 : 0;
  assert.ok(bpp, 'unsupported PNG color type ' + colorType);
  const raw = zlib.inflateSync(Buffer.concat(idat));
  const stride = width * bpp;
  const px = Buffer.alloc(stride * height);
  for (let y = 0; y < height; y++) {
    const f = raw[y * (stride + 1)];
    const line = raw.subarray(y * (stride + 1) + 1, (y + 1) * (stride + 1));
    for (let x = 0; x < stride; x++) {
      const a = x >= bpp ? px[y * stride + x - bpp] : 0;
      const b = y > 0 ? px[(y - 1) * stride + x] : 0;
      const c = x >= bpp && y > 0 ? px[(y - 1) * stride + x - bpp] : 0;
      let v = line[x];
      if (f === 1) v += a;
      else if (f === 2) v += b;
      else if (f === 3) v += (a + b) >> 1;
      else if (f === 4) { const pa = Math.abs(b - c), pb = Math.abs(a - c), pc = Math.abs(a + b - 2 * c); v += (pa <= pb && pa <= pc) ? a : (pb <= pc ? b : c); }
      px[y * stride + x] = v & 255;
    }
  }
  return { width, height, at(x, y) { const i = y * stride + x * bpp; return [px[i], px[i + 1], px[i + 2]]; } };
}

const HIGHLIGHT_HTML = `<!doctype html><html><head><meta charset="utf-8"><style>
html,body{margin:0;background:#fff}
textarea{position:absolute;left:40px;top:40px;width:420px;height:110px;font:24px/34px monospace;padding:10px;border:1px solid #888;box-sizing:border-box;color:#000;background:#fff;resize:none;outline:none}
::highlight(fushi-selection){background-color:rgba(255,0,0,.45);color:inherit}
.fushi-dict-highlight{background-color:rgba(255,0,0,.45)!important;color:inherit}
#out{position:absolute;left:0;top:360px;font-size:4px;color:#fff}
</style></head><body>
<textarea id="t">ab日本語です。</textarea>
<pre id="out"></pre>
<script>window.flutter_inappwebview={callHandler(){}};</script>
<script src="selection.js"></script>
<script>
const out={};
try{
  const el=document.getElementById('t');
  const before=el.value;
  const ctx=document.createElement('canvas').getContext('2d');ctx.font='24px monospace';
  const r=el.getBoundingClientRect();
  const x=r.left+11+ctx.measureText('ab').width+ctx.measureText('日').width/2, y=r.top+11+17;
  const hit=fushiSelection.getCharacterAtPoint(x,y);
  out.got=hit?hit.node.textContent[hit.offset]:null;
  fushiSelection.selectFromPosition(hit.node,hit.offset,8,x,y);
  const box=fushiSelection.highlightSelection(3);
  out.box=box;
  out.valueSame=el.value===before;
  out.focusUntouched=document.activeElement===document.body;
  out.clickGoesToField=document.elementFromPoint(x,y)===el;
  const imp=document.querySelector('.fushi-form-imposter');
  const cs=getComputedStyle(imp);
  out.imposter={opacity:cs.opacity,color:cs.color,bg:cs.backgroundColor,pe:cs.pointerEvents};
  const abRange=document.createRange();abRange.setStart(imp.firstChild,0);abRange.setEnd(imp.firstChild,2);
  const ab=abRange.getBoundingClientRect(); out.abLeft=ab.left; out.abRight=ab.right;
  if(location.hash==='#input'){
    out.highlightRangesBefore=CSS.highlights.get('fushi-selection')?.size;
    window.dispatchEvent(new Event('resize'));
    out.afterNoopResize=document.querySelectorAll('.fushi-form-imposter').length;
    el.value=el.value+'か';
    el.dispatchEvent(new Event('input',{bubbles:true}));
    out.afterInput=document.querySelectorAll('.fushi-form-imposter').length;
  }
}catch(e){out.error=String(e&&e.stack||e);}
document.getElementById('out').textContent='RESULT'+JSON.stringify(out)+'END';
</script></body></html>`;

test('真 Chrome 像素：输入框镜像选区有可见高亮，真字透得出来；不改值、不抢焦点、不挡点击；输入后高亮即撤', { timeout: 90000 }, (t) => {
  const chrome = findChrome();
  if (!chrome) { t.skip('no Chrome found (set CHROME_PATH)'); return; }
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'fushi-form-highlight-'));
  try {
    fs.copyFileSync(path.join(__dirname, 'vendor', 'selection.js'), path.join(dir, 'selection.js'));
    fs.writeFileSync(path.join(dir, 'probe.html'), HIGHLIGHT_HTML);
    const url = 'file:///' + path.join(dir, 'probe.html').replace(/\\/g, '/').replace(/^\//, '');
    const common = ['--headless=new', '--disable-gpu', '--no-first-run', '--no-sandbox', '--hide-scrollbars',
      '--force-device-scale-factor=1', '--window-size=600,400', '--allow-file-access-from-files', '--disable-lcd-text'];
    const dom = execFileSync(chrome, [...common, '--user-data-dir=' + path.join(dir, 'ud1'), '--dump-dom', url + '#input'],
      { encoding: 'utf8', timeout: 60000, stdio: ['ignore', 'pipe', 'ignore'] });
    const m = dom.match(/RESULT([\s\S]*?)END/);
    assert.ok(m, 'probe page produced no result');
    const res = JSON.parse(m[1].replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"'));
    assert.ok(!res.error, res.error);
    assert.strictEqual(res.got, '日');
    assert.strictEqual(res.valueSame, true, '不改控件的值');
    assert.strictEqual(res.focusUntouched, true, '不抢焦点');
    assert.strictEqual(res.clickGoesToField, true, '镜像不挡点击');
    assert.strictEqual(res.imposter.opacity, '1');
    assert.strictEqual(res.imposter.color, 'rgba(0, 0, 0, 0)', '镜像的字透明，真字由控件画');
    assert.strictEqual(res.imposter.pe, 'none');
    assert.ok(res.box && res.box.width > 20, '高亮框：' + JSON.stringify(res.box));
    assert.strictEqual(res.highlightRangesBefore, 1);
    assert.strictEqual(res.afterNoopResize, 1, '尺寸没变的 resize 不拆镜像');
    assert.strictEqual(res.afterInput, 0, '控件被输入改值：镜像（连同其上的高亮）当场撤掉，不留错位高亮');

    const shot = path.join(dir, 'shot.png');
    execFileSync(chrome, [...common, '--user-data-dir=' + path.join(dir, 'ud2'), '--screenshot=' + shot, url],
      { timeout: 60000, stdio: 'ignore' });
    const img = decodePng(fs.readFileSync(shot));
    const b = res.box;
    let tinted = 0, ink = 0, total = 0;
    for (let y = Math.ceil(b.y) + 2; y < Math.floor(b.y + b.height) - 2; y++) {
      for (let x = Math.ceil(b.x) + 2; x < Math.floor(b.x + b.width) - 2; x++) {
        const [r, g, bl] = img.at(x, y);
        total++;
        if (r > 200 && g < 190 && bl < 190) tinted++; // 白底 + 45% 红
        if (r < 170 && g < 80 && bl < 80) ink++; // 黑字 + 45% 红：真字从高亮下透出来
      }
    }
    assert.ok(total > 100, 'sample area too small');
    assert.ok(tinted / total > 0.3, '选区高亮看得见：' + tinted + '/' + total);
    assert.ok(ink > 10, '控件的真字在高亮下仍可见：' + ink);
    // 高亮只在选中的词上：前面的「ab」不带红。
    let redOutside = 0;
    for (let y = Math.ceil(b.y) + 2; y < Math.floor(b.y + b.height) - 2; y++) {
      for (let x = Math.ceil(res.abLeft) + 1; x < Math.floor(res.abRight) - 1; x++) {
        const [r, g, bl] = img.at(x, y);
        if (r > 150 && r - g > 60 && r - bl > 60) redOutside++;
      }
    }
    assert.strictEqual(redOutside, 0, '选区之外没有高亮');
  } finally {
    try { fs.rmSync(dir, { recursive: true, force: true }); } catch (_) {}
  }
});
