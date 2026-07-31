## BUG-1280 · 双页 spread 页唤不出底栏、退不出书
- **报告**：2026-07-31（用户："书架里面打开，然后自动变成双页漫画" → 唤不出菜单、退不出去）
- **真实性**：✅ 真 bug。根因两层，各自独立致命：
  - ① `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart:494` `buildSpreadPageHtml`
    生成的双页展开页是**独立文档**（继歌词 BUG-756、VN BUG-1195 之后的第四种），不含正文
    `hoshiReader`。它此前唯一的手势是 `img.click → onImageTap`（弹图片查看器）。正文有
    `onTapEmpty`、歌词有 `onLyricsTapEmpty`、VN 有 `onVnBlankTap`，**spread 一个唤出底栏的
    通道都没有**——底栏一收起（悬浮模式 / 「点空白隐藏控制栏」）就再也唤不回来，用户看不到
    返回按钮，退不出这本书、回不到书架。
  - ② `hibiki/lib/src/pages/implementations/reader_hibiki/webview.part.dart` 的 `onImageTap`
    处理器是全阅读器**唯一**没有 `_focusOwnership.reclaim` 的手势入口（`onTapEmpty` /
    `onLyricsTapEmpty` / `onSwipe` 都有），OS 焦点留在 WebView → ESC 全局退出失效
    （BUG-136 同族）。spread 页两张整页图铺满视口，点击几乎必然命中 img，于是「唤不出
    底栏」与「ESC 失效」同时成立，两条退出通道一起死 = 卡死在书里。
  - 触发前提：`ReaderSettings.spreadMode` 默认 `'auto'`，打开书时按 OPF 元数据 / 边缘匹配
    **自动**把相邻整页图章节配对成双页——用户从没主动选过这个模式。
- **[x] ① 已修复** — 三处根因修复：
  - spread 文档补「图片以外的点击」专桥 `onSpreadTapEmpty`（文档级监听 + `IMG` 短路，
    点图片仍走原有查看器）：`reader_hibiki_page.dart` `buildSpreadPageHtml`。
  - Dart 侧接上该桥，镜像歌词 `onLyricsTapEmpty` 的语义：有查词弹窗先清栈；悬浮态走
    `_handleFloatingChromeReveal`、挤压态 `_toggleChrome`，**不看** `tapEmptyToHideChrome`
    （spread 没有别的唤出途径，不能被那个开关关死）；收尾 `reclaim` 阅读焦点。
  - `onImageTap` 补 `_focusOwnership.reclaim(FocusReclaimCause.gesture)`，看完图 pop 回来
    后 ESC 仍能退出（正文内联图片同样受益）。
  - 按用户要求禁用自动进入：`spreadMode` 默认 `'auto'` → `'off'`
    （`reader_settings.dart` 与 `reader_hibiki_source.dart` 两处兜底同步改，否则
    readerSettings 未就绪时读到的默认与阅读器实际用的相反）。双页展开**选项完整保留**
    （设置里 off/on/auto 三选一），只是不再是没设置过的用户的默认落点；已显式设过本键的
    用户读到的仍是自己的存值。
- **[x] ② 已加自动化测试** — `hibiki/test/reader/spread_chrome_escape_guard_test.dart`（7 条）：
  生成器断言（空白桥存在 / IMG 短路在回传之前 / 不吃掉 onImageTap / TODO-1229 就绪门控不
  回退）+ 源码接线守卫（`onSpreadTapEmpty` 处理器含两条唤出分支与 reclaim、且不含
  `tapEmptyToHideChrome`；`onImageTap` 含 reclaim）+ `ReaderSettings` 真行为测试
  （默认 `off`；显式设 auto/on/off 照旧生效）。
  **变异实测**（5 次，逐条撤回 → 对应用例转红，无假绿）：删空白桥 → 2 红；删 IMG 短路 →
  1 红；删 `onSpreadTapEmpty` 的 reclaim → 1 红；删 `onImageTap` 的 reclaim → 1 红；
  默认值改回 `auto` → 1 红。
- **备注**：
  - 已知相邻缺口（本轮未扩大范围）：spread 独立文档同样没有 `onSwipe` 脚本，触屏在双页页面
    上无法滑动翻页，只能靠唤出底栏后用底栏按钮 / 键盘。修好唤出通道后已不再卡死，但手势
    契约仍与正文不对齐。
  - 真机复测（Android / Windows 原始路径：书架 → 打开含整页图的书 → 显式设 spreadMode=on →
    收起底栏 → 点 letterbox 留白）未做。
