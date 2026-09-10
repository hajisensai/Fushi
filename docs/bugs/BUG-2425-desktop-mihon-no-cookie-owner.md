## BUG-2425 · 桌面 Mihon 扩展无 cookie 所有者：需登录的源永远锁着
- **报告**：2026-09-10（用户：截图 BookWalker Japan 作品页，17 条章节全带 🔒，问「怎么解锁」）
- **真实性**：✅ 真 bug。锁本身不是 Hibiki 画的——`manga_chapter_list.dart:142` 原样渲染 `chapter.name`，全仓无锁图标逻辑；本机 `eu.kanade.tachiyomi.extension.ja.bookwalkerjp.apk` 的 dex 里有字面量 `"🔒 "` / `"🔒 (Preview) "`（MUTF-8 编码，普通 grep 扫不到），以及提示 `Log in via WebView and rent or purchase this chapter to read.` / `Log in via WebView to access your library.`。即 🔒 = 未登录或该卷未购买，扩展靠 `member.bookwalker.jp/api` + `/prx/holdBooks-api/hold-book-list/` 判归属，无登录 cookie 就一本都判不出来。

  根因在桌面端**没有 cookie 所有者**，三层都不成立：
  - `desktop_mihon_runtime.dart:87-94` 的 `_headers` 只发 `Authorization` + `Content-Type`，宿主侧根本没有 cookie 概念；
  - sidecar 内有**三份互不相通**的 cookie 存储——okhttp 的 `MemoryCookieJar`（`overlay/.../NetworkHelper.kt:26` → `upstream_src/.../MemoryCookieJar.kt:15`，纯 `mutableSetOf`）、`java.net.InMemoryCookieStore`（`Main.kt:42` 装、`CookieManagerImpl.kt:12` 消费）、CEF 内部那份（`KcefWebViewProvider` 全文零 cookie 代码）；三份**全在子进程内存**，`_restart()`（`invalidateExtensions` / `clearSourceData` 都会触发）一来即清空；
  - `DesktopMihonRuntime` 只 `implements CancellableMihonRuntime`，没有任何交互式 WebView 通路（`ChallengeMihonRuntime` 仅 Android 实现），且 sidecar 以 `-Djava.awt.headless=true` 起、KCEF 三处 browser 创建点全硬编码 `CefRendering.OFFSCREEN`，`KCEF.init` 从未调用、`InitBrowserHandler` 未在 DI 绑定——那条路结构上不可能承载登录。

  Android 不受影响：系统级 `CookieManager` 本来就是唯一所有者，扩展的 okhttp 经 `AndroidCookieJar` 直接读它。

- **[x] ① 根因修复** — `b71b565c34`。**让宿主成为 cookie 的唯一所有者**，sidecar 的 jar 退化成易失缓存，而不是再加第四份存储：
  - 抽出共用持久化 `MangaCookieJar`（`fushi/lib/src/media/manga/cookie/manga_cookie_jar.dart`）；`AidokuCookieJar` 退化成薄封装、公开 API 逐字节不变（它的既有测试全绿即零破坏的证明）。新增 `MihonCookieJar`，落 `<supportRoot>/mihon/cookies.json`。
  - `DesktopMihonRuntime` 每次 `/dalvik` 与 `/source-image` 按源 `baseUrl` 的 host 注入 `Cookie:` 头；`invokeBridge` 增加可空 `source` 具名参数把源身份带到发送点（Android 实现忽略它）。**关键杠杆**：sidecar 的 `DalvikHandler` 早就支持读这个头，注入通道现成，无需新增 RPC。
  - 新增 `MihonWebLoginPage`：可见 `InAppWebView` 打开源站，用户手动登录后点「完成」导出整站 cookie。**不猜完成信号**——登录不像 Cloudflare 解题有唯一判据（新 `cf_clearance`），拿某个 cookie 的出现当判据只在部分站点碰巧成立。Windows 的 `CookieManager.getCookies` 走 CDP `Network.getCookies`（`flutter_inappwebview_windows/windows/cookie_manager.cpp:227-271`），**能取到 HttpOnly**，方案因此成立。
  - 导出时把子域 cookie 重标到源站 host，与 sidecar 用 `source.getBaseUrl()` 重建域的既有行为对齐；两边不看同一个域，注进去的条目就匹配不上、登录会静默失败。
  - Kotlin overlay 新增 `SourceCookieInjection`（注入 + 回传的单一所有者，bridge / image 两条路共用同一份域规则），响应带 `X-Fushi-Set-Cookie`（base64 JSON）回传本次调用后 jar 里的 cookie，宿主 `mergeFromRuntime` **逐条覆盖**并回真值；缺这一步，登录态只能撑到站点轮转会话为止。回传合并刻意不用整站替换——那会把同站其它域的登录 cookie 一起抹掉，等于每发一次请求就登出一部分。
  - `clearSourceData` 连带清宿主 jar，否则「清除源数据」清完立刻被下次请求原样注回去。
  - UI 入口：源行加登录按钮，门控用 `runtime is HostCookieMihonRuntime` 这个**能力**判据，而不是 `Platform.isAndroid`。

- **[x] ② 自动化测试** — Kotlin 侧 `overlay/server/src/test/kotlin/mextensionserver/controller/SourceCookieInjectionTest.kt`（4 例：线格式字面量 / 会话 cookie 不带 OkHttp 的哨兵过期 / 空表不出头 / `domainOf` 回退）。**跨语言契约**：该测试里的 base64 字面量与 Dart 测试里的逐字节相同——两侧各有自己的编解码实现，只改一边而保持该边自洽的改动在各自测试里照样全绿，只有把同一份载荷钉在两边、漂移才会红。

  Dart 侧 `fushi/test/media/manga/mihon_cookie_jar_test.dart`（17 例：持久化往返 / 父子域匹配 / 过期 / 坏文件降级 / `clearForHost` 只清该站 / `mergeFromRuntime` 逐条覆盖且不动同站其它条目 / 无变化不落盘 / 线格式含非 ASCII 与分号的往返保真 + 坏载荷降级 / 注入按 host 过滤 / 无 cookie 不发头 / 刻意不发 UA / 无 host 的源不炸 / 回传被并回并落盘）；`fushi/test/media/manga/mihon_web_login_page_test.dart`（6 例：导出并关页 / 子域重标 / 第三方域被拒 / 空结果与导出失败都不关页 / 关闭按钮不导出）。运行时侧经 `debugRequestHeaders` / `debugAbsorbResponseCookies` 两个 `@visibleForTesting` 缝跑**生产函数本身**，不复制一份注入规则。新 overlay 文件已登记进 `mihon_vendored_server_guard_test.dart` 的 `_overlayNewFiles`。

- **验证边界（未做的部分要说清楚）**：
  - Dart 侧：全量 `flutter analyze` 绿；`test/media/manga/` + `test/build/mihon_vendored_server_guard_test.dart` 778 通过；51 条目录枚举型守卫整批 **368 通过**（与文档当前基线一致）。该批守卫当场抓出新文件里的一个裸 NUL 字节并已修（`dart_source_no_raw_nul_guard`）——正是「定向测试按功能域挑、永远挑不到目录枚举型守卫」的实例。
  - Kotlin 侧：`tool/mihon/build_desktop_runtime.ps1` 完整构建通过（含 `:server:test`），产物齐全。**`BUILD SUCCESSFUL` 不被当作新测试跑过的证据**——另起持久构建树单跑该测试类，读 JUnit XML 得 `tests="4" skipped="0" failures="0" errors="0"`，其中「线格式字面量」那条通过即证明 Kotlin 编码器产出与 Dart 解码器测试消费的字节完全一致。
  - **未做真实站点端到端**：没有拿真实 BookWalker 账号登录并验证 🔒 消失。宿主侧注入/回传/持久化均有测试覆盖，但「真登录后扩展判定归属成功」这一环只在代码路径上成立，未经真机证据。按 galgame 门的口径，这一环记 `implemented_unverified`。
  - **这本书即使解锁也读不了**：用户截图那本是轻小说（富士見ファンタジア文庫）。sidecar 日志 `sidecar.log.1:25283` 显示扩展在取到 `viewer-trial.bookwalker.jp/.../viewer.html`（200 OK）后抛 `Novels are not supported!`（`MihonInvoker.kt:334`，出现 3 次）——那是 BookWalker 扩展对小说的自有限制，与本 bug 无关，不在本轮范围。
  - **本轮不做桌面 Cloudflare 解题**：sidecar 的 `CloudflareInterceptor` 是空实现。因此刻意**不发 `User-Agent`**（没有「clearance 绑定 UA」的约束，发了只会全局改写自设 UA 的源）。将来补桌面解题时，UA 必须与 cookie 一起作为「登录身份」整体存取。
  - **cookie 作用域被放宽**到源站父域及其全部子域（重标的代价），且与 sidecar 既有行为一致；要收窄必须两侧一起改。

- **备注**：波及面远大于 BookWalker——本机已装 `cmoa` / `dmm` / `ebookjapan` / `comicfuz` 等几十个需登录的日源，桌面端此前**一个都登不了**。
