## BUG-221 · 默认主题书籍正文背景不吃背景色(恒白)
- **报告**：2026-06-12（用户：TODO-165「默认主题(强调色那个=system-theme)下书籍正文背景没吃背景颜色」）
- **真实性**：✅ 真 bug。BUG-208/TODO-143 修了阅读器**外壳** WebView 背景跟随主题
  （`resolveReaderThemeColors` + `_themeBackgroundColor` 等 getter），但**正文 `<body>`
  CSS 背景**这一路漏了。根因双点：
  - `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart:1830/1861`：CSS 注入处
    门控 `customBg: _isCustomTheme ? _readerBackgroundHex : null`。system-theme（默认主题）
    时 `_isCustomTheme=false` → 传 `customBg: null`，把 `_readerBackgroundHex`（经
    `resolveReaderThemeColors` 早已派生出真实 ColorScheme.surface 的正确背景）丢弃。
  - `hibiki/lib/src/reader/reader_content_styles.dart:531-532`：`_themeColors` 的 `default`
    分支（system-theme/light-theme/未命中 preset 的 key 都落这里）返回 `const _ThemeColors()`
    → 正文 `background` 恒 `#fff`（`:639` 默认值），完全无视传入的 customBg。
  - 合起来：默认主题下正文 `<body>` 背景永远白底，与外壳/词典/歌词背景不一致。
- **[x] ① 已修复** — `reader_content_styles.dart`：`_themeColors` 的 `default` 分支在收到
  `customBg`/`customFg` 时用它们（与 `custom-theme` 分支同逻辑：含明暗判断），没传才回退
  旧的浅色默认（保持 `css(settings)` 无主题信息时的向后兼容）。`reader_hibiki_page.dart`
  的 `_computeStyleTag`/`_applyStylesLive` 两处把 `customBg`/`customFg` 从
  `_isCustomTheme ? ... : null` 改成无条件传当前主题派生色 `_readerBackgroundHex`/
  `_customThemeTextCss`（preset 命中时 `_themeColors` 走 switch case 忽略 customBg → 零破坏；
  custom-theme 仍用用户色 → 零变化；system/light/未命中 → 吃真实 ColorScheme）。
  selection/sasayaki/link 保持仅 custom-theme 覆盖（无条件传会用 `_themeMap` 的等价副本
  覆盖掉 preset switch 专色，引入双份硬编码耦合且改 CSS 字符串）。
- **[x] ② 已加自动化测试** — `hibiki/test/reader/reader_content_styles_test.dart`：新增
  system-theme/未命中 key + 传 customBg 时正文 `background: <bg> !important` 吃派生色、
  不落 `background: #fff`（撤修复 → 转红）；不传 customBg 时正文仍 `background: #fff`
  （向后兼容）。preset（ecru/dark/black）/custom 既有断言不变保持绿。
- **备注**：根因与 BUG-208 同源（默认主题 `system-theme` 不在 reader preset map），BUG-208
  修了外壳、本条补正文 CSS 这一路。视觉效果（默认主题 + 暗色系统强调色下书籍正文背景
  真正跟随主题、与外壳一致）需真机复测（reader/WebView 类，CLAUDE.md 验证纪律）。
  撞号：`bug.dart new` 取 develop 最高号 220+1=221，遍历所有 worktree 分支 docs/bugs
  取并集确认 221/222 均空号，未撞；如 integration 合并时与他人撞号请改号。
