## BUG-962 · 文本框物理键盘空格被全局 DoNothingIntent 吞掉
- **报告**：2026-07-21（用户：群主）
- **真实性**：✅ 真 bug，根因 `hibiki/lib/src/shortcuts/global_navigation.dart:328`（原 `const SingleActivator(LogicalKeyboardKey.space): const DoNothingIntent()`）
- **现象**：重命名合集等对话框的输入框里，物理键盘按空格打不出空格；只有点右侧屏幕键盘图标（走 IME text-input 通道）才能插入空格。「脱裤子放屁」。
- **根因**：`wrapWithGlobalNavigation` 把 `space → DoNothingIntent` 无条件挂进全局 `Shortcuts`。`DoNothingAction.consumesKey` 恒为 `true`，故**无条件吞掉空格按下沿**，包括文本框聚焦时。`EditableText` 对裸空格没有任何 text-editing 动作（空格靠字符输入通道插入），不会在近处被 `onKeyEvent` 消费，于是一路冒泡到全局被吞。物理键盘走 KeyEvent 管线 → 被 handled 截断，引擎不再把空格转给 text-input；屏幕键盘走 IME text-input 通道，绕过快捷键层 → 能打。原注释（316-320 行）自称「文本框输入空格被更近作用域消费，到不了这里」，该假设错误。
- **[x] ① 已修复** — commit 见下。把中和从无条件 `Shortcuts` 表条目重构为 `_neutralizeBareSpace(event)`：仅在按下沿（`KeyDownEvent`）且 `focusedEditableText() == null`（无文本框聚焦）时返回 `handled` 中和；文本框聚焦时返回 `ignored` 放行，空格冒泡到 text-input 正常插入。挂在外层 `Focus.onKeyEvent` 最前（始终生效，先于框架 `space→ActivateIntent`），与已有 `_handleGlobalBack` 的 `focusedEditableText()` 门控同范式。焦点确认不走空格（Enter/手柄 A）与阅读器翻页/视频·有声书暂停均不变（后者在更近作用域先消费空格）。文件 `hibiki/lib/src/shortcuts/global_navigation.dart`。
- **[x] ② 已加自动化测试** — `hibiki/test/shortcuts/global_space_no_activate_test.dart`：新增「哨兵祖先 Focus」范式两条——控件聚焦时空格被消费（不冒泡到祖先）、文本框聚焦时空格放行冒泡（可落到 text-input），焦点导航开/关都断言。修复前后者必挂（DoNothingIntent 吞掉空格），修复后通过。另更新 `hibiki/test/reader/reader_chrome_space_pause_test.dart` 源码守卫：锚点从旧 `SingleActivator(space)` 改为 `_neutralizeBareSpace(`，并加固断言 `focusedEditableText() != null` 门控不得回退。
- **备注**：屏幕键盘图标（`TextField` 的 IME 触发）行为不变；本修复只让物理键盘空格与之一致。
