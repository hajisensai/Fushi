/// Kavita EPUB 的「打开即缓存」与「固定（下载）」。
///
/// 流程：打开一章 EPUB →
/// 1. 先按绑定查本地是否已有这一章（同服务器 + 同 chapterId）→ 有就直接返回 bookKey，
///    不重复下载；
/// 2. 没有就把原文件流式下载到临时目录，交给既有 EPUB 导入器入库（和手动导入、
///    发现页下载走同一条导入路径，零新导入逻辑），再把绑定写进书行；
/// 3. 临时文件无论成败都清掉。
///
/// 「下载」= [pin]：把 `cachedOnly` 翻成 false。缓存副本与固定副本在书库里是同一类
/// 本地书，区别只在这个标记（清理缓存时只动 `cachedOnly == true` 的书）。
library;

import 'dart:io';

import 'package:drift/drift.dart' show StringExpressionOperators, Value;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/book_title_conflict.dart'
    show DuplicatePolicy;
import 'package:fushi_engine/epub/epub_importer.dart';
import 'package:fushi_engine/media/kavita/kavita_api.dart';
import 'package:fushi_engine/media/kavita/kavita_models.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/kavita/kavita_book_binding.dart';

/// 把磁盘上的 EPUB 导入书库，返回 bookKey。生产实现走 `EpubImporter.importFromPath`。
typedef KavitaEpubImporter =
    Future<String> Function(String filePath, String fileName);

/// 书已绑定但本地行/文件不见了、服务器不可用等“可恢复”的失败。
class KavitaBookOpenException implements Exception {
  const KavitaBookOpenException(this.message);
  final String message;

  @override
  String toString() => 'KavitaBookOpenException($message)';
}

class KavitaBookService {
  KavitaBookService({
    required FushiDatabase db,
    required Directory tempRoot,
    KavitaEpubImporter? importEpub,
    int Function()? nowMs,
  }) : _db = db,
       _tempRoot = tempRoot,
       _importEpub = importEpub ?? _defaultImport(db),
       _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  final FushiDatabase _db;
  final Directory _tempRoot;
  final KavitaEpubImporter _importEpub;
  final int Function() _nowMs;

  static KavitaEpubImporter _defaultImport(FushiDatabase db) =>
      (String filePath, String fileName) => EpubImporter.importFromPath(
        db: db,
        filePath: filePath,
        fileName: fileName,
        // 与手动导入一致：同名书留副本，不静默吞掉 Kavita 这本。
        policy: const DuplicatePolicy.suffix(),
      );

  /// 本地已绑定这一章的书的 bookKey；没有返回 null。
  Future<String?> findBookKey({
    required String serverConfigId,
    required int chapterId,
  }) async {
    final List<EpubBookRow> rows = await (_db.select(
      _db.epubBooks,
    )..where((t) => t.sourceMetadata.like('%$kKavitaBookMarker%'))).get();
    for (final EpubBookRow row in rows) {
      final KavitaBookBinding? binding = KavitaBookBinding.tryParse(
        row.sourceMetadata,
      );
      if (binding != null && binding.sameChapterAs(serverConfigId, chapterId)) {
        return row.bookKey;
      }
    }
    return null;
  }

  /// 读某本书的绑定；不是 Kavita 书返回 null。
  Future<KavitaBookBinding?> bindingFor(String bookKey) async {
    final EpubBookRow? row = await _db.getEpubBook(bookKey);
    return KavitaBookBinding.tryParse(row?.sourceMetadata);
  }

  /// 打开（必要时下载并导入）一章 EPUB，返回 bookKey。
  Future<String> openOrImport({
    required String serverConfigId,
    required KavitaApi api,
    required KavitaSeries series,
    required KavitaChapter chapter,
    void Function(int received, int? total)? onProgress,
    KavitaCancelToken? cancelToken,
  }) async {
    final String? existing = await findBookKey(
      serverConfigId: serverConfigId,
      chapterId: chapter.id,
    );
    if (existing != null) return existing;

    await _tempRoot.create(recursive: true);
    final Directory work = await _tempRoot.createTemp('kavita_epub_');
    try {
      final File target = File(p.join(work.path, 'book.epub'));
      final KavitaDownloadResult downloaded = await api.downloadChapter(
        chapter.id,
        target,
        onProgress: onProgress,
        token: cancelToken,
      );
      final String fileName = _safeFileName(
        downloaded.fileName,
        fallback: '${series.displayName}.epub',
      );
      final String bookKey = await _importEpub(downloaded.file.path, fileName);
      final KavitaBookBinding binding = KavitaBookBinding(
        serverConfigId: serverConfigId,
        seriesId: series.id,
        volumeId: chapter.volumeId,
        chapterId: chapter.id,
        libraryId: series.libraryId,
        format: KavitaFormat.epub,
        cachedOnly: true,
      );
      await _writeBinding(bookKey, binding);
      return bookKey;
    } finally {
      try {
        await work.delete(recursive: true);
      } on FileSystemException {
        // 临时目录清不掉不影响已入库的书。
      }
    }
  }

  /// 固定（用户点「下载」）：缓存副本转为长期保留。书没绑定时返回 false。
  Future<bool> pin(String bookKey) => _setCachedOnly(bookKey, false);

  /// 取消固定：回到可清理的缓存副本。
  Future<bool> unpin(String bookKey) => _setCachedOnly(bookKey, true);

  Future<bool> _setCachedOnly(String bookKey, bool cachedOnly) async {
    final KavitaBookBinding? binding = await bindingFor(bookKey);
    if (binding == null) return false;
    await _writeBinding(bookKey, binding.copyWith(cachedOnly: cachedOnly));
    return true;
  }

  /// 记一次进度交换（推 / 拉）后的绑定戳。
  Future<void> recordSync(
    String bookKey, {
    bool pushed = false,
    bool pulled = false,
    int? page,
    String? bookScrollId,
  }) async {
    final KavitaBookBinding? binding = await bindingFor(bookKey);
    if (binding == null) return;
    final int now = _nowMs();
    await _writeBinding(
      bookKey,
      binding.copyWith(
        lastPushedAt: pushed ? now : null,
        lastPulledAt: pulled ? now : null,
        lastPushedPage: pushed ? page : null,
        bookScrollId: bookScrollId,
      ),
    );
  }

  /// 缓存副本（未固定）的 bookKey 列表，供清理缓存使用。
  Future<List<String>> cachedBookKeys() async {
    final List<EpubBookRow> rows = await (_db.select(
      _db.epubBooks,
    )..where((t) => t.sourceMetadata.like('%$kKavitaBookMarker%'))).get();
    return <String>[
      for (final EpubBookRow row in rows)
        if (KavitaBookBinding.tryParse(row.sourceMetadata)?.cachedOnly == true)
          row.bookKey,
    ];
  }

  Future<void> _writeBinding(String bookKey, KavitaBookBinding binding) async {
    await (_db.update(_db.epubBooks)..where((t) => t.bookKey.equals(bookKey)))
        .write(EpubBooksCompanion(sourceMetadata: Value(binding.encode())));
  }

  /// 服务器给的文件名可能带路径片段 / 缺失：取 basename，保证 `.epub` 结尾。
  static String _safeFileName(String? name, {required String fallback}) {
    String base = (name ?? '').trim();
    base = p.basename(base.replaceAll('\\', '/'));
    if (base.isEmpty || base == '.' || base == '..') base = fallback;
    if (!base.toLowerCase().endsWith('.epub')) base = '$base.epub';
    return base;
  }
}
