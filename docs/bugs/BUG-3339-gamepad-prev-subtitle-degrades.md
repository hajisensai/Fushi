## BUG-3339 · 手柄「上一句字幕」退化成固定秒数回退
- **报告**：2026-10-14（反馈 #e6hKBVvAcQ，Android 手柄 + 扩展在线播放：上一句「像固定约 3 秒倒退，连跳一两下才到句首」；屏幕双击左右跳句正常）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/video_fushi_page.dart:7186-7195`（修复前）——`_buildVideoShortcutActions` 的 `previousSubtitle` 写死 `degradeFarCueToTimeSeek: true`（键盘 Ctrl+← 的方向键心智，TODO-085：上一句起点距当前 > seekSeconds 时退化成回退 seekSeconds 秒）；手柄 `_handleVideoGamepadButton`（:7445）、鼠标侧键 `_handleVideoPointerDown`、屏幕自定义按钮、选词光标手柄分支都复用同一份执行体，于是按钮类输入也退化。屏幕双击走 `_skipCueAndPokeControls`（默认不退化，BUG-942），所以两条路径行为分叉。注释（:7179）本就写着「手柄恒跳句」，实现与之不符。
- **[x] ① 已修复** — 输入种类成为构造动作表的必填参数 `VideoActionInput { keyboard, button }`（`video_player_shortcuts.dart`）；退化开关 = `videoPrevSubtitleDegradesFarCue(input)`，只有键盘（页级 press-time 通道 + 字幕对轴弹窗 activator 表）退化，手柄 / 鼠标侧键 / 屏幕按钮 / 光标手柄分支传 `button`、恒跳句。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_gamepad_input_semantics_test.dart`（纯函数 + 每个派发点的 input 实参守卫 + 参数必须 required）。
- **备注**：键盘 Ctrl+← 的退化行为保持不变（TODO-085 用户设计）。未在真机手柄上复测（缺口）。
