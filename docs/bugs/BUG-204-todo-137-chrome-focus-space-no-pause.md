## BUG-204 · 底栏焦点点空格不暂停音频
- **报告**：2026-06-11（用户：焦点在书籍底栏的时候，点空格不会暂停音频）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart` `_handleKeyEvent`：`_chromeFocusScope.hasFocus`（焦点落底栏控件）分支里，除 arrowUp / gameButtonB / Escape 外对所有键（含裸 Space）`return KeyEventResult.ignored`，Space 到不了下方的 `resolveReaderSpaceOverride`（audiobookPlayPause 覆写），冒泡到 `global_navigation.dart:189` 的 `SingleActivator(space)` → `DoNothingIntent` 被中和（c152fcd91 用户裁定的正确全局行为），有声书不暂停。BUG-062 的 Space 暂停只覆盖了正文焦点路径，底栏焦点路径漏接。
- **[x] ① 已修复** — chrome-focus 分支在 catch-all `ignored` 之前，用同一 `resolveReaderSpaceOverride`（闸门：有声书激活 + 无修饰 Space）路由到 `audiobookPlayPause`；其余键仍落 `ignored`，底栏控件本身的 Space 语义不受影响。**不回退裸空格中和**。顺带把键盘解析里重复的修饰键集合构建抽成 `_activeModifiers()`、有声书激活判据抽成 `_hasActiveAudiobook` getter，正文/底栏两路径共用。提交：<待补>
- **[x] ② 已加自动化测试** — 新增 `hibiki/test/reader/reader_chrome_space_pause_test.dart`：纯函数断言 `resolveReaderSpaceOverride`（与正文路径同一闸门）在「有声书激活 + 无修饰 Space」返回 `audiobookPlayPause`、其余返回 null；+ 扩源码守卫断言 chrome-focus 分支内确有 Space→override 路由且未回退裸空格中和。提交：<待补>
- **备注**：真机复验留用户（底栏焦点 Space 暂停音频）。
