## BUG-4123 · music-lookup-popup-cover-theme
- **报告**：2026-11-06（用户：音乐歌词页里查词框没有封面取色）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/base_source_page.dart` `buildDictionary()` 外包 `Theme(data: appModel.overrideDictionaryTheme ?? theme)`，`theme` 是 `Theme.of(State.context)`（`fushi/lib/src/pages/base_page.dart:62`）；歌词页在自己 `build` 里才套封面主题（`music_lyrics_page.dart` `_themeFor`），State.context 在那层之上，弹窗被这层 Theme 打回应用主题色。
- **[x] ① 已修复** — `buildDictionary()` 改用 `Builder` 取插入点的环境主题（覆盖主题仍优先），弹窗层内的亮暗 / 底色一律从 builder context 读，不再读 State 的 `theme`。
- **[x] ② 已加自动化测试** — `fushi/test/pages/base_source_page_popup_ambient_theme_test.dart`：页面 build 内套一层不同种子色的主题，断言弹窗层拿到的是页面局部主题的 primary。
- **备注**：同批对齐了歌词页 pixi 背景观感（QPlayer 式 S 形弯曲 + 32px 贴图 + 压暗封顶调色）；「背景设置改了不保存」在调试实例里未复现（饱和度能落库），安装版那次的现场原因未定，单独跟进。
