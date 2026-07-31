## BUG-1280 · 双页 spread 页唤不出底栏、退不出书
- **报告**：2026-07-31（用户："书架里面打开，然后自动变成双页漫画" → 唤不出菜单、退不出去）
- **真实性**：✅ 真 bug。根因三层，各自独立：
  - ① `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart:494` `buildSpreadPageHtml`
    生成的双页展开页是**独立文档**（继歌词 BUG-756、VN BUG-1195 之后的第四种），HTML 本身
    不含正文 `hoshiReader`，自带手势只有 `img.click → onImageTap`（弹图片查看器）。正文有
    `onTapEmpty`、歌词有 `onLyricsTapEmpty`、VN 有 `onVnBlankTap`，spread 页 HTML 一条唤出
    通道都没有——底栏一收起（悬浮模式 / 「点空白隐藏控制栏」）就再也唤不回来，用户看不到
    返回按钮，退不出这本书、回不到书架。
  - ② `hibiki/lib/src/pages/implementations/reader_hibiki/webview.part.dart` 的 `onImageTap`
    处理器没有 `_focusOwnership.reclaim`，OS 焦点留在 WebView → ESC 全局退出失效
    （BUG-136 同族）。spread 页两张整页图铺满视口，点击几乎必然命中 img，于是「唤不出
    底栏」与「ESC 失效」同时成立，两条退出通道一起死 = 卡死在书里。
    **口径更正**：`onImageTap` 不是「全阅读器唯一没 reclaim 的手势入口」。同族至今仍有
    7 处 JS 桥零 reclaim——`onSelectionMenu` / `onImageRevealed` / `onImageContextMenu` /
    `onImageLongPress` / `onCueTap` / `onPointerSeek` / `onLyricsPointerSeek`，其中前四个
    连兄弟桥兜底都没有。本轮只修 spread 退出路径必经的 `onImageTap`，其余未覆盖。
  - ③ **平台分叉（复核阶段新发现，比 ① 更隐蔽）**：`_loadSpreadPage`
    （`reader_hibiki/navigation.part.dart`）传给 `loadData` 的 baseUrl 与
    `_chapterUrl(_currentChapter)` **逐字相同**，而 `onLoadStop` 的陈旧判据只比 `Uri.path`
    （`webview.part.dart:2362-2368`）→ 该判据**分不出** spread 文档和正文章节。
    - Windows fork 的 `loadData` 原生侧只取 data、丢掉 baseUrl
      （`webview_channel_delegate.cpp:104-106` → `NavigateToString`），文档 URL 变
      `about:blank`，path 为空 → 判 stale → 正文引擎从不注入；
    - Android 的 `loadDataWithBaseURL`（`WebViewChannelDelegate.java:117`）保留 baseUrl，
      path 完全相等 → 判据放行 → `_onChapterLoadComplete` **无条件**把整份
      `readerEngineSource`（含 `onTapEmpty` 手势链）注进 spread 文档。
    - 后果：若只做 ① 的修复，Android 上 spread 文档会**同时**挂着 `onTapEmpty` 与新加的
      `onSpreadTapEmpty`。一次空白点两个桥都收到：`onSpreadTapEmpty` 无条件翻转底栏，
      `onTapEmpty` 在悬浮态 / 开了「点空白隐藏控制栏」时也翻转一次 → 两次翻转互相抵消 →
      底栏仍然唤不出来，且比修复前更难查。所以 ① 的修复必须与 ③ 的守卫同批落地。
  - 触发前提：`ReaderSettings.spreadMode` 默认 `'auto'`，打开书时按 OPF 元数据 / 边缘匹配
    **自动**把相邻整页图章节配对成双页——用户从没主动选过这个模式。
- **自动配对到底会卷进哪些书（用户「书架里的书就不应该能变成双页漫画」的核实结果）**：
  - `EpubSpreadMap._shouldPairAuto`（`hibiki/lib/src/epub/epub_spread_map.dart:241-280`）三条
    判据（OPF `page-spread-left/right` 成对 / 书级 `rendition:spread` / 边缘像素匹配）
    **每一条都 `&& isImageOnlyChapter(i) && isImageOnlyChapter(i+1)`**
    （`:259, :266-267, :274-275`）。`isImageOnlyChapter`（`epub_book.dart:123-129`）要求
    章节正文纯文本 ≤ 20 字且含图片引用。
  - 结论：**纯文字 EPUB 小说在 `auto` 下不会进 spread**（正文 >20 字 → 判据直接 false）。
    真正被卷进去的是**图片型 EPUB**：扫描版漫画以 `format='epub'` 导入后走 reader 路径
    （`reader_hibiki_source.dart:506-508, 548-552` 只把 `pdf`/`manga` 分流走），以及带
    `rendition:spread` 的轻小说彩插页。用户说的「变成双页漫画」正是这一类。
  - **为什么不做「按媒体类型门控」**（口径更正：不是「拿不到信号」）：
    本仓**确实已有**可用信号——`MangaArchiveImporter._isPureImageEpub`
    （`hibiki/lib/src/media/manga/import/manga_archive_importer.dart:220-239`），入参正是
    reader 已持有的 `EpubBook`，且已产品化为 `BookConvertBlocker.textOnlyBook`
    （`book_format_convert.dart:42, 117`）；另有 DB 侧逐章 `chaptersJson.characters`。
    不做门控的真实理由是**它对本 bug 零增量、且不修根因**：
    - `_isPureImageEpub` 要求**所有** linear 非 nav 章都 image-only（`:226-227` 一章不满足
      就 false）。用户实际撞的是「**轻小说彩插 + `rendition:spread`**」——正文章节是文字，
      这类书会被判成**文字书**。按它正向门控 ⇒ 这类书本来就不符合，等于什么都没挡（零
      增量）；反向门控（只在纯图书上启用 spread）⇒ 彩插书原样复发。两个方向都不解决用户
      报的那本书。
    - 更根本的是：门控只是把「手势契约不同的独立文档」**精准投递**给会触发它的书，
      spread 文档本身的手势缺口一点没修。根因修复是 ①③（补唤出通道 + 堵掉误注入），
      默认改 `off` 是「不让没选过的用户撞上」，两者已覆盖用户诉求。
    - 相邻空白（本轮不做，留 TODO）：`rendition:layout` / `pre-paginated` **全仓未解析**
      （`grep` 零命中），`hibiki/lib/src/epub/epub_parser.dart:794-805` 解析 `rendition:spread`
      处是唯一的补点。真要做「按书判断该不该双页」，那才是正确的信号来源。
- **[x] ① 已修复** — 四处根因修复：
  - spread 文档补「图片以外的点击」专桥 `onSpreadTapEmpty`（文档级监听 + `IMG` 短路，
    点图片仍走原有查看器）：`reader_hibiki_page.dart` `buildSpreadPageHtml`。
  - Dart 侧接上该桥，镜像歌词 `onLyricsTapEmpty` 的语义：有查词弹窗先清栈；悬浮态走
    `_handleFloatingChromeReveal`、挤压态 `_toggleChrome`，**不看** `tapEmptyToHideChrome`
    （该开关的真实语义是「底栏悬浮 vs 挤压」，不是「允不允许唤栏」；spread 没有别的唤出
    途径，不能被它关死。歌词 `onLyricsTapEmpty` 已立同款先例）；收尾 `reclaim` 阅读焦点。
  - `onImageTap` 补 `_focusOwnership.reclaim(FocusReclaimCause.gesture)`，看完图 pop 回来
    后 ESC 仍能退出（正文内联图片同样受益）。
  - **平台分叉守卫**：新增状态 `_spreadDocumentLoaded`（`reader_hibiki_page.dart`），只有
    两个写点、正好是 WebView 的两个装载原语——`_loadSpreadPage` 置位、`_loadChapterDirectly`
    复位（spread 缺图降级回正文也经过后者，标记不会泄漏）。`_onChapterLoadComplete` 据此
    早退，spread 独立文档不再注入正文引擎 / 有声书桥 / 章节高亮。这是把 Android 拉齐到
    Windows 早已是的行为，而不是给 Android 加特例；对「两张整页图、正文 ≤20 字」的
    image-only 章，那些注入本来就无意义。
  - 按用户要求禁用自动进入：`spreadMode` 默认 `'auto'` → `'off'`
    （`reader_settings.dart` 与 `reader_hibiki_source.dart` 两处兜底同步改，否则
    readerSettings 未就绪时读到的默认与阅读器实际用的相反）。双页展开**选项完整保留**
    （设置里 off/on/auto 三选一），只是不再是没设置过的用户的默认落点；已显式设过本键的
    用户读到的仍是自己的存值。
- **[x] ② 已加自动化测试** — `hibiki/test/reader/spread_chrome_escape_guard_test.dart`（10 条）：
  - **行为级**：把生产 `buildSpreadPageHtml` 里的 `<script>` 原样丢进 node 真跑（最小假
    DOM + 模拟冒泡），断言点 IMG 只出 `onImageTap`、点留白才出 `onSpreadTapEmpty`。
    纯位置断言挡不住「保留 `tagName === 'IMG'` 判断、只删 `return;`」这种变异，这条挡得住。
  - **源码守卫**：`onSpreadTapEmpty` 处理器含两条唤出分支与 reclaim、且代码行不含
    `tapEmptyToHideChrome`；`onImageTap` 含 reclaim；`_onChapterLoadComplete` 的 spread 守卫
    在正文引擎注入之前、且 if 块**自身**含 `return;`（窗口用花括号配对，不用字符距离）；
    `_spreadDocumentLoaded` 的置位/复位两个写点都在。
  - **跨文件一致性**：`ttu_spread_mode` 两处兜底默认必须相等且为 `off`（只改其中一处的
    变异会被这条抓住）。
  - **真行为**：`ReaderSettings` 默认 `off`；显式设 auto/on/off 照旧生效。
  - **变异实测 5 次，全部转红（退出码 1）**：① 保留 IMG 判断只删 `return;` → 行为级用例红；
    ② 只把 `reader_hibiki_source.dart` 的默认改回 `'auto'` → 一致性用例红；
    ③ 保留 spread 守卫的 if 只删 `return;` → 红；④ 删 `_loadChapterDirectly` 的复位 → 红；
    ⑤ 删 `_loadSpreadPage` 的置位 → 红。
    其中 ③ 第一版守卫**假绿**（`return;` 的搜索窗口从守卫一直到注入点，混进了歌词分支自己
    的 `return;`），已收紧为 if 块自身再复测转红——变异实测当场抓到的假绿。
- **备注**：
  - 🔴 **本次修复在 Android 上有一处真实的能力损失，必须记账**：③ 的守卫堵掉的那份误注入，
    此前**顺带**给 Android 的 spread 页提供过 `onSwipe` 滑动翻页与键盘桥（正文引擎自带）。
    守卫生效后它们一并消失 ⇒ **Android 用户在双页页面上会失去滑动翻页**，只能唤出底栏后用
    底栏按钮 / 键盘 / 手柄翻页。这不是「单纯修好一个 bug」，是拿「双触发导致底栏彻底唤不出
    （退不出书）」换「少一种翻页手势」——卡死是致命的、少一种手势是可降级的，所以这笔交易
    值得做，但**不得淡化**。
    Windows 侧无此损失（那边从来就没被注入过，本来就没有 spread 滑动翻页）。
  - **TODO（跟进补回）**：给 spread 独立文档补它自己的 `onSwipe` 脚本 + 键桥，与歌词 / VN
    独立文档同款自带手势，而不是靠正文引擎误注入白捡。补回后两个平台的 spread 手势契约才
    真正对齐（目前是「两平台一致地少了滑动翻页」）。
  - 真机复测（Android / Windows 原始路径：书架 → 打开含整页图的书 → 显式设 spreadMode=on →
    收起底栏 → 点 letterbox 留白）未做；③ 的平台分叉是静态证据链（Dart 调用点 + 两侧原生
    实现 + 陈旧判据三处对齐），未在真机上观测过双触发。
