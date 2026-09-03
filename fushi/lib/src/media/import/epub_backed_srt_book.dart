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
  // (idempotent), not collide on UNIQUE(uid).
  // BUG-1678：行已存在时走**局部更新**，只写本次真的带来的列。以前这里凭空造
  // 一个 SrtBook（只带 id）再走整行覆盖的 save，于是「只换字幕」（audioPaths 传
  // 空）会把配对行的 audioPaths / audioRoot / coverPath 一起清成 null —— 互联
  // host 的 hasAudiobook 判据要求 audiobooks + srt_books 两表齐备且带音频，
  // 清掉就等于这本书从同步里消失（exportAudiobook 抛 StateError）。
  // 手抄一遍「把旧值搬过来」也能修，但那是纪律不是结构：新增列照样会漏抄。
  final bool patched = await repo.patchByUid(
    uid,
    title: title,
    srtPath: srtPath,
    bookKey: bookKey,
    importedAt: DateTime.now().millisecondsSinceEpoch,
    author: author,
    audioPaths: audioPaths.isNotEmpty ? List<String>.of(audioPaths) : null,
  );
  if (patched) return;

  // 行不存在：这才是真正的整行创建。cover_path 刻意留空（见上文）。
  final SrtBook book = SrtBook()
    ..uid = uid
    ..title = title
    ..srtPath = srtPath
    ..importedAt = DateTime.now().millisecondsSinceEpoch
    ..bookKey = bookKey;
  if (audioPaths.isNotEmpty) {
    book.audioPaths = List<String>.of(audioPaths);
  }
  if (author != null) {
    book.author = author;
  }
  await repo.save(book);
}
