## BUG-5077 · 漫画朗读读到章末播放条不退的修复（#3986）缺自动化回归测试
- **报告**：2026-11-21（审查 PR #3986 时发现）
- **真实性**：✅ 真 bug，已修于 PR #3986（read_aloud.part.dart 的 _onControllerChanged 改为在 isActive 翻转时重建）。缺口是没有自动化回归测试：页面层要走到 finished 必须有可用的 TTS 引擎，现有页面测试做不到。
- **[x] ① 已修复** — 已修（#3986）。
- **[ ] ② 未加自动化测试** — 给 MangaReadAloudController 加可注入的假 TTS 引擎，或把「播放条 / 工具栏选择」抽成纯函数按 isActive 判定，补测试覆盖 playing→finished 后底栏退回工具栏。
- **备注**：
