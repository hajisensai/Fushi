## BUG-1859 · gal 查词浮窗穿透态滚轮不滚：ScrollBy 的 pass_through_ 门是 WS_EX_TRANSPARENT 时代遗物
- **报告**：2026-08-25（用户：截图圈出 hook 台词浮窗右侧滚动条，「在穿透模式下没法滚轮」）
- **真实性**：✅ 真 bug。根因 `fushi/windows/runner/floating_lyric_window.cpp` `ScrollBy()`（改前 `if (!hook_text_mode_ || pass_through_ || scroll_max_px_ <= 0.0f) return false;`）。
  - 这条 `pass_through_` 判据是 BUG-951 时代写的：那时穿透态正文窗带 `WS_EX_TRANSPARENT`，系统不投任何鼠标消息，判据只兜「置位到应用 ex-style 之间那一瞬」。
  - BUG-1480 把穿透态改成**逐像素 alpha 命中**（`ApplyPassThroughExStyle` 明确不再设 `WS_EX_TRANSPARENT`，`Render` 把背景压成真 alpha 0）：OS 在合成阶段分流——落在字形（BUG-1853 后是整个行盒）上的鼠标事件归浮窗，落在 alpha-0 背景上的归游戏。于是穿透态下滚轮**能**投到 `WM_MOUSEWHEEL`，却被 `ScrollBy` 的旧门拦下、落到 `DefWindowProc`；这窗没有父窗，事件既不滚文本也到不了游戏，就是「没法滚轮」。
  - 同一份判定在点击上早就放开了（穿透态点字查词），滚轮还留着门 = 两条路径对「穿透态鼠标归谁」的回答不一致。
- **[x] ① 已修复** — `ScrollBy` 去掉 `pass_through_` 门，只剩「hook 模式 + 真有溢出」；写偏移收成唯一入口 `SetScrollOffset()`（滚轮与 BUG-1860 拖 thumb 共用）；`WM_MOUSEWHEEL` 注释改写为「穿透态不是例外，与 BUG-1480 同一份判定」。提交见 PR（叠在 PR #1003 之上）。
- **[x] ② 已加自动化测试** — `fushi/test/build/gal_overlay_scroll_guard_test.dart` ⑤ 改断新前置条件、新增 ⑧：`ScrollBy` / `SetScrollOffset` 源码不含 `pass_through_`，`WM_MOUSEWHEEL` 不准自己加穿透态分支。
- **备注**：C++ 分层窗无法在 Dart 测试里执行，测试层是源码守卫；真机复验清单：穿透态开、文本溢出、鼠标停在文字上滚轮→文本滚动，停在背景上滚轮→游戏收到。本轮未真机复验。
