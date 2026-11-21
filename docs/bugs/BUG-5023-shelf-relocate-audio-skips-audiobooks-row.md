## BUG-5023 · 书架「重新定位文件」只改 srt 行，EPUB 有声书的 audiobooks 行仍是坏路径
- **报告**：2026-11-20（路线图 #3722 c48 gap-novelmisc-1）
- **真实性**：✅ 真 bug。
  - 根因：`fushi/lib/src/pages/implementations/reader_history/books.part.dart` `_relocateSrtBookAudio`（develop 上第 656～660 行）把新路径写进内存里的 `SrtBook` 再整行 `save`，只落 `srt_books`。EPUB 有声书的同一批路径还登记在 `audiobooks` 行上，而会话启动器 `fushi/lib/src/media/audiobook/audiobook_session_launcher.dart:53` `_pickSource` 优先读 `audiobooks` 行：旧路径部分还在时按残缺列表起播（文件缺项、cue 错位）；全断时退到 srt 行按 uid 身份起播（cue / 进度挂在 bookKey 上，字幕不跟、进度归零）。
- **[x] ① 已修复** — `SrtBookRepository.relocateAudioPaths`（`packages/fushi_audio/lib/src/audiobook/srt_book_repository.dart`）：同一事务只改两行的 `audioPaths`（并清 `audioRoot`），不动进度、不复制文件；只改带对齐字幕的 `audiobooks` 行（没有对齐的是旧版 audioOnly 脏行，不救活）；配对行新文件数与原登记不等时拒绝、一行不写，书架弹错误提示。独立字幕书保持「选几个写几个」。不套 `replaceAudio`：那会按「音频变了」判进度去留并复制进持久目录。
- **[x] ② 已增加自动化测试** — `fushi/test/media/audiobook/srt_book_relocate_audio_test.dart`：部分断链 / 全部断链两种情况下重新定位后 `AudiobookSessionLauncher.resolve(bookKey)` 仍是 audiobooks 来源、拿到全部新路径、进度 1234 ms 不变；文件数不等拒绝且两行不变；脏行不被改写。
- **备注**：真机未复测（本轮所有者定不做设备验证）。
