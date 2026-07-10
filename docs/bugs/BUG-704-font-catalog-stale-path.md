## BUG-704 · 字体库字体丢失：数据根迁移/备份恢复后 font_catalog 路径失联

- **报告**：2026-07-10（用户：wrds，TODO-1393）
- **真实性**：✅ 真 bug（一类「路径失联」自愈缺口，非数据删除）

### 诊断（本机真实数据）

- 数据根 `flutter.data_root = D:\APP\HIBIKI_date`（`shared_preferences.json`）；派生
  `documents = D:\APP\HIBIKI_date\documents`、`support = D:\APP\HIBIKI_date\support`。
- 字体文件**全部在盘**（7 个）：`D:\APP\HIBIKI_date\documents\custom_fonts\` 下
  Klee One / Noto Sans JP / Noto Sans SC（多版本）+ 测试字体。**没有被删。**
- 当前 `src:reader_ttu:font_catalog`（Drift `preferences`）只剩 2 条，且路径**有效**、
  指向现根现存文件（Klee One_1782285150702.ttf / Noto Sans SC_1781248919842.ttf）。
- 结论：这是**路径失联**（字体文件在盘、catalog 曾指向旧根/失效路径被丢失），不是删除。

### 根因（rebase 覆盖已完整，真正缺口是「无读侧自愈」）

- 三条正向 rebase 路径（数据根迁移 / 备份恢复 / Profile 导出）都覆盖同一组 key
  （`font_catalog` + 4 个 shadow 列表 custom_fonts/app_ui_fonts/dict_fonts/video_sub_fonts），
  当前**无漏 key**：
  - 迁移：`hibiki/lib/src/storage/data_root_migrator.dart:803-815`（catalog 803-808 + shadow 809-815）。
  - 备份恢复：`hibiki/lib/src/sync/backup_service.dart:2628` `_rebaseFontPaths`（catalog 2638-2646 + shadow 2649-2653）。
  - Profile：`hibiki/lib/src/profile/profile_repository.dart:427-431`。
- 历史缺口（git 考古）：备份恢复在 **2026-06-11→06-13** 只 rebase shadow 列表、**从不 rebase
  `font_catalog`**（`font_catalog` 模型 06-13 才引入 `ddbb89fe9`）；06-11 前完全不 rebase。
  该窗口把 `font_catalog` 路径遗留在旧根 → 文件搬走后 catalog 指向失效路径。
- 真正的**持续缺口**：读侧无任何自愈。`ReaderSettings._readFontCatalogState` /
  `custom_fonts_page._readCatalogState` 逐字信任存储路径；`AppFontLoader.resolveAndLoad`
  （`hibiki/lib/src/models/app_font_loader.dart:72`）对缺失文件只 `continue` 跳过、
  不回写。一旦路径失效（历史备份窗口 / 部分失败的迁移 / iOS 重装换 container UUID /
  Profile 导入把路径剥成空根 `/X.ttf` 后从不重挂根，`profile_repository.dart:428/431`），
  字体在阅读器/词典/UI 静默消失且**无找回入口**——即用户所报「字体没了」。

### 修复

- **[x] ① 已修复** — 加启动自愈（读侧，与 TODO-1255 视频封面 `listForShelf` 自愈同构）：
  - 纯函数 `relocateMissingFontCatalogPaths` / `relocateMissingFontListPaths` + `fontPathBasename`
    （`hibiki/lib/src/reader/font_catalog.dart:336-471`）：对 path 失效的条目，按 basename 在当前
    `<documents>/custom_fonts` 找回同名文件；有效路径 / 系统字体(null) / 无同名文件一律不动。
  - `ReaderSettings.healMissingFontFilePaths(currentFontsDir)`
    （`hibiki/lib/src/reader/reader_settings.dart:667`）：自愈 catalog + 4 shadow 列表并回写 DB，
    幂等、返回找回数。
  - init 接线 `hibiki/lib/src/models/app_model.dart:1867-1884`（在字体加载前跑，首帧即用有效路径）。
  - 提交：分支 `todo1393-font-recovery`（TODO-1393，见本分支 git log）
- **[x] ② 已加自动化测试** —
  - `hibiki/test/reader/font_path_relocation_test.dart`（纯函数：找回/不动有效/不动无源/系统字体/
    Profile 剥离路径/坏 JSON verbatim）。
  - `hibiki/test/reader/font_path_heal_integration_test.dart`（真 Drift DB：stale catalog+shadow →
    heal → 真写穿 DB + 幂等 + 全有效 no-op）。
  - 提交：分支 `todo1393-font-recovery`（TODO-1393，见本分支 git log）

### 备注

- 未做「删除误判找回」——若字体文件真被迁移误删则本机制无能为力（本机文件均在盘，无此情况）。
- 相邻缺口（本次未改，建议后续）：Profile 导入 `importProfileFromJson` 把剥成空根的字体路径
  原样入库、激活后运行时不重挂根（`profile_repository.dart:544/559`）；本自愈在**下次启动**覆盖它，
  但运行时激活到重启前仍失效。
