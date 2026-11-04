## BUG-4006 · 歌词模式新版宽屏缺阅读速度 / 已读字数 / 阅读时长
- **报告**：2026-11-03（shishamo，经 fushi-bot 代提交 njN2KIQS_j，开发版 3.3.0 系列：歌词模式新版样式底部没有阅读速度、阅读进度、阅读时间）
- **真实性**：✅ 真 bug。`LyricsPlayerStats`（速度 / 全书已读字数 / 会话时长）在经典布局两端都有展示：宽屏左栏 `_StatsChips`、窄屏顶栏 `_NarrowTopBar`（`lyrics_player_md3.dart`）。新版（2026-10-31 拍板的 `Md3ModernLyricsPlayerDesign`）窄屏沿用经典顶栏，读数仍在；但宽屏改成三浮岛后只在左岛 `_ModernInfoIsland` 留了「章名 · 百分比」，`fushi/lib/src/media/audiobook/lyrics_player/lyrics_player_md3_modern.part.dart` `_ModernWideChrome` 里速度、字数、时长全部没有渲染位——新版宽屏是唯一丢读数的形态。
- **[x] ① 已修复** — `_ModernWideChrome` 进度线上方那一行由「两端时间」改为「当前时间 · 读数 · 剩余时间」，读数与经典 / 窄屏同一份数据与格式（`_speedText` / `_progressText` / `_sessionText`，`_StatsBuilder` 每秒只读一次）；左岛去掉与读数重复的百分比，只留书名 / 章名。不改几何、不动歌词编辑相关界面（功能黑名单）。
- **[x] ② 已加自动化测试** — `fushi/test/media/audiobook/lyrics_modern_layout_test.dart`「reading stats (speed · progress · session) above the seek line」（真 widget：1600×900 新版宽屏出现 `lyrics_modern_stats`，含「7,200 字/时」口径的速度、`1,234 / 56,789`、`2.17%`、`30:00`，位于歌词区之下、底部浮岛之上，无溢出）。
- **备注**：未做真机截图复测；底栏自动隐藏时读数随底栏一起淡出（与时间同一行）。
