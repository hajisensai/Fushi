/// Kavita EPUB 的「打开即缓存」与「下载（持久副本）」。
///
/// 流程：打开一章 EPUB →
/// 1. 先按绑定查本地是否已有这一章（同服务器 + 同 chapterId）→ 有就直接返回 bookKey，
///    不重复下载；
/// 2. 没有就把原文件流式下载到临时目录，交给既有 EPUB 导入器入库（和手动导入、
///    发现页下载走同一条导入路径，零新导入逻辑），再把绑定写进书行；
/// 3. 临时文件无论成败都清掉。
///
/// 两态（区别只在绑定的 `cachedOnly`）：
/// - **缓存副本**（「阅读」产生）：最多保留 [kKavitaCachedBookLimit] 本，超出按最近使用
///   淘汰（[KavitaBookService.trimCache]），设置里可一键清理
///   （[KavitaBookService.clearCache]）；
/// - **持久副本**（用户显式「下载」= [KavitaBookService.pin]）：只有「移除下载」
///   （[KavitaBookService.removeDownload]）才删。
///
/// 所有删除都走书架删书原语 `ReaderFushiSource.deleteBook`（删行 + 解压目录 + 有声书
/// 副本，与书架单删同一条路），不裸删目录。删之前若本地阅读位置还没同步到服务器，先
/// 推一次（[KavitaProgressSync]，带「不覆盖更新的服务器进度」校验）；推不出去（离线 /
/// 无服务器配置）就**保留**这本书，不丢本地进度。服务器进度本身在服务器上，绑定靠
/// 「服务器配置 id + chapterId」由 Kavita 页重建，所以删掉本地行不丢同步身份。
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
import 'package:fushi/src/media/kavita/kavita_progress_sync.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';

/// 「阅读」产生的缓存副本最多留几本（按最近使用淘汰）。显式「下载」的不计入。
const int kKavitaCachedBookLimit = 8;

/// 把磁盘上的 EPUB 导入书库，返回 bookKey。生产实现走 `EpubImporter.importFromPath`。
typedef KavitaEpubImporter =
    Future<String> Function(String filePath, String fileName);

/// 删一本本地书，返回是否真删了。生产实现走 `ReaderFushiSource.deleteBook`。
typedef KavitaBookDeleter = Future<bool> Function(String bookKey);

/// 按服务器配置 id 取协议层客户端；服务器已删除 / 停用时返回 null。
typedef KavitaApiResolver = KavitaApi? Function(String serverConfigId);

/// 删一本 Kavita 本地书的结果。
enum KavitaLocalRemoval {
  /// 本地文件与书架条目已删。
  removed,

  /// 本地有尚未同步到服务器的进度、且这次推不出去：书保留。
  keptUnsynced,

  /// 不是 Kavita 书 / 删除原语失败。
  failed,
}

/// 一次清理（淘汰 / 一键清理）的计数。
class KavitaCacheCleanup {
  const KavitaCacheCleanup({
    this.removed = 0,
    this.keptUnsynced = 0,
    this.failed = 0,
  });

  final int removed;
  final int keptUnsynced;
  final int failed;

  KavitaCacheCleanup add(KavitaLocalRemoval outcome) => KavitaCacheCleanup(
    removed: removed + (outcome == KavitaLocalRemoval.removed ? 1 : 0),
    keptUnsynced:
        keptUnsynced + (outcome == KavitaLocalRemoval.keptUnsynced ? 1 : 0),
    failed: failed + (outcome == KavitaLocalRemoval.failed ? 1 : 0),
  );
}

/// 书已绑定但本地行/文件不见了、服务器不可用等“可恢复”的失败。
class KavitaBookOpenException implements Exception {
  const KavitaBookOpenException(this.message);
  final String message;

  @override
  String toString() => 'KavitaBookOpenException($message)';
}

typedef _CachedEntry = ({EpubBookRow row, KavitaBookBinding binding});

class KavitaBookService {
  KavitaBookService({
    required FushiDatabase db,
    Directory? tempRoot,
    KavitaEpubImporter? importEpub,
    KavitaBookDeleter? deleteBook,
    KavitaApiResolver? apiFor,
    int cacheLimit = kKavitaCachedBookLimit,
    Duration pushTimeout = const Duration(seconds: 8),
    int Function()? nowMs,
  }) : _db = db,
       _tempRoot = tempRoot,
       _importEpub = importEpub ?? _defaultImport(db),
       _deleteBook = deleteBook ?? _defaultDelete(db),
       _apiFor = apiFor,
       _cacheLimit = cacheLimit,
       _pushTimeout = pushTimeout,
       _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  final FushiDatabase _db;

  /// 下载临时目录；只有 [openOrImport] 需要（绑定读写不需要）。
  final Directory? _tempRoot;
  final KavitaEpubImporter _importEpub;
  final KavitaBookDeleter _deleteBook;

  /// 删之前推未同步进度用；null = 推不了（有未同步进度的书一律保留）。
  final KavitaApiResolver? _apiFor;
  final int _cacheLimit;
  final Duration _pushTimeout;
  final int Function() _nowMs;

  /// 进程内串行化所有删除（淘汰 / 一键清理 / 移除下载）：详情页与设置页各自的服务
  /// 实例并发时也不会对同一本书删两次。每一轮都在锁内重新读库。
  static Future<void> _removalLock = Future<void>.value();

  static Future<T> _serialized<T>(Future<T> Function() body) {
    final Future<T> run = _removalLock.then((_) => body());
    _removalLock = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  static KavitaEpubImporter _defaultImport(FushiDatabase db) =>
      (String filePath, String fileName) => EpubImporter.importFromPath(
        db: db,
        filePath: filePath,
        fileName: fileName,
        // 与手动导入一致：同名书留副本，不静默吞掉 Kavita 这本。
        policy: const DuplicatePolicy.suffix(),
      );

  static KavitaBookDeleter _defaultDelete(FushiDatabase db) =>
      (String bookKey) async => (await ReaderFushiSource.instance.deleteBook(
        db: db,
        bookKey: bookKey,
      )).deleted;

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

  /// 一次取出 [serverConfigId] 上所有已绑定的章：chapterId → 绑定（含 pin 状态）。
  /// 详情页一次查询渲染整列「已下载 / 已缓存」徽标，免得逐章查库。
  Future<Map<int, ({String bookKey, KavitaBookBinding binding})>> boundChapters(
    String serverConfigId,
  ) async {
    final List<EpubBookRow> rows = await (_db.select(
      _db.epubBooks,
    )..where((t) => t.sourceMetadata.like('%$kKavitaBookMarker%'))).get();
    final Map<int, ({String bookKey, KavitaBookBinding binding})> out =
        <int, ({String bookKey, KavitaBookBinding binding})>{};
    for (final EpubBookRow row in rows) {
      final KavitaBookBinding? binding = KavitaBookBinding.tryParse(
        row.sourceMetadata,
      );
      if (binding != null && binding.serverConfigId == serverConfigId) {
        out[binding.chapterId] = (bookKey: row.bookKey, binding: binding);
      }
    }
    return out;
  }

  /// 读某本书的绑定；不是 Kavita 书返回 null。
  Future<KavitaBookBinding?> bindingFor(String bookKey) async {
    final EpubBookRow? row = await _db.getEpubBook(bookKey);
    return KavitaBookBinding.tryParse(row?.sourceMetadata);
  }

  /// 打开（必要时下载并导入）一章 EPUB，返回 bookKey。新导入的是缓存副本；
  /// 调用方随后应 [trimCache]（`keep` = 返回的 bookKey）把缓存收回上限。
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
    if (existing != null) {
      await _touch(existing);
      return existing;
    }

    final Directory? root = _tempRoot;
    if (root == null) {
      throw StateError('KavitaBookService.openOrImport needs a tempRoot');
    }
    await root.create(recursive: true);
    final Directory work = await root.createTemp('kavita_epub_');
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
        lastOpenedAt: _nowMs(),
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

  /// 固定（用户点「下载」）：缓存副本转为持久副本。书没绑定时返回 false。
  Future<bool> pin(String bookKey) => _setCachedOnly(bookKey, false);

  /// 取消固定：回到可清理的缓存副本（不删任何东西）。
  Future<bool> unpin(String bookKey) => _setCachedOnly(bookKey, true);

  Future<bool> _setCachedOnly(String bookKey, bool cachedOnly) async {
    final KavitaBookBinding? binding = await bindingFor(bookKey);
    if (binding == null) return false;
    await _writeBinding(bookKey, binding.copyWith(cachedOnly: cachedOnly));
    return true;
  }

  /// 记一次进度交换（推 / 拉）后的绑定戳。
  ///
  /// [page] 是这次交换后两侧一致的页号（推出去的页 / 采用的服务器页 / 拉取时两侧
  /// 相同的页），推与拉都记；拉取后两侧仍不一致时传 null，保留旧基线。
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
        lastPushedPage: page,
        bookScrollId: bookScrollId,
      ),
    );
  }

  /// 缓存副本（未固定）的 bookKey 列表（设置页显示数量用）。
  Future<List<String>> cachedBookKeys() async => <String>[
    for (final _CachedEntry e in await _cachedEntries()) e.row.bookKey,
  ];

  /// 把缓存副本收回到上限以内：按最近使用（打开时刻 / 阅读位置更新时刻 / 导入时刻
  /// 取最新）留前 `cacheLimit` 本，其余删除。[keep] 是刚打开的那本，无论如何不删。
  /// 有未同步进度且推不出去的书保留，下一轮再试。
  Future<KavitaCacheCleanup> trimCache({String? keep}) => _serialized(() async {
    final List<_CachedEntry> cached = await _cachedEntries();
    if (cached.length <= _cacheLimit) return const KavitaCacheCleanup();
    final Map<String, int> recency = <String, int>{
      for (final _CachedEntry e in cached)
        e.row.bookKey: await _recencyOf(e.row, e.binding),
    };
    int order(_CachedEntry a, _CachedEntry b) {
      if (a.row.bookKey == keep) return -1;
      if (b.row.bookKey == keep) return 1;
      return recency[b.row.bookKey]!.compareTo(recency[a.row.bookKey]!);
    }

    cached.sort(order);
    KavitaCacheCleanup result = const KavitaCacheCleanup();
    for (final _CachedEntry e in cached.skip(_cacheLimit)) {
      if (e.row.bookKey == keep) continue;
      result = result.add(await _removeLocal(e.row, e.binding));
    }
    return result;
  });

  /// 一键清理全部缓存副本（显式下载的不动）。
  Future<KavitaCacheCleanup> clearCache() => _serialized(() async {
    KavitaCacheCleanup result = const KavitaCacheCleanup();
    for (final _CachedEntry e in await _cachedEntries()) {
      result = result.add(await _removeLocal(e.row, e.binding));
    }
    return result;
  });

  /// 「移除下载」：删掉本地文件与书架条目。本地进度推不出去时不删，而是降回缓存副本
  /// （之后进度同步了，照常按上限淘汰或被一键清理带走），返回
  /// [KavitaLocalRemoval.keptUnsynced]。
  Future<KavitaLocalRemoval> removeDownload(String bookKey) =>
      _serialized(() async {
        final EpubBookRow? row = await _db.getEpubBook(bookKey);
        final KavitaBookBinding? binding = KavitaBookBinding.tryParse(
          row?.sourceMetadata,
        );
        if (row == null || binding == null) return KavitaLocalRemoval.failed;
        final KavitaLocalRemoval outcome = await _removeLocal(row, binding);
        if (outcome == KavitaLocalRemoval.keptUnsynced && !binding.cachedOnly) {
          await _setCachedOnly(bookKey, true);
        }
        return outcome;
      });

  Future<List<_CachedEntry>> _cachedEntries() async {
    final List<EpubBookRow> rows = await (_db.select(
      _db.epubBooks,
    )..where((t) => t.sourceMetadata.like('%$kKavitaBookMarker%'))).get();
    return <_CachedEntry>[
      for (final EpubBookRow row in rows)
        if (KavitaBookBinding.tryParse(row.sourceMetadata)
            case final KavitaBookBinding binding when binding.cachedOnly)
          (row: row, binding: binding),
    ];
  }

  Future<int> _recencyOf(EpubBookRow row, KavitaBookBinding binding) async {
    final ReaderPositionRow? position = row.uid.isEmpty
        ? null
        : await _db.getReaderPosition(row.uid);
    int latest = row.importedAt;
    for (final int? at in <int?>[binding.lastOpenedAt, position?.updatedAt]) {
      if (at != null && at > latest) latest = at;
    }
    return latest;
  }

  /// 先保住进度，再走删书原语。
  Future<KavitaLocalRemoval> _removeLocal(
    EpubBookRow row,
    KavitaBookBinding binding,
  ) async {
    if (!await _settleProgress(row, binding)) {
      return KavitaLocalRemoval.keptUnsynced;
    }
    return await _deleteBook(row.bookKey)
        ? KavitaLocalRemoval.removed
        : KavitaLocalRemoval.failed;
  }

  /// 本地阅读位置是否已经和服务器一致（或已被服务器上更新的进度取代）。
  ///
  /// 基线是绑定里的 `lastPushedPage`（最近一次两侧一致的脊柱页；从没同步过 = 0，即
  /// 书首）。本地停在基线上 = 没有要推的。动过就推一次：成功 = 已同步；服务器自上次
  /// 同步后被别处推进过（[KavitaProgressSync] 拒推）= 服务器那边更新，本地这份已过时，
  /// 删掉不丢东西；其余（离线 / 超时 / 无服务器配置）= 没保住，返回 false。
  Future<bool> _settleProgress(
    EpubBookRow row,
    KavitaBookBinding binding,
  ) async {
    final ReaderPositionRow? local = row.uid.isEmpty
        ? null
        : await _db.getReaderPosition(row.uid);
    if (local == null) return true;
    if (local.sectionIndex == (binding.lastPushedPage ?? 0)) return true;
    final KavitaApi? api = _apiFor?.call(binding.serverConfigId);
    if (api == null) return false;
    final int? pushedAt = binding.lastPushedAt;
    final int? pulledAt = binding.lastPulledAt;
    final int? lastSyncAt = pushedAt == null
        ? pulledAt
        : (pulledAt == null || pushedAt > pulledAt ? pushedAt : pulledAt);
    bool serverNewer = false;
    final KavitaProgressSync sync = KavitaProgressSync(
      api: api,
      target: KavitaProgressTarget(
        seriesId: binding.seriesId,
        volumeId: binding.volumeId,
        chapterId: binding.chapterId,
        libraryId: binding.libraryId,
        totalPages: row.chapterCount,
      ),
      debounce: Duration.zero,
      lastPushedPage: binding.lastPushedPage,
      lastSyncAt: lastSyncAt,
      nowMs: _nowMs,
      onServerNewer: (KavitaProgress _) => serverNewer = true,
    );
    try {
      sync.reportPage(local.sectionIndex);
      final bool pushed = await sync.flush().timeout(
        _pushTimeout,
        onTimeout: () => false,
      );
      if (pushed) {
        await recordSync(row.bookKey, pushed: true, page: local.sectionIndex);
        return true;
      }
      return serverNewer;
    } finally {
      sync.dispose();
    }
  }

  /// 记一次经 Kavita 页打开（缓存淘汰按它排最近使用）。
  Future<void> _touch(String bookKey) async {
    final KavitaBookBinding? binding = await bindingFor(bookKey);
    if (binding == null) return;
    await _writeBinding(bookKey, binding.copyWith(lastOpenedAt: _nowMs()));
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
