## BUG-1678 · 有声书换字幕时把现有音频删光并中止导入
- **报告**：2026-08-16（用户转述：「只重新导入音频和字幕之后，音频大多数时候不响；最后整本删掉重导才好」）
- **真实性**：✅ 真 bug（沿真实代码路径逐行读出，两条独立机制）
  - **机制 A（毁磁盘文件）**：`fushi/lib/src/media/audiobook/audiobook_import_dialog.dart:993`
    `_enterReplaceSubtitleMode` 把**已持久化**的音频路径回填进 `_audioPaths` 来表达「音频不变」，
    `_doImport` 随后无条件 `AudiobookStorage.cleanAudioFiles(persistDir)`
    （`audiobook_import_dialog.dart:685/696` 修复前）把它们全删了，紧接着复制循环
    `final int fileLen = await srcFile.length();` 读的正是刚被删掉的源文件 →
    `FileSystemException` → 导入中止。结果：磁盘上音频没了，`audiobooks.audio_paths_json`
    还指着已不存在的路径，`AudiobookSessionLauncher._resolveAudioFiles` 过滤掉全部不存在的
    文件后返回空 → 这本书再也没有音频。同形状的裸调用另有三处：
    `audiobook_alignment_service.dart:204`、`book_import_dialog.dart:943`、
    `packages/fushi_audio/lib/src/audiobook/srt_book_repository.dart:191`（`replaceAudio`）。
  - **机制 B（清库里的列）**：`packages/fushi_core/lib/src/database/database_prefs_media.part.dart:389`
    `upsertAudiobook` 是 `DoUpdate((_) => ab)` 的**整行覆盖**，而
    `AudiobookRepository._audiobookToCompanion` 每一列都是 `Value(...)`（没有 `absent`）。
    `_doImport` 凭空 `Audiobook()..bookKey = ...` 再 upsert，本次没设的列一律被写成
    默认值：`persistedPaths` 为空（换字幕路径；legacy `audioRoot` 目录模式的书恒走这条，
    因为 `_hasAudioSource` 认 `_audioDir` 而 `audioCopyFiles` 只从 `_audioPaths` 收）时，
    `audio_paths_json` 与 `audio_root` 一起被清零 → 音频整列消失。
  - **机制 C（清配对行的列）**：同一形状再来一次。`fushi/lib/src/media/import/epub_backed_srt_book.dart`
    的 `writeEpubBackedSrtBook` 除 `id` 外凭空造 `SrtBook`，而 `SrtBookRepository.save`
    （`srt_book_repository.dart:277`）也是整行覆盖。只换字幕时它拿不到音频（`audioPaths`
    传空），配对 `srt_books` 行的 `audioPaths` / `audioRoot` / `coverPath` 一起被清成
    null —— 互联 host 的 hasAudiobook 判据要求 audiobooks + srt_books 两表齐备且带音频，
    清掉即这本书从同步里消失（`exportAudiobook` 抛 `StateError`）。
- **[x] ① 已修复** — `keep` 保留集 + 基线克隆两处根因：
  - `AudiobookStorage.cleanAudioFiles(dir, {keep})`：本次导入的源文件绝不删，
    「全换新 / 全沿用 / 混合」收敛成同一条无分支路径；四处调用点全部传 `keep`。
  - `Audiobook.cloneOf(src)`：整行 upsert 前必须以现有行为基线，新增列只需改这一处。
    `_doImport` 改为 `findByBookKey` 取基线再只改本次真换掉的列；换新音频时显式
    `audioRoot = null`（新音频一律文件列表模式，不让基线把旧目录带回来）。
  - `writeEpubBackedSrtBook`：同样改为以现有行为基线，只覆盖本次真的带来的字段；
    新建行的行为不变（`coverPath` 仍留空）。
  - 提交：`fix(audiobook): stop re-import from wiping existing audio`（机制 A/B）
    + `fix(audiobook): 配对 srt_books 行不再被换字幕清空音频/封面`（机制 C）。
- **[x] ② 已加自动化测试** —
  - 行为层：`packages/fushi_audio/test/audiobook/audiobook_reimport_audio_survival_test.dart`
    （`keep` 真的保留 / `replaceAudio` 吃回自己的持久路径不毁文件不抛 / `cloneOf` 保列 +
    「凭空造行仍会清列」的负向对照）。
  - 接线层：`fushi/test/media/audiobook/audiobook_reimport_no_audio_wipe_guard_test.dart`
    （三处 persist-dir 写入方的 `cleanAudioFiles` 必须带 `keep:`；对话框必须先取基线再写）。
  - 配对行：`fushi/test/media/audiobook/book_import_srtbook_pairing_test.dart`
    增「只换字幕不得清空配对行的音频与封面」。
  - 七处变异实测全部让对应测试变红，还原后逐文件 sha256 校验一致。
- **备注**：与 [BUG-1679](BUG-1679-audiobook-audio-replace-stale-position.md) 同一条用户报告的两半——
  这条解释「音频不响」，那条解释「偶尔能响就乱跳页」。用户最后「整本删掉重导」能好，是因为
  `deleteBook` 会 `AudiobookStorage.deletePersistDir(bookKey)` 把脏持久目录整个清掉，
  下一次导入从干净目录起步，绕过了机制 A。
