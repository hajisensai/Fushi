## BUG-1888 · 漫画阅读器顶栏无任何隐藏方式，也没有全屏入口
- **报告**：2026-08-27（用户：「小说和漫画都缺少全屏模式」＋顶栏截图「缺少隐藏方式」）
- **真实性**：✅ 真 bug。`fushi/lib/src/media/manga/reader/manga_fushi_page.dart:3697-3703`（修前）：顶部 chrome（页码 `1 / 168` + 框选重扫 / 整卷 OCR / 单双页 / 阅读模式切换）与左上返回键（`:3682-3696`）的**唯一**显示条件是 `_bookRow != null && !_loadFailed`——没有任何可见性状态字段、没有 auto-hide timer、没有点击唤出、也没有对应的 `ShortcutAction`（manga scope 修前只有 6 个动作：翻页 ×2、关词典、平移 ×4 中的 4 个）。用户无从把它们收掉。
  对照小说侧：reader_fushi 早有完整的 chrome 显隐状态机（`reader_fushi/chrome.part.dart:1005/1017/1108/1113/1142` 的持久开关 + 临时可见 + auto-hide + 点空白唤出，快捷键 `readerToggleChrome` 默认 M / 手柄 Y）。漫画这一整套都没有。
- **[x] ① 已修复** — 三层接线，与小说同形：
  - 动作层：新增 `ShortcutAction.mangaToggleChrome`（`shortcut_action.dart`，manga scope，key `manga_toggle_chrome`），默认绑定 **M / 手柄 Y**（`shortcut_defaults.dart`）——与 `readerToggleChrome` 同键，两者分属不同 scope 绝不同时激活，肌肉记忆跨阅读器复用；label 落 `shortcut_labels.dart`（新 i18n key `shortcut_action_manga_toggle_chrome`）。
  - 解析层：`MangaFushiPage.inputActionForShortcut` 新增 `MangaReaderInputAction.toggleChrome` 分支，位置在**两道翻页门控之前**（与平移同理）——它既不翻页也不动视野，「webtoon 让位原生滚动」「弹窗可见让位」对它都不适用：查词途中想收顶栏看清页图是合理操作。
  - 页面层：新增 `_chromeVisible` 状态；顶栏与返回键同时受门控（只挂一处等于隐藏不干净）；`_toggleMangaChrome()` 为按钮与快捷键的**唯一**执行体；移动端联动 `_applyMangaImmersiveMode()`（隐藏 → `SystemUiMode.immersiveSticky` 真全屏，显示 → 还原 `edgeToEdge`），这就是漫画在移动端的「全屏模式」。桌面窗口全屏走全局 F11（见 [BUG-1886](BUG-1886-global-fullscreen-gated-by-experimental-focus-nav.md)），两者可叠加。
  - 隐藏态保留一个 opacity 0.35 的小号「显示界面」按钮（`manga_chrome_show_button`）。这是**硬要求**不是妥协：漫画正文是原生 WebView，空白点击手势全在注入的 JS 里且已被翻页占用（见 `reference_manga_reader_gestures_live_in_webview_js`），没有这个按钮，触屏设备再没有第二条通道能把界面唤回来。顶栏侧对应新增 `manga_chrome_hide_button`。
  - 新 i18n key：`manga_interface_hide` / `manga_interface_show` / `shortcut_action_manga_toggle_chrome`（经 `i18n_sync --add` 进 17 语，除 en/zh-CN 外暂回落英文待译）。
- **[x] ② 已加自动化测试** — `fushi/test/pages/manga_toggle_chrome_test.dart`，10 条分三层：动作层（枚举/scope/key + 默认绑定与 `readerToggleChrome` 同键，三平台各验）、解析层（spread / webtoon / 弹窗可见都解析出 toggleChrome，且既有翻页/关词典/退出动作解析结果不变）、结构层源码守卫（两处门控都在、隐藏态唤回分支在、两个按钮 key 在、immersive 双向还原在、按钮与快捷键共用一个执行体）。
  变异实测：把 toggleChrome 分支改成受两道翻页门控（`if (dictionaryShown || mode == MangaReadingMode.webtoon) return null;`）→ 精确红「webtoon 仍解析」与「弹窗可见仍解析」两条、其余 8 条全绿；还原后 sha256 与变异前一致（`a064d3db4b9bd4d9…`）。结构层变异（去掉顶栏的 `&& _chromeVisible`）→ 精确红「顶栏与返回键都受 `_chromeVisible` 门控」1 条、其余 9 条绿；还原后 sha256 与变异前一致（`f4851a15eb27f90f…`）。
- **备注**：漫画未做「点空白唤出 + auto-hide」那套（小说有），因为漫画的空白点击在 WebView JS 里已被翻页占满，硬塞会与翻页抢同一次点击；现方案是显式开关语义，不引入歧义。真机验证未做（用户已取消该环节）。
