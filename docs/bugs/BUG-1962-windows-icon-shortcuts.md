## BUG-1962 · Windows 换图标未同步固定任务栏且启动后快捷方式不自愈
- **报告**：2026-08-30（用户：换了图标之后任务栏里和桌面不会变）
- **真实性**：✅ 真 bug。运行时窗口链 `fushi/windows/runner/flutter_window.cpp:2408-2436` 已正确用 WIC + `WM_SETICON`，Dart 也已生成内容哈希命名的多尺寸 ICO；断点在快捷方式覆盖范围与恢复时机：`ApplyShortcutIcon`（同文件 `:326-354`）只改桌面及开始菜单，并在注释中明确跳过任务栏固定项；`fushi/lib/main.dart:277-289` 冷启动只恢复当前窗口图标，不重写被安装器恢复为 exe 默认 `IconLocation=,0` 的快捷方式。同一预设又会在设置页提前返回，无法靠重选自愈。
- **[x] ① 已修复** — `bbdf2d91c8`：把安装器管理的 `User Pinned\\TaskBar\\Fushi.lnk` 纳入同一 `IShellLink::SetIconLocation` 链；仅在其最终规范路径与当前 exe 一致时改写，避免碰同名/旧安装快捷方式。Windows 冷启动成功恢复窗口图标后，用同一图片字节重新同步桌面、开始菜单和固定任务栏快捷方式，使安装器重置后也能自愈。
- **[x] ② 已加自动化测试** — `bbdf2d91c8`：扩 `fushi/test/native/windows_shortcut_icon_guard_static_test.dart`，钉住 pinned Known Folder 路径、target 最终路径校验、启动恢复调用，并保留现有多尺寸 ICO、Shell link 与通知契约；与 ICO 编码/滚轮测试合跑共 17 tests 全绿。
- **备注**：不重写运行中的 PE/不破坏签名，不引入可能改变任务栏分组的 AppUserModelID，也不扫描或改写用户自建的其它快捷方式。真机需确认三处 `Fushi.lnk` 的 IconLocation 均指向当前哈希 ICO，并验证覆盖安装后启动可自愈。
