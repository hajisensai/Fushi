## BUG-825 · 安卓阅读器制卡书籍封面缺失(FileProvider 未覆盖 app_flutter 解压目录)
- **报告**：2026-07-15（用户：手机制卡少了书籍封面，卡片 `Picture` 字段是空的；电脑制卡有封面）
- **真实性**：✅ **真 bug**。沿真实代码路径复核（develop 设备构建 `d50148f` 1.2.0+750 已含 BUG-703 封面路径修复）：
  - 制卡封面**解析正确、非空**——`hibiki/lib/src/pages/implementations/reader_hibiki/mining.part.dart:38` 用 `ReaderHibikiSource.resolveCoverFilePath` 解析到解压目录里的真实封面文件（与书架同一解析器，用户确认书架封面正常）。
  - 卡片图字段走 `{card-image}`（Lapis 预设 `packages/hibiki_anki/lib/src/lapis_note_type.dart:71` `'Picture': '{card-image}'`），渲染读 `context.coverPath`。
  - **根因在 AnkiDroid 落媒体那一步**：`hibiki/android/app/src/main/java/app/hibiki/reader/AnkiChannelHandler.java:283` `FileProvider.getUriForFile(file)` 只能服务 `provider_paths.xml` 声明过的根（`code_cache`/`files`/`cache`/`external*`）。句子音频/视频封面/词典媒体都先写进 Dart `Directory.systemTemp`（=Android `code_cache`）再交 AnkiDroid，故能被服务；**唯独书籍封面**直接把 EPUB 解压目录路径喂 FileProvider——解压目录 base 是 `getApplicationDocumentsDirectory()` = `/data/data/<pkg>/app_flutter`（`files` 的兄弟目录，**不在任何配置根下**）→ `getUriForFile` 抛 `IllegalArgumentException「Failed to find configured root」`，被 `packages/hibiki_anki/lib/src/ankidroid/anki_repository.dart` 的 `_addMediaFile` catch 吞掉 → 返回 null → coverRef=null → `{card-image}` 恒空。
  - 平台面：仅 **AnkiDroid（手机）** 中招；桌面 **AnkiConnect** 走 HTTP 传字节、书架 Flutter 直接读文件，都不经 FileProvider → 电脑/书架正常。默认数据根即触发（无需自定义位置）。
  - 与已修的 BUG-703 区分：BUG-703 是封面**路径解析**大小写不对称（已修）；本 bug 是解析出的封面路径**落 AnkiDroid 媒体**时被 FileProvider 拒。
- **[x] ① 已修复** — `packages/hibiki_anki/lib/src/ankidroid/anki_repository.dart`：新增收口 `_stageForMediaProvider(filePath, preferredName)`，`_addMediaFile` 在进原生前调用它——源文件若不在 `code_cache`（`Directory.systemTemp`）下就先复制进 FileProvider 覆盖的 `anki-media` 缓存目录，再把副本路径交给原生 `addFileToMedia`。这样**每一种**交给 AnkiDroid 的媒体都落在声明过的根里；已在 temp 下的媒体（句子音频等）原样返回，零行为改动、不多余复制。（提交哈希见 git log / 本分支。）
- **[x] ② 已加自动化测试** — `packages/hibiki_anki/test/ankidroid_cover_fileprovider_stage_test.dart`（3 例，全绿）：
  1. 行为端到端（mock `app.hibiki.reader/anki` 通道）：封面源在 `systemTemp` 之外（模拟 `app_flutter` 解压目录）时，`mineEntry` 提交给原生 `addFileToMedia` 的 `filename` 必须被搬进 `systemTemp`(=code_cache) 下、且副本真实存在、字节一致——回归即变红。
  2. 无回归：封面源已在 `systemTemp` 下时原样提交，不多余复制。
  3. 源码接线守卫：`_addMediaFile` 必经 `_stageForMediaProvider`，且提交 `stagedPath` 而非裸 `filePath`（一旦改回 `'filename': filePath` 立即变红）。
  - 全量 `flutter analyze`（改动文件）No issues；`packages/hibiki_anki` 整包 165 例全绿。
- **备注**：
  - **Android 真机验证门未过**：修复在 Dart 侧收口，逻辑清晰且 CI 端到端守卫已覆盖「非 code_cache 源被搬进 code_cache」这一根因判据；但未在真机制卡目视封面出现（本机安卓真机在线但为 release 不可 debug 构建，需另装含本修复的构建才能肉眼复测原始失败路径）。待有含修复的构建时补真机复测。
  - 顺带受益：`_addRemoteAudio` 的 localFile 分支等任何「从任意本地路径取媒体交 AnkiDroid」的场景，此后都不会再被 FileProvider 拒（同一收口）。
