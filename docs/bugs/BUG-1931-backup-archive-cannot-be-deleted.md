## BUG-1931 · 导出的备份包无法删除，且移动端从不清理

- **报告**：2026-08-29（用户：「这个备份导出怎么删呢，目前在存储里面没办法删，需要加一个按钮，
  给这些存储里面的能加的加按钮」）
- **真实性**：✅ 真 bug，而且是两个叠在一起的问题。
- **根因 A（泄漏，这才是「那些删不掉的文件」的来源）**：
  `backup.part.dart:206-213`（修前）的 `finally { tmpFile.delete() }` **只写在桌面 else 分支里**。
  移动端走 `FushiShare.shareFiles`（`backup.part.dart:194`）之后**从不删除 tmp 文件** ——
  每导出一次就在 `getTemporaryDirectory()` 里永久堆一份完整备份 zip（可能几 GB）。
- **根因 B（看不见、也删不掉）**：
  - 备份包落在 `getTemporaryDirectory()`，只会作为一个匿名子项落进「缓存与临时文件」类目；
  - 而 `storage_usage_view.dart:472`（修前）的删除按钮门控是
    `entry.kind == StorageEntryKind.readOnly ? null : IconButton(...)`，通用类目的每条明细
    (`_readOnlyEntries`) kind 恒为 `readOnly` → 无按钮、无长按、无点击；
  - 名字最像的「导出文件」类目扫的是 `<docs>/fushiExport`，那是 Anki 制卡的图片/音频暂存，
    备份代码从不往那儿写。
- **平台事实（查实）**：
  - 移动端最终存到哪由系统分享面板的接收方决定，**Hibiki 拿不到路径也无权删**；但 tmp 那一份是
    app 沙盒内的普通 `dart:io` File，完全可枚举可删。
  - 桌面 `FilePicker.saveFile` 返回真实路径（不是 SAF content URI），copy 后 tmp 必删，最终文件在
    用户自选目录，app 既不记录也不扫描 → 结构上无法在存储页列出（也不需要）。
  - `AppPaths.tempRootDirectory()` = `getTemporaryDirectory()`（`app_paths.dart:489`），与备份落盘
    同一目录，所以修好 kind 之后备份包确实会出现在该类目里。桌面端该类目按设计恒为 0
    （`storage_usage_service.dart:696`：Windows/Linux 临时目录是全系统共享的，算进来会严重高报），
    但桌面本来就不泄漏，不影响。

- **[x] ① 已修复** — 1d2053fdf4。
  - **A**：`runBackupExportFlow` 每次导出**之前**先 `_sweepStaleBackupArchives(tmpDir)` 扫掉上一次
    遗留的备份包。**为什么不是当场删**：`FushiShare.shareFiles` 用的是非结果变体，Future 在面板
    **呈现后**就完成（`fushi_share.dart:38` 的注释），拿不到「用户存完了」的时机 —— 当场删会把文件
    从接收方手里抽走。挪到下一次导出之前，磁盘上最多滞留一份。匹配用「前缀 + 后缀」双重限定的正则
    `^(fushi|hibiki)-backup-.*\.(fushi|hibiki)\.zip$`，而不是只认 `.fushi.zip` —— 临时目录里还可能
    躺着推荐词典包 `fushi-recommended.fushi.zip` 这类同后缀、绝不该被清掉的文件。
  - **B**：新增 `StorageEntryKind.derivedFile` 与 `kDeletableEntryCategories`，给 covers / web /
    exports / ocrModels / shaders / cache 六个类目的明细开出删除入口（判据是「删了不会留下悬空引用」）。
    `_readOnlyEntries` 更名 `_childEntries` 并收 `kind` 参数（名字得跟着行为走）。删除原语接在
    `settings_schema_storage.dart`，服务层与 widget 仍**零裸磁盘删除**。
  - **刻意不开**：videoDownloads / subtitles / customFonts（都有 DB 行或配置指着，裸删会留下孤儿行
    与指向空文件的字体配置，BUG-183 那条链）、database（活库）、other（白名单之外，语义不明）、
    books / dictionaries（各有自己的删除原语）。
- **[x] ② 已加自动化测试** —
  - `fushi/test/pages/storage_usage_view_test.dart` 新增正向（封面类目明细可删、走注入的
    `deleteFiles` 原语并触发重扫）与**负向**（自定义字体类目仍不给删除按钮）各一条。负向那条防的是
    以后有人顺手把有引用的类目塞进可删清单。
  - `fushi/test/sync/backup_export_file_picker_guard_test.dart` 新增「每次导出前先清掉上一次遗留的
    备份包」：清理必须存在，且必须**在打包之前**（打完再清会把这一次的成果也删掉）。
  - 变异实测：删掉 `_sweepStaleBackupArchives` 调用、把 covers 移出可删清单 → 对应用例各自变红。
