## BUG-2382 · 移动端打开阅读器导航抽屉即自动弹出软键盘
- **报告**：2026-09-09（用户：移动端「导航打开后不要自动打开键盘」）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/pages/implementations/reader_fushi/chrome.part.dart:2067`（修前）：
  ```dart
  autofocusSearch:
      presentation == ReaderQuickSettingsPresentation.sideSheetNavigation,
  ```
  判据只看**呈现形态**、不看平台。而导航抽屉在**所有平台共用**（同文件 :1769 注释
  「所有平台共用左侧导航与右侧设置」，只有有声书面板按宽窄分流），于是手机上点工具栏
  目录键 → 抽屉滑出 → `FushiTextField(autofocus: true)`
  （`fushi/lib/src/media/audiobook/reader_quick_settings_sheet.dart:980`）立刻请求
  `TextInput.show` → 软键盘顶起，把抽屉里本来是主角的**章节目录**压到剩下的半屏
  （抽屉是全高路由 `showReaderSideSheet`，键盘的 viewInsets 直接吃掉下半部分）。
  用户想点一章跳过去，得先按返回键收键盘。桌面端没有这个代价（物理键盘、不占屏），
  Ctrl+F 唤出后光标落进搜索框正是那个动作的自然续写——所以修的是**平台判据缺失**，
  不是把 autofocus 一刀砍掉。
- **[x] ① 已修复** — 新增纯函数判据 `readerNavigationAutofocusesSearch`
  （`fushi/lib/src/reader/reader_desktop_chrome.dart`，与 `readerAudiobookUsesDialog`
  / `readerWebViewPointerClosesSideSheet` 同处一个真相源），接线改成
  `navigationPresentation && desktop`（`desktop: isDesktopPlatform`）。
  桌面端行为逐字不变；移动端点搜索框仍照常弹键盘，主动权交回用户。提交：本提交。
- **[x] ② 已加自动化测试** — `fushi/test/reader/reader_nav_autofocus_bug2382_test.dart`（本提交）：
  - 纯函数四态（导航×桌面/移动、非导航×两端）；
  - 源码守卫：接线必须走判据，旧的「导航形态即 autofocus」裸比较不得复活；
  - **widget 行为测试**（最强可落地层）：真 pump `ReaderQuickSettingsSheet`
    的 `sideSheetNavigation` 形态，断言 `tester.testTextInput.isVisible`
    —— 即「引擎有没有收到 `TextInput.show`」，也就是真机上软键盘会不会顶起来，
    而不是「焦点在哪」这种代理指标。`autofocusSearch: true` 一支断言 isVisible==true，
    同时证明搜索框确实在场（否则 false 那支会是假绿）。
- **验证**（按退出码判绿）：
  - `flutter test test/reader/reader_nav_autofocus_bug2382_test.dart --no-pub` → 4 例全绿，exit=0。
  - `flutter analyze`（fushi）→ No issues found。
- **备注**：本机无可用 Android 模拟器 / 真机（`flutter emulators` 为空、`adb devices` 无设备），
  移动端原始路径的肉眼复测未做；行为由上述 `testTextInput` 断言在 widget 层钉死。
