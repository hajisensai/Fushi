## BUG-205 · Windows悬浮字幕条拖不动/无锁按钮/无法缩放
- **报告**：2026-06-11（用户：「这个电脑的悬浮字幕什么jb玩意·没办法放大·拖动·点击·没有锁按钮」）
- **真实性**：✅ 真 bug（三处独立根因，均在 Win32 后端 `hibiki/windows/runner/`）

### 根因
1. **拖动失灵** — `floating_lyric_window.cpp:334-348`（WM_LBUTTONDOWN）。`click_lookup_enabled_` 默认为 `true`，落在文字上的左键一律走 `CharIndexAt`→`on_lookup_` 查词后 `return`；只有点到**空白**才进 `:349-358` 的拖动分支。720px 宽的条几乎被字幕文字占满，可拖区域近乎为零 → 用户感知「拖不动」。设计上没有「专用拖动手柄」也没有「修饰键拖动」的逃生口。
2. **锁按钮缺失 + setLocked 是 no-op** — `flutter_window.cpp:444-448` 把 `setLocked` 实现成空操作（注释「desktop strip has no lock affordance」）。`floating_lyric_window.cpp` 只画 prev/playPause/next/close 四键（`:537-540`），`ControlActionAt` 只识别 4 槽（`:578` `slot<4`），`controls_total = btn*4`（`:503`）。Dart 端 `floating_lyric_channel.dart` 的 `setLocked`/`lockChanged`/`updateLabels(lock/unlock)` 早已就绪（Android 在用），Win32 后端从未接线。
3. **缩放缺失** — `kStripWidthDip=720`/`kStripHeightDip=96` 是 `constexpr`（`:22-23`），窗口尺寸写死，`HandleMessage` 无 `WM_NCHITTEST`/resize 处理，用户无法改变条的大小。

### 对齐 Android（BUG-150 位置锁语义）
Android `FloatingLyricService.isDragLocked()` 返回 `isLocked`（`:166-168`），锁后**只禁拖动**，点击查词 + 播放控制照常。Win32 后端按此语义实现：locked 时拖动分支早退，查词路径（`:334-348`）和控制按钮路径不受影响。

- **[x] ① 根因修复** — `floating_lyric_window.{h,cpp}` 加第 5 个锁按钮 + `locked_` 状态门控拖动；`flutter_window.cpp` setLocked 改真实现 + lockChanged 回 Dart；WM_NCHITTEST 拖右下角缩放（条宽高可变，字号/布局跟随）；reader_hibiki_page.dart `onLockChanged` 接线（debug 日志，无 app 内镜像）。修复提交见本分支 `codex/todo-136-desktop-floating-lock-resize`。
- **[x] ② 自动化测试** — `floating_lyric_click_through_guard_test.dart` 扩展源码扫描守卫：点穿契约仍绿 + 锁按钮(slot 5)/locked_ 门控拖动/setLocked 真实现(非 no-op)/WM_NCHITTEST resize 的源码守卫。测试文件：`hibiki/test/media/audiobook/floating_lyric_click_through_guard_test.dart`
- **备注**：Win32 native 无法在 host 跑，守卫是源码扫描；实际锁/拖/缩放观感仅 Windows 真机可验，诚实留用户。
