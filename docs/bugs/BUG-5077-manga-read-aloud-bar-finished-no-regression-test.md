## BUG-5077 · 漫画朗读读到章末播放条不退的修复（#3986）缺自动化回归测试
- **报告**：2026-11-21（审查 PR #3986 时发现）
- **真实性**：✅ 真 bug，已修于 PR #3986（read_aloud.part.dart 的 _onControllerChanged 改为在 isActive 翻转时重建）。缺口是没有自动化回归测试：页面层要走到 finished 必须有可用的 TTS 引擎，现有页面测试做不到。
- **[x] ① 已修复** — 已修（#3986）。
- **[x] ② 已加自动化测试** — 根因位置：`fushi/lib/src/media/manga/reader/manga_fushi/read_aloud.part.dart` 的 `_onControllerChanged` 原先按「跨不跨 idle」决定重建，playing→finished 不经 idle 不重建。页面私有类里的这段判定测不到，抽成 `MangaReadAloudSessionWatch`（`manga_read_aloud_controller.dart` 末尾），页面改为挂它（`onActiveChanged` → 重建、`onFinished` → 章末提示）。测试在 `fushi/test/media/manga/reader/manga_read_aloud_controller_test.dart` 的 `MangaReadAloudSessionWatch` 组：真控制器 + 假宿主 / 假合成 / 假播放器跑到章末，断言 playing→finished 时回调重建且此刻 isActive=false、提示 chapterEnd；整章无字同理。变异：把判据改回 idle 翻转，用例变红。
- **备注**：
