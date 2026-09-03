## BUG-1678 · 有声书换字幕时把现有音频删光并中止导入
- **报告**：2026-08-16（用户转述：「只重新导入音频和字幕之后，音频大多数时候不响；最后整本删掉重导才好」）
- **真实性**：✅ 真 bug（沿真实代码路径逐行读出）。**同一个形状在三处独立复发**，说明不是三个疏忽，
  是 API 形状本身在诱导错误用法：
  - **机制 A（毁磁盘文件）**：`AudiobookImportDialog._enterReplaceSubtitleMode`
    （`audiobook_import_dialog.dart:993`）把**已持久化**的音频路径回填进 `_audioPaths` 来表达
    「音频不变」，`_doImport` 随后按「先 `cleanAudioFiles(persistDir)` 清目录、再逐个复制」
    两步走 —— 第一步先把本次的**源文件**删了，第二步 `await srcFile.length()` 读的正是刚删掉
    的文件 → `FileSystemException` → 导入中止。磁盘上音频没了，`audiobooks.audio_paths_json`
    还指着不存在的路径，`AudiobookSessionLauncher._resolveAudioFiles` 过滤掉全部不存在的文件
    后返回空 → 这本书再也没有音频。同形状的裸「清+拷」另有三处：
    `audiobook_alignment_service.dart`、`book_import_dialog.dart`、
    `SrtBookRepository.replaceAudio`。
  - **机制 B（清 audiobooks 的列）**：`upsertAudiobook`
    （`database_prefs_media.part.dart:389`）是 `DoUpdate((_) => ab)` 的**整行覆盖**，而
    `AudiobookRepository._audiobookToCompanion` 每一列都是 `Value(...)`（没有 `absent`）。
    `_doImport` 凭空 `Audiobook()..bookKey = ...` 再 upsert，本次没设的列一律被写成默认值：
    `persistedPaths` 为空（换字幕路径；legacy `audioRoot` 目录模式的书恒走这条，因为
    `_hasAudioSource` 认 `_audioDir` 而 `audioCopyFiles` 只从 `_audioPaths` 收）时，
    `audio_paths_json` 与 `audio_root` 一起被清零 → 音频整列消失。
  - **机制 C（清配对 srt_books 的列）**：`writeEpubBackedSrtBook`
    （`epub_backed_srt_book.dart`）除 `id` 外凭空造 `SrtBook`，而 `SrtBookRepository.save`
    也是整行覆盖。只换字幕时它拿不到音频（`audioPaths` 传空），配对行的 `audioPaths` /
    `audioRoot` / `coverPath` 一起被清成 null —— 互联 host 的 hasAudiobook 判据要求
    audiobooks + srt_books 两表齐备且带音频，清掉即这本书从同步里消失
    （`exportAudiobook` 抛 `StateError`）。
- **[x] ① 已修复** — **改数据结构让错的用法写不出来**，不是给危险 API 加「记得传对」的参数
  （第一版就是那么修的：`cleanAudioFiles(keep:)` + `Audiobook.cloneOf` 基线克隆。它能修好这
  三处，但特殊情况没消失，只是从「忘了会毁数据」变成「忘了会毁数据、但有守卫测试骂你」——
  需要一条测试去检查每个调用点有没有传对参数，本身就是 API 允许写错的证据）：
  - **磁盘侧**：唯一原语 `AudiobookStorage.syncAudioFiles(dir, sources)` —— 「把持久目录同步
    成恰好这一组」。删除那一半（`_pruneAudioFiles`）变成**私有**，「先清后拷」这种自毁顺序
    无从表达；已在目录里的源文件零拷贝原地保留。「全换新 / 全沿用 / 混合」三种情况走同一条
    无分支路径，且天然幂等。四处调用点各自塌缩成一次调用。
  - **库侧（audiobooks）**：**删掉** `AudiobookRepository.saveAudiobook` 与
    `_audiobookToCompanion`。repository 现在只有四个窄动作：`ensureAudiobook` /
    `replaceAudio` / `replaceAlignment` / `writeHealth`，各自只写自己那几列
    （走新增的 `FushiDatabase.patchAudiobook`，drift `update().write()` 不碰 absent 的列）。
    调用方**没有入口**去清空别的列。`upsertAudiobook` 保留但加注释限定为「从同步包物化一
    整行」。测试/fixture 的整行播种也一并改走窄接口——不留后门。
  - **库侧（srt_books）**：新增 `SrtBookRepository.patchByUid`（参数一律「null = 不改」），
    `writeEpubBackedSrtBook` 行已存在时走它，只有真正创建新行时才走整行 `save`。
  - 提交：`fix(audiobook): stop re-import from wiping existing audio`（第一版补丁）
    + `refactor(audiobook): 让「清空没碰的列」在结构上写不出来`（本次根本性修复）。
- **[x] ② 已加自动化测试** —
  - `packages/fushi_audio/test/audiobook/audiobook_reimport_audio_survival_test.dart`：
    同步原语三态（全换 / 全沿用幂等不毁源 / 混合）、`replaceAudio` 吃回自己的持久路径、
    窄写入互不越界（换字幕不动音频列、换音频不动字幕列、`ensureAudiobook` 幂等）。
  - `fushi/test/media/audiobook/book_import_srtbook_pairing_test.dart`：
    「只换字幕不得清空配对行的音频与封面」。
  - 第一版那条源码守卫（检查每个调用点有没有传 `keep:` / 有没有先取基线）**已删除**：
    它守的是一个不再存在的footgun，现在由编译器保证。
  - 七处变异实测全部让对应测试变红，还原后逐文件 sha256 校验一致。
- **备注**：与 [BUG-1679](BUG-1679-audiobook-audio-replace-stale-position.md) 同一条用户报告的两半——
  这条解释「音频不响」，那条解释「偶尔能响就乱跳页」。用户最后「整本删掉重导」能好，是因为
  `deleteBook` 会 `AudiobookStorage.deletePersistDir(bookKey)` 把脏持久目录整个清掉，
  下一次导入从干净目录起步，绕过了机制 A。
