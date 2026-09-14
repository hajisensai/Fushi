## BUG-2546 · 词典自带脚本第二次查词后失效：折叠字段点不开
- **报告**：2026-09-15（用户：视频字幕查词，OALD 词条里的 `Verb Forms` 折叠块第一次查词能展开，同一个词再查一次就点不开了）
- **真实性**：✅ 真 bug。根因 `fushi/assets/popup/dict-media.js:452`（原 `factory.call(window, scopedDocument, window, window, …)`）——跑词典自带 `<script>` 时交给脚本的是**真** window。

  MDX 词典（OALD 系）的折叠块是 `<span class="unbox"><span class="box_title">Verb Forms…</span><span class="body">…</span></span>`，词典 CSS 只写了 `.collapse .unbox .box_title + * { display: none }` 与 `.unbox.is-active` 的 ⊕/⊖ 图标，**展开本身完全靠词典自带脚本**（jQuery + `oaldpe.js`，`runDictScripts` 补跑——经 innerHTML 注入的 `<script>` 按规范不会自动执行）。

  弹窗 WebView 是**常驻热槽**：换词只重注入 `lookupEntries` + `renderPopup()` 重建结果 DOM，不重载页面（`dictionary_popup_webview.dart:1239` 一带）。于是同一本词典的同一份脚本每查一次词就被**重跑一遍**。`createScopedDocument`（`dict-media.js:256`）只把 `document` 圈进本词典块，脚本照样能经 `window` 逃出去，两条路各自成灾：

  1. **jQuery 式**：UMD 内部第一句就是 `var document = window.document`，拿到的是真 document，`$(document).on('click', …)` 于是绑在真 document 上。第二次查词再绑一份 → 同一次点击被两份监听各处理一次 → 折叠块展开又立刻收起，看起来就是「点不开」；第三次查词监听数回到奇数，又能开。
  2. **幂等守卫式**：脚本写 `if (window.__inited) return;` 时更彻底 —— 第二次起直接短路返回，新 DOM 一次都绑不上，从此永久点不开。

  两种写法都用 jsdom + 真 `dict-media.js` 复现到位（三轮同词查询）：写法 1 得到 `开 / 点不开 / 开`，写法 2 得到 `开 / 点不开 / 点不开`，与用户录屏一致。

- **[x] ① 已修复** — 提交 `ec74080512`。新增 `createScopedWindow()`（`fushi/assets/popup/dict-media.js:415`）：给每个词典块一份私有 window 代理——`document` 换成 scoped 版、自指属性（`window`/`self`/`top`/`parent`/`globalThis`）指回代理、window 级 `addEventListener` 收到本块 root 上（生命周期事件仍按 scoped document 的老规矩立即补发）、属性写入关进本块私有表，读取时先私有表后回落真 window（`setTimeout`/`location`/`navigator` 等宿主 API 照常可用）。脚本体外再包一层 `with (window) { … }`，让**裸标识符**（jQuery 把自己写进 window 之后，同词典下一份脚本里的 `$(…)`）也经代理解析，否则会解析到真全局拿到 undefined。代理的 target 用空对象而不是真 window：`window`/`top` 这类不可配置数据属性会让「get 返回代理自身」撞上 Proxy 不变量检查（TypeError）。

  旧块随 DOM 一起被丢弃，它挂的监听与标记自然作废，**第 N 次查词与第一次完全等价**。三份镜像（app 弹窗 / `fushi/assets/browser_extension/vendor/` / `tools/browser-extension/vendor/`）同步改。

- **[x] ② 已加自动化测试** — `fushi/test/pages/popup_dict_script_scope_test.js` + `.dart` 包装。行为级：用 Node 真跑 `runDictScripts`，连开三个词典块，断言每块都完整初始化（不被上一块留在 window 上的标记短路）、window 级监听恰好落在本块 root 一次、真 window 与真 document 上不留任何痕迹；在修复前的 `dict-media.js` 上跑会红。源码级：三份镜像都必须定义 `createScopedWindow`、把 scoped window 传给 `factory.call`、并用 `with (window)` 包裹脚本体（防只改一份）。既有的 `tools/browser-extension/dict-script-exec.test.js` 10 条契约保持全绿。

- **备注**：`runDictScripts` 取不到脚本源码时（词典包没带 js / 媒体库里没有）本就一行都不执行，点击会一路冒泡到 `popup.js` 的 `__fushiPopupClick`，落在 `.glossary-content` 分支去取词——那是另一回事，不在本条范围内。
