## BUG-1868 · 查词弹窗慢，尤其嵌套查词
- **报告**：2026-08-25（用户：）
- **真实性**：✅ 真 bug。不是「渲染慢」，是**每次查词都重传一遍本可只传一次的巨量负载**。
  根因有四处，最大一处是 `fushi/lib/src/lookup/clipboard_panel_controller.dart:477`
  调 `buildStackRenderScript` 时**完全没传** `knownStaticRevisions` /
  `emittedStaticRevisions`（当时是可选形参），于是 BUG-1833 那套静态段去重对剪贴板
  面板整条路径失效。
- **[x] ① 已修复** — `1532f2331d`（四条根因）+ `8408b83dde`（字体改走 URL，已端到端验证 `392c2a22ff`）
- **[x] ② 已加自动化测试** — `fushi/test/lookup/popup_static_revision_dedup_guard_test.dart`（新）、
  `fushi/test/utils/misc/popup_dict_css_memo_test.{js,dart}`（新）、
  `fushi/test/reader/dictionary_font_css_test.dart`（增 URL 模式 4 例）、
  `fushi/test/pages/popup_settings_injection_memo_test.dart`（改用真账本走 cold→commit→hot）、
  `fushi/integration_test/dict_popup_font_url_itest.dart`（新，Windows 真 WebView2 端到端 + 负向对照）
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

### in-app 字体走 URL（`8408b83dde`）—— 已端到端验证（Windows）

嵌套那条路去重救不了：每层都是新 WebView（新 realm，静态段必须重发）。唯一的根治是
让被重发的东西本身从 33.7 MB 降到 KB 级——字体改走
`https://fushi.local/dictfonts/<enc>`，字节由弹窗 WebView 的 `shouldInterceptRequest`
按需供，且**跨 WebView 共享 HTTP 缓存**（`data:` 每次都是全新资源，永远共享不了）。

Windows 离屏实测（`392c2a22ff`，`tool/run_windows_itest.ps1`，隔离 app data + 隔离
WebView2 profile，**不启动 app、不碰生产库**）：

```
[cors]   fetch:200 | bytes:3936 | load:ok | check:true | faces:ItestFont=loaded
[nocors] fetch-threw:TypeError: Failed to fetch | check:false | faces:ItestFont=error
```

负向对照（同样字节、同样 200，唯独抽掉 `Access-Control-Allow-Origin`）确实失败，
证明该环境真在检查 CORS，正向那条绿不是恒真。

覆盖边界：只实测了 **Windows**。Android 走同一套 `shouldInterceptRequest` +
`WebResourceResponse` headers 机制（阅读器 `fushi.local/fonts/` 已在生产用它），但
**未实测**。iOS / macOS 只有 `WKURLSchemeHandler`，其 `URLResponse` 带不了任何 header，
字体会被 CORS 拒 → 这两个平台继续内联，不受影响（能力边界，非偷懒）。

验证过程中修掉两个**测试自身**的坑（已写进测试文件注释）：`evaluateJavascript` 不会
await Promise（头两轮的「失败」全是假的）；`Directory.systemTemp` 在 Windows 给反斜杠，
手拼 `/` 造出混合分隔符会被白名单挡下。

### 尚未处理（收益递减，另开）

- 嵌套时各帧 `entriesJs` 仍全栈重传（静态段修好后它就是下一个大头）。
- `global_lookup_host.js:109` standby 池只有 1，连点第二层掉回冷 iframe 创建。注释说
  「bound is deliberate — a dictionary frame owns popup.js, observers and **decoded
  fonts**」——字体改走 URL 后这条理由变弱，池可以再评估。
- `FushiDicts.instance.lookup` 同步跑在主 isolate（`app_model.dart:5051`），无 compute。
  **已调查，不建议顺手改**：引擎自己的源码（`native/fushidicts/fushidicts_src/` +
  `fushidicts_ffi.cpp`）里**没有任何 mutex / std::thread / pthread**（全仓命中的并发原语
  都在 vendored 的 glaze 里），即它是无内部同步的单线程设计——多个 isolate 拿同一个
  handle 并发查询会直接踩共享状态。已有先例 `FushiDicts.importDictionary`
  （`fushidicts.dart:527`）之所以能 `Isolate.run`，是因为它是 **static、不需要 handle**，
  在新 isolate 里自建 bindings；`lookup` 需要主 isolate 建的 handle，情况完全不同。
  唯一安全的形态是**单个专用查词 isolate 串行化**，但那要把引擎 handle 的所有权整体
  迁过去（牵动 AppModel 初始化与所有同步调用点），是独立的架构改动，应单独立项。
- `popup.js` masonry 在 forEach 里写 6 个样式再读 `offsetHeight`，每张卡片一次强制同步布局。
