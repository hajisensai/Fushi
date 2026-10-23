## BUG-3653 · srs-anki-migration-silent-options
- **报告**：2026-10-21（用户：「怎么没任何弹窗让我选 rwkv 之类的选择」「anki 迁移的 lapis 迁移到 fushi card 之类的也没提醒，应该给一整个页面这些提醒才对」）
- **真实性**：✅ 真 bug。「从 Anki 迁移」固定用 `kSrsAnkiMigrationOptions`（`fushi/lib/src/srs/srs_anki_migration.dart`），迁移页只弹一个数量确认框，`useRwkv` 默认开、用户无从选择——与 `srs_import_options.dart` 里引用的所有者要求「从 anki 迁移数据时，应该让用户选择是否迁移 rwkv」矛盾（只有「导入 Anki 包」对话框接了这个开关）。Lapis → Fushi 卡片的提示挂在 `SrsAnkiMigrationPage.onMigrated`，只在后台任务结束时迁移页仍在栈上才弹；迁移是后台任务，用户离开页面后报告框与 Lapis 提示都不出现。
- **[x] ① 已修复** — `a1c9eb003e`：选好集合 / 文件后进「迁移设置」整页（`srs_anki_migration_setup_page.dart`）：来源概况与「Anki 还开着」警告、学习进度三项（排程与复习记录 / 牌组预设 / FSRS 参数）、排程算法 RWKV / FSRS 二选一并写明后果、「导入后把旧 Lapis 迁到 Fushi 卡片」、折叠的更新规则，以及「合并不替换 / 删过的笔记会恢复 / 后台进行 / 如何撤回」四条提醒；选择记在偏好 `srs_anki_migration_settings`。Lapis 转换并进迁移任务本身（`srsConvertLegacyLapisAfterImport`，每个变体一个事务，失败不拖垮已落库的导入、写进报告并记日志），不再依赖页面开着。
- **[x] ② 已加自动化测试** — `fushi/test/srs/srs_anki_migration_setup_test.dart`：设置默认值与 JSON 往返；导入后转换把内置 Lapis 笔记迁到 Fushi 卡片并计数；MD3 / Apple 两套设计系统下设置页列出全部选项与四条提醒，切到 FSRS、关掉 Lapis 转换后开始，返回值与所选一致。
- **备注**：「导入 Anki 包」对话框（分享牌组用）保持原样，没有加 Lapis 转换项；迁移后仍保留原有的 Lapis 补充提示（关掉转换且页面还开着时）。
