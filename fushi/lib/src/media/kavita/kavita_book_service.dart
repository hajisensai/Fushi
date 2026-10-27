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
///
/// 删书原语会连带删掉书签 / 单书 CSS / 有声书与字幕配对 / 标签 / 合集成员身份，这些
/// 只在本机、服务器上没有副本，所以**带这些用户数据的缓存副本不参与自动淘汰与一键
/// 清理**（只有用户显式「移除下载」或在书架删书才删）。删除与打开 / 固定共用一把锁，
/// 且每本删前在锁内按最新状态复核（见 [KavitaBookService.trimCache]）。
library;

import 'dart:io';

import 'package:drift/drift.dart'
    show
        BooleanExpressionOperators,
        HasResultSet,
        SimpleSelectStatement,
        StringExpressionOperators,
        Value;
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

/// 一本 Kavita 本地书此刻的状态快照（书行 + 绑定 + 本地阅读位置）。删除分三步——
/// 锁内选中、锁外推进度、锁内复核再删——复核时拿新快照和选中时的比，判断推进度那段
/// 时间里有没有人打开 / 读过 / 固定过这本书。
typedef _Entry = ({
  EpubBookRow row,
  KavitaBookBinding binding,
  ReaderPositionRow? position,
});

/// 一次受保护删除的结局（比 [KavitaLocalRemoval] 多两种「不删」的情形）。
enum _GuardedRemoval {
  removed,
  keptUnsynced,
  failed,

  /// 复核时书已经不在了（别的删除先删了）。
  gone,

  /// 推进度期间这本书被打开 / 读过 / 固定 / 加了用户数据：不删。
  changed,
}

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

  /// 进程内一把锁，串行化「改变一本书去留」的短临界区：选删除目标、复核并删、
  /// 打开时的查找 + 记使用（[openOrImport]）、固定 / 取消固定。详情页、设置页与进度
  /// 同步各自的服务实例共用它（static）。推进度这种可能等网络的步骤**不在锁里**，
  /// 所以淘汰再慢也不挡开书；代价是删前必须在锁内复核（[_removeGuarded]）。
  /// 不可重入：锁内只调 `*Unlocked` 版本。
  static Future<void> _lock = Future<void>.value();

  static Future<T> _serialized<T>(Future<T> Function() body) {
    final Future<T> run = _lock.then((_) => body());
    _lock = run.then<void>((_) {}, onError: (Object _) {});
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
    for (final EpubBookRow row in await _kavitaRows()) {
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
    final Map<int, ({String bookKey, KavitaBookBinding binding})> out =
        <int, ({String bookKey, KavitaBookBinding binding})>{};
    for (final EpubBookRow row in await _kavitaRows()) {
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
  ///
  /// 「查本地有没有 + 记一次使用」在删除锁里一步完成：要么删除先发生（这里查不到，
  /// 重新下载），要么先记上使用（删除复核看到使用变了就不删），不会返回一本马上被删
  /// 掉的书。
  Future<String> openOrImport({
    required String serverConfigId,
    required KavitaApi api,
    required KavitaSeries series,
    required KavitaChapter chapter,
    void Function(int received, int? total)? onProgress,
    KavitaCancelToken? cancelToken,
  }) async {
    final String? existing = await _serialized(() async {
      final String? key = await findBookKey(
        serverConfigId: serverConfigId,
        chapterId: chapter.id,
      );
      if (key != null) await _touchUnlocked(key);
      return key;
    });
    if (existing != null) return existing;

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
  Future<bool> pin(String bookKey) =>
      _serialized(() => _setCachedOnlyUnlocked(bookKey, false));

  /// 取消固定：回到可清理的缓存副本（不删任何东西）。
  Future<bool> unpin(String bookKey) =>
      _serialized(() => _setCachedOnlyUnlocked(bookKey, true));

  Future<bool> _setCachedOnlyUnlocked(String bookKey, bool cachedOnly) =>
      _updateBinding(
        bookKey,
        (KavitaBookBinding b) => b.copyWith(cachedOnly: cachedOnly),
      );

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
    final int now = _nowMs();
    await _updateBinding(
      bookKey,
      (KavitaBookBinding b) => b.copyWith(
        lastPushedAt: pushed ? now : null,
        lastPulledAt: pulled ? now : null,
        lastPushedPage: page,
        bookScrollId: bookScrollId,
      ),
    );
  }

  /// 可被清理的缓存副本（未固定、且没有用户数据）的 bookKey 列表。设置页「清理缓存」
  /// 按钮上的数字用它——与 [clearCache] 实际会动的范围一致。
  Future<List<String>> cachedBookKeys() async => <String>[
    for (final _Entry e in await _evictableEntries()) e.row.bookKey,
  ];

  /// 把缓存副本收回到上限以内：按最近使用（打开时刻 / 阅读位置更新时刻 / 导入时刻
  /// 取最新）留前 `cacheLimit` 本，其余删除。[keep] 是刚打开的那本，无论如何不删。
  ///
  /// 只淘汰**可清理**的缓存副本：带书签 / 单书 CSS / 有声书或字幕配对 / 标签 / 合集
  /// 成员身份的书不参与淘汰、也不占上限——这些是用户在本机产生、服务器上没有副本的
  /// 数据，删书原语会把它们连同书一起删掉，自动淘汰不能替用户做这个决定。
  /// 有未同步进度且推不出去的书保留，下一轮再试。
  ///
  /// 每删一本都在锁内重新读库选下一个目标（不是开头拍一次快照逐本删），所以淘汰
  /// 期间被打开、读到、固定的书会按最新状态重新排位。
  Future<KavitaCacheCleanup> trimCache({String? keep}) async {
    KavitaCacheCleanup result = const KavitaCacheCleanup();
    final Set<String> attempted = <String>{};
    while (true) {
      final _Entry? victim = await _serialized(() async {
        for (final _Entry e in await _trimVictims(keep)) {
          if (!attempted.contains(e.row.bookKey)) return e;
        }
        return null;
      });
      if (victim == null) return result;
      attempted.add(victim.row.bookKey);
      final _GuardedRemoval outcome = await _removeGuarded(
        victim,
        stillRemovable: (_Entry fresh) async =>
            _sameUse(victim, fresh) &&
            (await _trimVictims(
              keep,
            )).any((_Entry e) => e.row.bookKey == fresh.row.bookKey),
      );
      result = _tally(result, outcome);
    }
  }

  /// 一键清理全部可清理的缓存副本（显式下载的、带用户数据的不动）。
  Future<KavitaCacheCleanup> clearCache() async {
    KavitaCacheCleanup result = const KavitaCacheCleanup();
    final Set<String> attempted = <String>{};
    while (true) {
      final _Entry? victim = await _serialized(() async {
        for (final _Entry e in await _evictableEntries()) {
          if (!attempted.contains(e.row.bookKey)) return e;
        }
        return null;
      });
      if (victim == null) return result;
      attempted.add(victim.row.bookKey);
      final _GuardedRemoval outcome = await _removeGuarded(
        victim,
        stillRemovable: (_Entry fresh) async =>
            _sameUse(victim, fresh) && !await _hasUserData(fresh.row),
      );
      result = _tally(result, outcome);
    }
  }

  /// 「移除下载」：用户显式删这本书（与书架单删同义，书签等随书删除）。本地进度推
  /// 不出去时不删，而是降回缓存副本（之后进度同步了，照常按上限淘汰或被一键清理
  /// 带走），返回 [KavitaLocalRemoval.keptUnsynced]。推进度期间本地位置又动了（正在
  /// 读）同样按未同步处理。
  Future<KavitaLocalRemoval> removeDownload(String bookKey) async {
    final _Entry? entry = await _serialized(() => _entryFor(bookKey));
    if (entry == null) return KavitaLocalRemoval.failed;
    final _GuardedRemoval outcome = await _removeGuarded(
      entry,
      stillRemovable: (_Entry fresh) async =>
          _samePosition(entry.position, fresh.position),
    );
    switch (outcome) {
      case _GuardedRemoval.removed:
      case _GuardedRemoval.gone:
        return KavitaLocalRemoval.removed;
      case _GuardedRemoval.failed:
        return KavitaLocalRemoval.failed;
      case _GuardedRemoval.keptUnsynced:
      case _GuardedRemoval.changed:
        await _serialized(() async {
          final KavitaBookBinding? now = await bindingFor(bookKey);
          if (now != null && !now.cachedOnly) {
            await _setCachedOnlyUnlocked(bookKey, true);
          }
        });
        return KavitaLocalRemoval.keptUnsynced;
    }
  }

  static KavitaCacheCleanup _tally(
    KavitaCacheCleanup result,
    _GuardedRemoval outcome,
  ) => switch (outcome) {
    _GuardedRemoval.removed => result.add(KavitaLocalRemoval.removed),
    _GuardedRemoval.keptUnsynced => result.add(KavitaLocalRemoval.keptUnsynced),
    _GuardedRemoval.failed => result.add(KavitaLocalRemoval.failed),
    _GuardedRemoval.gone || _GuardedRemoval.changed => result,
  };

  /// 先保住进度（锁外，可能等网络），再在锁内按最新状态复核：书还在、
  /// [stillRemovable] 仍成立才走删书原语。复核与删除同在锁内，[openOrImport] /
  /// [pin] 不可能插进这两步之间。
  Future<_GuardedRemoval> _removeGuarded(
    _Entry victim, {
    required Future<bool> Function(_Entry fresh) stillRemovable,
  }) async {
    if (!await _settleProgress(victim.row, victim.binding)) {
      return _GuardedRemoval.keptUnsynced;
    }
    return _serialized(() async {
      final _Entry? fresh = await _entryFor(victim.row.bookKey);
      if (fresh == null) return _GuardedRemoval.gone;
      if (!await stillRemovable(fresh)) return _GuardedRemoval.changed;
      return await _deleteBook(fresh.row.bookKey)
          ? _GuardedRemoval.removed
          : _GuardedRemoval.failed;
    });
  }

  /// 选中后到复核前，这本书的「使用」没变：仍是同一行、去留状态没翻、没被经 Kavita
  /// 页打开过、本地阅读位置没动（动了 = 正在读，且推出去的进度已过时）。
  static bool _sameUse(_Entry a, _Entry b) =>
      a.row.uid == b.row.uid &&
      a.binding.cachedOnly == b.binding.cachedOnly &&
      a.binding.lastOpenedAt == b.binding.lastOpenedAt &&
      _samePosition(a.position, b.position);

  static bool _samePosition(ReaderPositionRow? a, ReaderPositionRow? b) {
    if (a == null || b == null) return a == b;
    return a.sectionIndex == b.sectionIndex &&
        a.normCharOffset == b.normCharOffset &&
        a.updatedAt == b.updatedAt;
  }

  /// 按淘汰规则此刻该删的缓存副本（最旧的在后）。
  Future<List<_Entry>> _trimVictims(String? keep) async {
    final List<_Entry> evictable = await _evictableEntries();
    if (evictable.length <= _cacheLimit) return const <_Entry>[];
    int order(_Entry a, _Entry b) {
      if (a.row.bookKey == keep) return -1;
      if (b.row.bookKey == keep) return 1;
      return _recencyOf(b).compareTo(_recencyOf(a));
    }

    evictable.sort(order);
    return <_Entry>[
      for (final _Entry e in evictable.skip(_cacheLimit))
        if (e.row.bookKey != keep) e,
    ];
  }

  Future<List<EpubBookRow>> _kavitaRows() => (_db.select(
    _db.epubBooks,
  )..where((t) => t.sourceMetadata.like('%$kKavitaBookMarker%'))).get();

  Future<_Entry> _entryOf(EpubBookRow row, KavitaBookBinding binding) async => (
    row: row,
    binding: binding,
    position: row.uid.isEmpty ? null : await _db.getReaderPosition(row.uid),
  );

  Future<_Entry?> _entryFor(String bookKey) async {
    final EpubBookRow? row = await _db.getEpubBook(bookKey);
    final KavitaBookBinding? binding = KavitaBookBinding.tryParse(
      row?.sourceMetadata,
    );
    if (row == null || binding == null) return null;
    return _entryOf(row, binding);
  }

  /// 可被自动淘汰 / 一键清理的缓存副本：未固定、且没有用户数据。
  Future<List<_Entry>> _evictableEntries() async => <_Entry>[
    for (final EpubBookRow row in await _kavitaRows())
      if (KavitaBookBinding.tryParse(row.sourceMetadata)
          case final KavitaBookBinding binding
          when binding.cachedOnly && !await _hasUserData(row))
        await _entryOf(row, binding),
  ];

  /// 这本书是否带着删书原语（`deleteEpubBook`）会一并删掉、而服务器上没有副本的
  /// 用户数据：书签、单书自定义 CSS、有声书 / 字幕配对、标签、合集成员身份。阅读
  /// 位置不算——它由 [_settleProgress] 先推到服务器。
  Future<bool> _hasUserData(EpubBookRow row) async {
    final String uid = row.uid;
    final String key = row.bookKey;
    if (uid.isNotEmpty) {
      if (await _exists(
        _db.select(_db.bookmarks)..where((t) => t.bookUid.equals(uid)),
      )) {
        return true;
      }
      if (await _exists(
        _db.select(_db.bookCustomCss)
          ..where((t) => t.bookUid.equals(uid) & t.deleted.equals(false)),
      )) {
        return true;
      }
      if (await _exists(
        _db.select(_db.mediaCollectionItems)..where(
          (t) =>
              t.mediaType.equals(MediaKind.epub.dbValue) &
              t.entryKey.equals(uid),
        ),
      )) {
        return true;
      }
    }
    if (await _exists(
      _db.select(_db.audiobooks)..where((t) => t.bookKey.equals(key)),
    )) {
      return true;
    }
    if (await _exists(
      _db.select(_db.srtBooks)..where((t) => t.bookKey.equals(key)),
    )) {
      return true;
    }
    return _exists(
      _db.select(_db.tagAssignments)..where(
        (t) =>
            t.mediaKind.equals(TagHostKind.epub.dbValue) &
            t.entryKey.equals(key),
      ),
    );
  }

  static Future<bool> _exists<T extends HasResultSet, D>(
    SimpleSelectStatement<T, D> query,
  ) async {
    query.limit(1);
    return (await query.get()).isNotEmpty;
  }

  static int _recencyOf(_Entry e) {
    int latest = e.row.importedAt;
    for (final int? at in <int?>[
      e.binding.lastOpenedAt,
      e.position?.updatedAt,
    ]) {
      if (at != null && at > latest) latest = at;
    }
    return latest;
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

  /// 记一次经 Kavita 页打开（缓存淘汰按它排最近使用）。调用方须已持锁。
  Future<void> _touchUnlocked(String bookKey) => _updateBinding(
    bookKey,
    (KavitaBookBinding b) => b.copyWith(lastOpenedAt: _nowMs()),
  );

  /// 读-改-写绑定放在一个事务里：进度同步（[recordSync]）与固定 / 记使用并发时，
  /// 互不覆盖对方刚写的字段（否则 recordSync 可能把刚固定的书写回缓存副本）。
  Future<bool> _updateBinding(
    String bookKey,
    KavitaBookBinding Function(KavitaBookBinding current) change,
  ) => _db.transaction(() async {
    final KavitaBookBinding? current = await bindingFor(bookKey);
    if (current == null) return false;
    await _writeBinding(bookKey, change(current));
    return true;
  });

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
