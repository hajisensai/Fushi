## BUG-4907 · 游戏首页空库引导卡被拉满整个高度，窄卡居中两侧大片空白
- **报告**：2026-11-20（用户：11-20 反馈截图 30，Windows 游戏 › 首页，库里没有游戏；「没游戏的时候这里有点抽象」）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/pages/implementations/games/galgame_home_blocks.dart:2258`：拼贴版空态 `GalgameHomeEmpty` 是 `Center > ConstrainedBox(maxWidth 460) > _StatShell > Row`，Row 里文字那一列是默认 `MainAxisSize.max` 的 `Column`，在 Row 给的有界纵向约束下撑到最大高度，于是整张卡被拉成整列高、内容挤在左上角。经典封面网格版另有一份 `_buildEmpty`（`galgame_home_page.dart` 原 669 行），两份空态口径也不一致。
- **[x] ① 已修复** — 空态改用库页共享空态 `FushiPlaceholderMessage`（与书架 / 视频同一个：MD3 饱和色块图标弹入、Apple ContentUnavailableView 式），在剩余空间里居中：标题 + 拖放 .exe 提示 + 主按钮「导入游戏」/ 次按钮「去发现」，外层 `FushiStaggeredEntrance` 进场（MD3 / Apple 同一条）。拼贴版与经典版合成同一份 `_buildEmptyState`，删掉旧 `_buildEmpty`。新 i18n key `game_home_import_games`。（提交见 PR）
- **[x] ② 已加自动化测试** — `fushi/test/pages/galgame_home_page_test.dart`：拼贴 / 封面网格 × MD3 / Apple，空库时没有任何底板高于页面一半、文案与主按钮整组落在页面中段并水平居中、拖放提示与「导入游戏」都在。
- **备注**：像素证据见 PR（widget test 渲染 MD3 / Apple）。
