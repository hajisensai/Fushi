## BUG-3415 · 歌词模式点查词弹窗词典折叠标题后弹窗整个关闭
- **报告**：2026-10-14（用户：iOS 真机录屏，竖排歌词模式点词出底部停靠查词弹窗，点弹窗里「新選国語辞典 第十版」折叠标题——标题呈 `:active` 灰底——弹窗紧接着整个关闭（无淡出）、播放卡重新露出；反复 3 次，看起来在闪）
- **真实性**：❓ 未复现。读代码：弹窗内 `summary` 点击在 `fushi/assets/popup/popup.js` 的文档 click 处理里直接 return，不发 `tapOutside`；折叠触发的 `popupContentResized` 在底部停靠时被 `base_source_page.dart` `onContentMetrics` 忽略；歌词独有的三个关闭出口（`lyrics_player_overlay.dart` 背景 `onTapBackground`、歌词 JS `onLyricsTapEmpty` / `onLyricsCueTap`）与查词 barrier 都要求触摸落在弹窗外。Mac iOS 26.5 模拟器取证：
  - Flutter 逐层 hitTest（弹窗中心 / 顶栏）：路径为弹窗 `RenderUiKitView` → `_BodySwipeDismissDetector` opaque Listener → 页面 Stack，歌词模式与阅读模式一致，不含歌词背景与 barrier。
  - 正常 `main` 起的 debug app + XCUITest 真 UIKit 触摸：点弹窗内词典标题（y≈76% 屏高，含歌词 WKWebView 与弹窗 WKWebView 原生重叠带 y≈557–605 内一点），弹窗 WebView 收到完整 touch/click、`<details>` 正常折叠，弹窗不关；歌词 / 正文 WebView 零触摸；竖排、横排、阅读模式对照均同。
  - 唯一异常一次：首次点击 Flutter 发 `PointerCancelEvent`、弹窗 WebView 收到 `touchcancel`、标题未折叠，弹窗也未关；未再现。
- **[ ] ① 未修复** — 无可复现路径，不做猜测性修改。
- **[ ] ② 未加自动化测试** —
- **备注**：与用户环境的可能差异：真机手指位移（弹窗本体 / barrier 的触摸滑关，但那条有滑出淡出动画，与「无淡出」不符）、release 构建、真实词典数量、用户是重开书直接恢复成歌词模式（`_pendingLyricsRestore` 路径未覆盖）、点标题前是否有嵌套弹窗。下一步：真机开诊断日志复现，或把 `_dismissPopupAt` / `clearDictionaryResult` 调用栈日志临时编进 TestFlight 包取一条真机栈。Mac 探针 worktree `~/dev/hibiki-lyricsvert`（`lvapp_run.sh`，XCUITest 装置 `~/dev/lvtouch`）保留可复跑。
