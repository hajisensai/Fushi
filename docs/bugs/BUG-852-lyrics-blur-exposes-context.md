## BUG-852 · 歌词模式模糊只盖当前句，前后文暴露
- **报告**：2026-07-16（用户：）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/media/audiobook/lyrics_mode_html.dart:143`——听力沉浸模糊（TODO-908）的 CSS 门控写成 `body.lyrics-blur .cue.current { filter: blur(8px) }`，只盖当前句；前后文 `.cue` / `.cue.near-*` 无 filter，照样清晰可读、可预读，沉浸模糊语义（整篇不可预读）失效。显形选择器 `.cue.current:hover` / `.cue.current.revealed` 同样只对当前句生效。
- **[x] ① 已修复** — 把 blur 门控从 `.cue.current` 放宽到整个 `.cue`（`body.lyrics-blur .cue { filter: blur(8px) }`），显形选择器同步改成 `.cue:hover` / `.cue.revealed`，逐句 hover / 点击才显形。运行时开关 `__lyricsSetBlur` 仍只翻 `body.lyrics-blur` class（`.revealed` 显形逻辑本就按任意 `.cue` 走，无需改）。提交：见 PR。
- **[x] ② 已加自动化测试** — `hibiki/test/media/audiobook/lyrics_mode_html_test.dart` 新增 group `BUG-852 listening blur hides all cues (not just current)`：断言 blur filter 挂在 `body.lyrics-blur .cue`、显形选择器为 `.cue:hover` / `.cue.revealed`，并回归守卫旧的 `body.lyrics-blur .cue.current {` 门控不得再出现。
- **备注**：模糊维度与 writing-mode 正交，只作用 `.cue`，不碰 TODO-907 轴 CSS；`__lyricsUpdateStyle` 的 cssRules 遍历按精确 selectorText 匹配（`.cue` / `.cue.current`），不与放宽后的 `body.lyrics-blur .cue` 复合选择器冲突。
