import 'package:fushi_audio/fushi_audio.dart';

/// TODO-894：为一条 EPUB-backed 有声书补写配对的 srt_books 行。
///
/// EPUB-backed 路径（`BookImportDialog._importEpubWithAlignment`）只写 Audiobooks
/// 行，但 push 两条消费路径（`sync_orchestrator.dart` live push 与
/// `syncAudiobookPackages`）都靠 `srt_books.book_key == audiobooks.book_key` 找配对
/// 的 SrtBook，缺它整本永不上传。导入路径与 backfill 迁移共用同一稳定派生 uid
/// `srtbook_epub_<bookKey>`：同 bookKey 恒定 → 经 upsert-on-uid 幂等（重复导入覆盖
/// 同行，绝不落第二行）。禁用 `DateTime.now()` 做 uid（破幂等）。
///
/// cover_path 新建时刻意留空——export 打包不依赖 srtBook.coverPath（封面来自
/// epub_books / audiobook 落盘文件），新导入与 backfill 两路径对此保持同一策略；
/// 但既有行上的值必须原样带过去，整行覆盖不是清列的借口（BUG-1678）。
///
/// 原寄生在 book_import_dialog.dart 里被反向依赖，迁出到共享目录（审计 §1-K）。
String epubBackedSrtBookUid(String bookKey) => 'srtbook_epub_$bookKey';

Future<void> writeEpubBackedSrtBook({
  required SrtBookRepository repo,
  required String bookKey,
  required String title,
  required String? author,
  required String srtPath,
  required List<String> audioPaths,
}) async {
  final String uid = epubBackedSrtBookUid(bookKey);
  // Re-import of the same bookKey must update the existing paired row in place
  // (idempotent), not collide on UNIQUE(uid). upsertSrtBook resolves on the
  // `id` PK, so carry the existing row's id when present.
  final SrtBook? existing = await repo.findByUid(uid);
  // BUG-1678：`SrtBookRepository.save` 也是整行覆盖（companion 除 id 外每列都是
  // `Value(...)`）。只换字幕时本函数拿不到音频，凭空造行会把配对行的 audioPaths /
  // audioRoot / coverPath 一起清空 —— 互联 host 的 hasAudiobook 判据要求
  // audiobooks + srt_books 两表齐备且带音频，清掉就等于这本书从同步里消失。
  // 以现有行为基线，只改本次真的带来的字段。
  final SrtBook book = SrtBook()
    ..id = existing?.id
    ..uid = uid
    ..title = title
    ..srtPath = srtPath
    ..importedAt = DateTime.now().millisecondsSinceEpoch
    ..bookKey = bookKey
    ..author = existing?.author
    ..audioRoot = existing?.audioRoot
    ..audioPaths = existing?.audioPaths
    ..coverPath = existing?.coverPath;
  if (audioPaths.isNotEmpty) {
    book
      ..audioPaths = List<String>.of(audioPaths)
      // 新音频一律文件列表模式：不清 audioRoot 会让基线把旧目录带回来。
      ..audioRoot = null;
  }
  if (author != null) {
    book.author = author;
  }
  await repo.save(book);
}
