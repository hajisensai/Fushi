// BUG-3705 / BUG-3706：恶意词典内容不能在查词弹窗主文档里执行脚本、调原生桥或外联。
//
// 在真 Chrome 里加载生产 dict-media.js + selection.js + popup.js（与 popup.html 同序），
// 原生桥换成记录器，逐个场景渲染词典块再检查主文档与桥调用记录。沙箱 iframe 里发生了
// 什么，靠词典脚本自己经 postMessage 报一条 error 消息出来（父页面转成 reportJsError
// 调用，记录器能看到）。
//
// 不覆盖：Android addJavascriptInterface 那类「桥注入所有 frame」的宿主行为——那由各平台
// 原生的桥锁定补丁负责（见 docs/specs/2026-10-23-dictionary-script-sandbox.md）。
import fs from 'node:fs';
import assert from 'node:assert/strict';
import { launchChromeDriver, resolveChrome } from '../../../tool/reader_pitch_headless/cdp_client.mjs';

if (!resolveChrome()) {
  console.log('Chrome unavailable');
  process.exit(77);
}
// 唯一参数是 Dart 测试刚写的临时 payload 文件（仓库里的生产脚本），不是外部输入。
const scripts = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));  // NOSONAR: path comes from the Dart test harness

const LOCKED = 'fushi-bridge-locked-v1';

function page(lockReply, dictStyles) {
  const bridge = `
    window.__calls = [];
    window.flutter_inappwebview = {
      callHandler(name, ...args) {
        window.__calls.push({ name, args: JSON.parse(JSON.stringify(args)) });
        if (name === '_fushiLockBridge') return Promise.resolve(${JSON.stringify(lockReply)});
        if (name === 'getDictAsset') return Promise.resolve('window.__extLoaded = 1;');
        return Promise.resolve(null);
      },
    };
    window.dictionaryStyles = ${JSON.stringify(dictStyles || {})};
  `;
  const esc = (s) => s.replace(/<\/script/gi, '<\\/script');
  return '<!doctype html><html><head><meta charset="utf-8">' +
    `<script>${esc(bridge)}</script>` +
    `<script>${esc(scripts.dictMedia)}</script>` +
    `<script>${esc(scripts.selection)}</script>` +
    `<script>${esc(scripts.popup)}</script>` +
    '</head><body></body></html>';
}

// 渲染一个词典块，等锁桥 + iframe 加载 + 消息往返，然后回报主文档状态。
function renderExpr(content) {
  return `(async () => {
    const details = createGlossarySection('D', [{ content: ${JSON.stringify(content)},
      definitionTags: '', termTags: '', glossaryIndex: 0 }], 0, 0, 1);
    document.body.appendChild(details);
    await new Promise((r) => setTimeout(r, 1500));
    const frames = [...document.querySelectorAll('iframe')];
    return {
      pwned: window.__pwned === undefined ? null : String(window.__pwned),
      scriptsInMain: document.querySelectorAll('body script').length,
      onAttrs: [...document.body.querySelectorAll('*')]
        .flatMap((el) => [...el.attributes].map((a) => a.name))
        .filter((n) => n.startsWith('on')),
      hrefs: [...document.body.querySelectorAll('[href]')].map((el) => el.getAttribute('href')),
      srcs: [...document.body.querySelectorAll('[src]')].map((el) => el.getAttribute('src')),
      frames: frames.map((f) => ({ sandbox: f.getAttribute('sandbox'), height: f.style.height })),
      calls: window.__calls.map((c) => c.name),
      reports: window.__calls.filter((c) => c.name === 'reportJsError')
        .map((c) => (c.args[0] && c.args[0].message) || ''),
      text: document.body.textContent,
      dictStyle: [...document.querySelectorAll('style.fushi-dict-style')].map((s) => s.textContent).join('\\n'),
    };
  })()`;
}

const SCRIPTED = `<div id="t">static</div>
<script>
  var reach = 'blocked';
  try { reach = typeof parent.flutter_inappwebview; } catch (e) { reach = 'blocked'; }
  try { window.top.__pwned = 'top'; } catch (e) {}
  document.getElementById('t').textContent = 'ran';
  window.__pwned = 'iframe-only';
  setTimeout(function () {
    parent.postMessage({ __fushiDictSandbox: 1, type: 'error',
      message: 'probe:' + document.getElementById('t').textContent + ':' + reach + ':' + (window.__extLoaded || 0) }, '*');
    parent.postMessage({ __fushiDictSandbox: 1, type: 'select', text: 'spam', rect: {} }, '*');
    parent.postMessage({ __fushiDictSandbox: 1, type: 'link', href: 'https://evil.example/', text: 'x', rect: {} }, '*');
  }, 50);
</script>
<script src="ext.js"></script>`;

const driver = await launchChromeDriver();
let passed = 0;
try {
  // 1. 结构化内容：标签白名单 + 危险 href。
  {
    const r = await driver.evalOnPage(page(LOCKED), renderExpr(JSON.stringify({
      type: 'structured-content',
      content: [
        { tag: 'script', content: "window.__pwned = 'sc-script'" },
        { tag: 'a', href: "javascript:window.__pwned='sc-href'", content: 'link' },
        { tag: 'iframe', content: 'framed' },
        { tag: 'span', style: { backgroundImage: 'url(https://evil.example/t.png)' }, content: 'bg' },
      ],
    })));
    assert.equal(r.pwned, null, 'structured content must not execute');
    assert.equal(r.scriptsInMain, 0, 'no <script> element from structured content');
    assert.equal(r.frames.length, 0, 'no iframe element from structured content');
    assert.ok(!r.hrefs.some((h) => /javascript:/i.test(h)), `javascript: href stripped (${r.hrefs})`);
    assert.ok(!/evil\.example/.test(JSON.stringify(r)), 'remote background url dropped');
    assert.ok(r.text.includes('link') && r.text.includes('framed'), 'content of unknown tags is kept');
    passed++;
  }

  // 2. 不带脚本的 HTML 释义：净化后留在主文档。
  {
    const r = await driver.evalOnPage(page(LOCKED), renderExpr(
      '<img src="x" onerror="window.__pwned=\'onerror\'">' +
      '<svg onload="window.__pwned=\'svg\'"><a xlink:href="javascript:1"><text>s</text></a></svg>' +
      '<a href="javascript:window.__pwned=\'click\'">bad</a><a href="https://example.com/">ok</a>' +
      '<img src="https://evil.example/t.png"><form action="https://evil.example/"><input></form>' +
      '<p style="background:url(https://evil.example/s.png)">styled</p>'));
    assert.equal(r.pwned, null, `inline handlers must not run (${r.pwned})`);
    assert.deepEqual(r.onAttrs, [], 'on* attributes stripped');
    assert.ok(!r.hrefs.some((h) => /javascript:/i.test(h)), `javascript: href stripped (${r.hrefs})`);
    assert.ok(r.hrefs.includes('https://example.com/'), 'normal external link kept');
    assert.ok(!r.srcs.some((s) => /evil\.example/.test(s)), `remote img src stripped (${r.srcs})`);
    assert.ok(!/evil\.example/.test(JSON.stringify(r)), 'no remote reference left anywhere');
    assert.ok(r.text.includes('styled'), 'content kept');
    passed++;
  }

  // 3. 带脚本的 HTML 释义 + 桥锁定成功：脚本只在沙箱 iframe 里跑。
  {
    const r = await driver.evalOnPage(page(LOCKED), renderExpr(SCRIPTED));
    assert.equal(r.pwned, null, `dictionary script must not touch the main window (${r.pwned})`);
    assert.equal(r.scriptsInMain, 0, 'no script element in the main document');
    assert.equal(r.frames.length, 1, 'scripted block mounted into one iframe');
    assert.equal(r.frames[0].sandbox, 'allow-scripts', 'sandbox without allow-same-origin');
    assert.ok(r.calls.includes('_fushiLockBridge'), 'page asked the host to lock the bridge');
    assert.ok(r.calls.includes('getDictAsset'), 'external script fetched by the parent');
    const probe = r.reports.find((m) => m.includes('probe:'));
    assert.ok(probe, `sandbox reported back (${r.reports})`);
    assert.ok(probe.includes('probe:ran:blocked:1'),
      `script ran inside the sandbox, could not reach the parent bridge, external script inlined (${probe})`);
    assert.ok(!r.calls.includes('textSelected'), 'unsolicited select from the sandbox is dropped');
    assert.ok(!r.calls.includes('openLink'), 'unsolicited link from the sandbox is dropped');
    assert.notEqual(r.frames[0].height, '0px', 'iframe height follows its content');
    passed++;
  }

  // 4. 宿主回的不是专用值（没实现锁定）：不挂沙箱，只显示净化后的静态内容。
  for (const reply of [true, null, 'ok']) {
    const r = await driver.evalOnPage(page(reply), renderExpr(SCRIPTED));
    assert.equal(r.pwned, null, `no script may run when the bridge is not locked (${reply})`);
    assert.equal(r.frames.length, 0, `no sandbox without a confirmed lock (${reply})`);
    assert.ok(r.text.includes('static'), 'static content still shown');
    assert.ok(!r.calls.includes('getDictAsset'), 'scripts not even fetched');
  }
  passed++;

  // 5. 词典 styles.css：@import 与外部 url() 不进样式表，本地 url() 保留。
  {
    const r = await driver.evalOnPage(page(LOCKED, {
      D: "@import url('https://evil.example/x.css'); .a { background: url(https://evil.example/y.png); }" +
        ' .b { background: url(//evil.example/z.png); } .c { background: url(local.png); }',
    }), renderExpr(JSON.stringify({ type: 'structured-content', content: 'css' })));
    assert.ok(!/evil\.example/.test(r.dictStyle), `remote css refs stripped (${r.dictStyle})`);
    assert.ok(!/@import/i.test(r.dictStyle), '@import stripped');
    assert.ok(r.dictStyle.includes('local.png'), 'local url kept');
    passed++;
  }
} finally {
  await driver.close();
}
console.log(`PASS ${passed} dictionary sandbox scenarios`);
