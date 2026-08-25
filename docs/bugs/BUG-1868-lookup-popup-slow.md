## BUG-1868 · 查词弹窗慢，尤其嵌套查词
- **报告**：2026-08-25（用户：）
- **真实性**：✅ 真 bug。不是「渲染慢」，是**每次查词都重传一遍本可只传一次的巨量负载**。
  根因有四处，最大一处是 `fushi/lib/src/lookup/clipboard_panel_controller.dart:477`
  调 `buildStackRenderScript` 时**完全没传** `knownStaticRevisions` /
  `emittedStaticRevisions`（当时是可选形参），于是 BUG-1833 那套静态段去重对剪贴板
  面板整条路径失效。
- **[x] ① 已修复** — `1532f2331d`（四条根因）+ `8408b83dde`（字体改走 URL，⚠ 见备注）
- **[x] ② 已加自动化测试** — `fushi/test/lookup/popup_static_revision_dedup_guard_test.dart`（新）、
  `fushi/test/utils/misc/popup_dict_css_memo_test.{js,dart}`（新）、
  `fushi/test/reader/dictionary_font_css_test.dart`（增 URL 模式 4 例）、
  `fushi/test/pages/popup_settings_injection_memo_test.dart`（改用真账本走 cold→commit→hot）
- **备注**：

### 量级（用户真实配置）

词典字体绑了两个（读自生产库 `src:reader_fushi:font_targets` 的 `dict_fonts` 目标）：

| 字体 | 文件 | base64 内联后 |
|---|---|---|
| Klee One | 8.32 MB | 11.09 MB |
| Noto Sans SC | 16.95 MB | 22.60 MB |
| | | **合计 ≈ 33.7 MB** |

这两个字体以 `data:` URL 内联在**静态设置段**里（`popup_settings_injection.dart` 的
`$fontStyleJs`）。静态段本该「只发一次」，但去重是各调用方自己拼的、三处三种做法、
两处漏了：

| 路径 | 去重 | 后果 |
|---|---|---|
| 桌面全局查词窗 / gal 浮窗 | ✅ per-host revision + `staticSettingsRequired` 回补 | 正常 |
| **app 内弹窗**（阅读器/视频/首页） | ❌ `_lastSentStaticRevision` 是 **per-WebView 实例字段**（`dictionary_popup_webview.dart:416`） | 第一层走热槽复用不重发；**每嵌套一层就新建 WebView → 字段为 null → 重发 33.7 MB** |
| **剪贴板面板** | ❌ 调用点完全没传去重形参 | 每次查词（含嵌套）都重发 33.7 MB |

中间那行就是用户说的「**特别是嵌套查词开始**」。

讽刺的是 host 侧（`global_lookup_host.js:2246` 起）**早就写好了正确答案**——把字体
data URL 重写成同源 Blob object URL 跨 iframe 共享。它收到重发的 33.7 MB 后发现
revision 已缓存，`dropDescriptorStaticSource` 直接丢掉。**整整 33.7 MB 是白传的。**

旁证：`%TEMP%\hibiki_glookup.log` 里「渲染下发 → 首个按钮探测」稳定 750~1180 ms，
`entries=1` 与 `entries=84` 几乎同耗时——与词条数无关，是固定体积开销，不是渲染计算量。

### 四条根因与修法

1. **静态段去重对面板完全失效**（最大头）。根因是「去重状态由每个调用方自己维护、
   且可以不传」。修法不是给面板补参数，而是把这个特殊情况消灭掉：新增
   `PopupStaticRevisionCache` 收口账本，形参改**必填**，待确认版本从返回值
   `pendingRevisions` 带出——漏传即编译错误。面板同时接上 host 的
   `staticSettingsRequired` 回补通道：**去重与回补是一对**，只做前者会让宿主丢缓存后
   永远等不到静态段（无主题/无字体/无词典样式），比不去重更糟。

2. **每条日志一次最多 512 KB 整文件回读**。`ErrorLogService._trimLogFileToMaxBytes`
   每次 append 后都 `readAsBytes()` 整个文件才比长度，而日志长期贴着上限运行。改为先
   `stat length()`，超限才读回来裁。

3. **渲染热路径上的无条件 debug console.log**。`[RICHTEXT_HTML]` 每行释义一条、
   `[IMG_CREATE]` 每张词典图一条，每条都是跨进程 console 消息，在 in-app 表面还会经
   `onConsoleMessage` 落进 ErrorLogService（叠加第 2 条）。不删日志，改
   `window.__fushiPopupDebug` 门控，默认关。门控包住**整条语句**——参数里的
   substring/拼接在传参前就求值了，只挡输出等于没挡住开销。

4. **`constructDictCss` 无 memo**，被「N 词条 × M 词典」重复调用，每次对同一本词典
   那份（Yomitan 动辄几十 KB 的）CSS 重做逐字符扫描。加 `(css, dictName, scopePrefix)`
   三元组 memo；外层用 css 串本身分桶，内容变了自然落新桶，无需失效钩子。三份
   dict-media.js（app + 扩展两镜像）同步移植。

### ⚠ 未验证部分（`8408b83dde`）

in-app 弹窗字体改走 URL（`https://fushi.local/dictfonts/<enc>`）是唯一能根治嵌套那条
路的办法：嵌套每层都是新 WebView（新 realm，静态段必须重发），去重救不了，只能让被
重发的东西本身从 33.7 MB 降到 KB 级；URL 还能跨 WebView 共享 HTTP 缓存，`data:` 永远
共享不了。

已有代码级证据（Windows fork `web_resource_response.cpp:59-66` 确实把 headers 逐条
`AppendHeader` 进 WebView2），但**没有端到端证据**。风险方向是「字体静默不生效」，比慢
更糟：Android 的 `file://` 与 Windows `initialData` 的 opaque origin 都是跨源，成败取决
于 ACAO 头是否被插件如实传给浏览器。阅读器那条同机制路径是**同源**的，其生产表现不能
直接推断这里。**合入前必须在真机打开查词弹窗确认词典字体仍生效。**

平台边界：iOS / macOS 只有 `WKURLSchemeHandler`，其 `URLResponse` 带不了任何 header，
字体会被 CORS 拒，故这两个平台继续内联——不是偷懒，是能力边界。

### 尚未处理（收益递减，另开）

- 嵌套时各帧 `entriesJs` 仍全栈重传（静态段修好后它就是下一个大头）。
- `global_lookup_host.js:109` standby 池只有 1，连点第二层掉回冷 iframe 创建。注释说
  「bound is deliberate — a dictionary frame owns popup.js, observers and **decoded
  fonts**」——字体改走 URL 后这条理由变弱，池可以再评估。
- `FushiDicts.instance.lookup` 同步跑在主 isolate（`app_model.dart:5051`），无 compute。
- `popup.js` masonry 在 forEach 里写 6 个样式再读 `offsetHeight`，每张卡片一次强制同步布局。
