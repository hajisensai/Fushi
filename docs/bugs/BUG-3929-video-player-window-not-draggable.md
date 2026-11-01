## BUG-3929 · Windows 进入视频播放器后窗口拖不动（主界面正常，上一版正常）
- **报告**：2026-11-01（用户：应用内反馈 BEX2_5K1zV，Windows，3.1.0-debug.22337）
- **真实性**：✅ 真回归。d094597e7f（2026-10-30）把视频 / 阅读器 / 漫画 / 歌词等「上报了页面配色」的沉浸页改成占满整窗、自绘标题行（拖动区 + 窗口按钮）平时隐去且 `IgnorePointer`；a7a3c7a8bc（10-31）再把浮出条件收紧为「指针在窗口最顶边 8px 停留 400ms」。根因 `fushi/lib/src/utils/components/fushi_desktop_title_bar.dart` `_ImmersiveCaptionReveal._shown`：浮出只认顶边停留 / 键盘焦点 / 触摸 / 原生最大化键悬停，与页面自己的 chrome 无关——Windows 窗口化时那 8px 正好压着顶边 resize 把手（光标是缩放箭头），播放中想拖窗口几乎摸不到入口，用户读作「播放器里窗口拖不动」。上一版标题行常显，所以正常。
- **[x] ① 已修复** — 新增页面级浮出请求 `FushiDesktopTitleBar.setCaptionRevealed` + `FushiTitleBarRevealScope`（owner 语义、被整页盖住时撤回，同配色 / 接管两套 scope）；沉浸标题行在有请求时浮出，且已浮出时指针进带子即保持显示（控制条随后自动收起也不在指针下隐去）。视频页用控制条真实可见态（`_mediaKitControlsVisible`）登记：控制条一出来，窗口按钮与拖动区就在（mpv / PotPlayer 同款）。阅读器 / 漫画不登记，保持「顶部正文可点查词」的既有行为。
- **[x] ② 已加自动化测试** — `fushi/test/desktop/fushi_title_bar_page_colors_test.dart`「页面 chrome 浮出时标题行跟着浮出；指针在带子里时控制条收起也不隐去」「被另一整页盖住时撤回浮出请求」（Windows / macOS 宿主各一遍）。
- **备注**：未在真机复测拖窗（本轮反馈批处理不做设备验证）。
