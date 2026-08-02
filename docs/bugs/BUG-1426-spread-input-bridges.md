## BUG-1426 · 双页 spread 页滚轮与左右翻页失效
- **报告**：2026-08-02（用户截图：EPUB 轻小说彩插被自动配成双页展开，"进入这个界面以后，滚轮和左右翻页失效"）
- **真实性**：✅ 真 bug。根因是 **BUG-1280 ③ 的守卫留下的账**，不是新回归：
  - spread 页是 `buildSpreadPageHtml`（`hibiki/lib/src/pages/implementations/reader_hibiki_page.dart:497`）
    生成的**独立文档**（第四种，继歌词 BUG-756 / VN BUG-1195 / spread BUG-1280）。它原本
    自带的桥只有三条：`onImageTap`（点图片看原图）、`onSpreadTapEmpty`（点留白唤底栏）、
    `spreadReady`（就绪信号）。**一条翻页输入都没有。**
  - 而滚轮（`wheel` → `onWheelPaginate`）、横扫（`touchend` → `onSwipe`）、键桥
    （`webViewKeyBridgeScript`）**全长在正文引擎里**，由
    `_onChapterLoadComplete`（`reader_hibiki/webview.part.dart:2528`）注入——那里第一句就是
    BUG-1280 ③ 的守卫：`if (_spreadDocumentLoaded) return;`。于是 spread 文档一条都拿不到。
  - 两个平台的到达路径不同，结果相同：
    - **Windows**：`loadData` 的原生实现是 `NavigateToString`（丢 baseUrl），`onLoadStop`
      的陈旧判据只比 `Uri.path` → 判 stale → 正文引擎**从来**没注入过 spread 文档。
      所以 Windows 上双页页面**自始至终**没有滚轮翻页，不是本次才坏的。
    - **Android**：`loadDataWithBaseURL` 保留 baseUrl → 判据放行 → BUG-1280 修复**之前**
      顺带白捡过正文引擎的滚轮/横扫/键桥；守卫落地后一并消失。BUG-1280 备注里已明确记账
      （"Android 用户在双页页面上会失去滑动翻页…不得淡化"）并留了 TODO：**"给 spread
      独立文档补它自己的 onSwipe 脚本 + 键桥"**。本条就是那笔账。
  - 键盘那一半还叠了 TODO-1078 / BUG-136 同源的焦点问题：Windows 的 WebView2 一旦持有 OS
    焦点，按键只存在于 DOM 里，Flutter 的 `Focus.onKeyEvent` 收不到——正文靠注入的键桥回传，
    spread 文档没有键桥，所以方向键也一起没反应。
  - **用户为什么会进到这个界面**：生产库 `src:reader_ttu:ttu_spread_mode = 'auto'`（**显式存值**，
    BUG-1280 把默认改成 `off` 只对没设置过的用户生效），且该书的边缘匹配缓存
    `spread_match:安達としまむら = {"0":true,...,"7":true}` 有成对页 → 自动配成双页。
    截图那本是 `epub_books.format='epub'` 的轻小说（安達としまむら系列），走 reader 路径，
    与 BUG-1280 里"轻小说彩插 + rendition:spread"是同一类。
- **[x] ① 已修复** — 让 spread 独立文档**自带**三条输入通道，且**全部直连既有 Dart handler**，
  Dart 侧不新增任何翻页语义（节流 / 跨章冷却 / 虚拟页翻页仍是 `_paginate` →
  `_handlePageTurnLimit` 那一份）：
  - **滚轮**：`buildSpreadPageHtml` 加文档级 `wheel` 监听 → `onWheelPaginate(dir, axis)`，
    与正文 `_handlePagedWheelTick` 逐字同款语义（主轴取绝对值更大的那个，`delta > 0` =
    forward，`preventDefault`）。Dart 侧 handler 未改。
  - **横扫**：`touchstart`/`touchend` → `onSwipe('left'|'right')`，判据与阈值同正文 `touchend`
    分支（横向分量占优 + `dist` 或 `fastDist`+900px/s 二选一，`dx < 0` = `'left'`）。阈值由
    `_loadSpreadPage` 从 `ReaderSettings.swipePageTurnDistThresholds`（随灵敏度设置缩放的
    **同一真值**）取，spread 侧不另立默认。
  - **键盘**：新 `onSpreadKey` 桥。token 表由 `spreadKeyBridgeTokens` 按注册表**当前**绑定
    实时导出（翻页 / 唤收底栏 / 退出书四个动作），改键即时跟随——不重蹈漫画页旧桥写死
    `ArrowLeft/ArrowRight` 的覆辙（BUG-1347）。Dart 侧 `InputBinding.deserialize` →
    与 Flutter 焦点路径**同一个** `resolveKeyboard` → `_executeShortcutAction` → reclaim 焦点。
    **裸 Space 恒排除**：它归与正文逐字同款的 `onSpaceKey` 桥（经 `resolveReaderSpaceOverride`
    分流"有声书激活 → 播放/暂停"），两座桥都在本 document 装 `keydown`，不排除就翻两页。
  - **合成 click 抑制**：横扫后浏览器仍会合成一次 `click`，不拦就会同时命中 `onImageTap`
    （弹图片查看器）。capture 阶段单点吞掉（700ms 一次性窗口，不粘住后续真实点击）。
  - 顺带把 `swipe_page_turn_sensitivity` 的兜底默认提成
    `ReaderSettings.defaultSwipePageTurnSensitivity`——它现在有了第二个读取方（settings 未
    就绪时的 spread 装载），两处各写字面量 `1.0` 会让改默认手感只改到一半。
- **[x] ② 已加自动化测试** — `hibiki/test/reader/spread_page_turn_input_test.dart`（10 条）：
  - **行为级**（把生产 `buildSpreadPageHtml` 的 `<script>` 原样丢进 node 真跑，最小假 DOM +
    capture/bubble 分桶）：滚轮下滚=forward / 上滚=backward / 主轴取绝对值更大者 / 零位移不翻页；
    横扫过阈值才翻且方向正确、纵向拖动与亚阈值抖动不翻页；横扫后的合成 click 在 capture 被
    吞掉且不到达任何桥，而**之后**的真实点击照常开图片查看器。
  - **token 表真行为**：未装载注册表给空表；导出的每个 token 都能反解析回声明的动作集；
    裸 Space 恒不在表内；改键后表跟着变（`KeyN`）。
  - **源码守卫**：`onSpreadKey` handler 走 `InputBinding.deserialize` + `resolveKeyboard` +
    `_executeShortcutAction` + reclaim；`_loadSpreadPage` 真的把阈值/键桥/Space 桥都传进去；
    spread 复用的既有 handler（`onWheelPaginate` / `onSwipe`）仍在。
  - 既有 `spread_chrome_escape_guard_test.dart` 的 node runner 同步升级成按 (type, capture)
    分桶 + capture 先跑可 `stopPropagation`，原断言强度不变（文档级 click 桥仍恰好一个）。
  - `reader_spread_image_ready_gate_test.dart` 的 `buildSpreadPageHtml(leftUrl:` 连写断言放宽为
    「调用 builder + 传 leftUrl」——加参数后调用点被 format 折行，那条是拼写脆弱不是契约破裂。
  - **变异实测 5 次**（见下方备注，结果附在 PR 里）。
- **备注**：
  - 🔴 **本次没做鼠标拖动翻页**。正文在桌面有 pointer-drag 翻页（`_finishHoshiReaderMouseDrag`
    → `onSwipe`），spread 只补了 touch 横扫。理由是它与图片查看器的 click 语义纠缠更深
    （在图上按下拖动 = 选择/拖图），而桌面的主诉滚轮已经修好。**这是已知缺口，不是遗漏。**
  - 键桥 token 表在**装载 spread 文档那一刻**求值，用户改键后需重新进一次双页页面才生效
    （每次进 spread 都重新生成 HTML）。可接受，且与"每章重注入"的正文行为同构。
  - 未做真机复测：Windows 原始路径（书架 → 打开彩插书 → spreadMode=auto 自动进双页 → 滚轮/
    方向键翻页）与 Android 横扫都只有静态证据链 + node 行为级测试，没在真机上观测过。
