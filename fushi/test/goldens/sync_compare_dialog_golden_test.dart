import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/sync/sync_asset_store.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_compare_dialog.dart';
import 'package:fushi/src/sync/sync_file_ref.dart';
import 'package:fushi/src/sync/ttu_filename.dart';
import 'package:fushi/src/sync/ttu_models.dart';
import 'package:fushi_core/fushi_core.dart';

/// 同步对比对话框排版的 golden（C3 改前/改后对照）。
///
/// 数据：2 本真分叉冲突 + 1 本本地更新（自动上传）+ 1 本远端更新（自动下载）
/// + 1 本远端独有可下载 + 1 个远端独有词典。1200 宽下对话框吃到 720 的上限。
/// 字体是测试字体（Ahem），只比排版不比字形。
FushiDatabase _memDb() =>
    FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

const String _chaptersJson = '[{"characters":1000}]';
const String _dictNamespace = 'dicts';

class _RemoteBook {
  const _RemoteBook({required this.folderId, this.timestampMs, this.fraction});
  final String folderId;
  final int? timestampMs;
  final double? fraction;
}

/// 只实现对比对话框 `_load` 路径会触达的成员；其余经 noSuchMethod 兜底。
class _FakeBackend implements SyncBackend {
  _FakeBackend(this.books);

  final Map<String, _RemoteBook> books;
  String? _root;
  final Map<String, String> _folders = <String, String>{};

  @override
  Future<String> findOrCreateRootFolder() async => _root = 'root';
  @override
  Future<List<SyncFileRef>> listBooks(String rootFolderId) async =>
      <SyncFileRef>[
        for (final MapEntry<String, _RemoteBook> e in books.entries)
          SyncFileRef(id: e.value.folderId, name: e.key),
      ];
  @override
  void cacheBookFolderIds(List<SyncFileRef> folders) {}
  @override
  Future<SyncFileTrio> listSyncFiles(String folderId) async {
    for (final _RemoteBook b in books.values) {
      if (b.folderId != folderId || b.timestampMs == null) continue;
      return SyncFileTrio(
        progress: SyncFileRef(
          id: 'progress-$folderId',
          name: progressFileName(b.timestampMs!, b.fraction!),
        ),
      );
    }
    return const SyncFileTrio();
  }

  @override
  Future<TtuProgress> getProgressFile(String fileId) async {
    for (final _RemoteBook b in books.values) {
      if ('progress-${b.folderId}' != fileId) continue;
      return TtuProgress(
        dataId: 0,
        exploredCharCount: (b.fraction! * 1000).round(),
        progress: b.fraction!,
        lastBookmarkModified: b.timestampMs!,
      );
    }
    throw StateError('no payload for $fileId');
  }

  @override
  Future<String> ensureNamespace(String name) async => _dictNamespace;
  @override
  Future<List<AssetEntry>> listChildren(String id) async {
    if (id == _dictNamespace) {
      return const <AssetEntry>[
        AssetEntry(id: 'dict-jmdict', name: 'JMdict.fushidict'),
      ];
    }
    // 远端独有书的文件夹里有 .epub 才可下载。
    return const <AssetEntry>[AssetEntry(id: 'e', name: 'book.epub')];
  }

  @override
  void clearCache() {
    _root = null;
    _folders.clear();
  }

  @override
  void restoreCache(
      {String? rootFolderId, Map<String, String>? titleToFolderId}) {
    _root = rootFolderId;
    if (titleToFolderId != null) _folders.addAll(titleToFolderId);
  }

  @override
  String? get cachedRootFolderId => _root;
  @override
  Map<String, String> get cachedFolderIds => _folders;
  @override
  Future<bool> get isAuthenticated async => true;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not on the load path');
}

Future<EpubBookRow> _seedBook(FushiDatabase db, String title) async {
  await db.insertEpubBook(EpubBooksCompanion.insert(
    bookKey: title,
    title: title,
    epubPath: '/fake/$title.epub',
    extractDir: '/fake/$title',
    chapterCount: 1,
    chaptersJson: _chaptersJson,
    importedAt: DateTime.now().millisecondsSinceEpoch,
  ));
  return (await db.getAllEpubBooks()).firstWhere((b) => b.title == title);
}

Future<void> _seedPosition(
  FushiDatabase db,
  String bookUid, {
  required int updatedAt,
  required double fraction,
}) async {
  await db.upsertReaderPosition(ReaderPositionsCompanion(
    bookUid: Value(bookUid),
    sectionIndex: const Value(0),
    normCharOffset: Value((fraction * 10000).round()),
    updatedAt: Value(updatedAt),
  ));
}

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  testWidgets('sync compare dialog · wide', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final FushiDatabase db = _memDb();
    addTearDown(db.close);

    // 两本真分叉：本地与远端都偏离 base。
    for (final String title in <String>['Conflict A', 'Conflict B']) {
      final EpubBookRow b = await _seedBook(db, title);
      await _seedPosition(db, b.uid, updatedAt: 120, fraction: 0.6);
      await db.setSyncBaseline(sanitizeTtuFilename(title), 'progress', 50);
    }
    // 本地更新（远端 == base）→ 自动上传。
    final EpubBookRow localNewer = await _seedBook(db, 'Local newer');
    await _seedPosition(db, localNewer.uid, updatedAt: 120, fraction: 0.4);
    await db.setSyncBaseline(
        sanitizeTtuFilename('Local newer'), 'progress', 100);
    // 远端更新（本地 == base）→ 自动下载。
    final EpubBookRow remoteNewer = await _seedBook(db, 'Remote newer');
    await _seedPosition(db, remoteNewer.uid, updatedAt: 100, fraction: 0.3);
    await db.setSyncBaseline(
        sanitizeTtuFilename('Remote newer'), 'progress', 100);

    final _FakeBackend fake = _FakeBackend(<String, _RemoteBook>{
      'Conflict A':
          const _RemoteBook(folderId: 'fa', timestampMs: 130, fraction: 0.7),
      'Conflict B':
          const _RemoteBook(folderId: 'fb', timestampMs: 130, fraction: 0.2),
      'Local newer':
          const _RemoteBook(folderId: 'fl', timestampMs: 100, fraction: 0.3),
      'Remote newer':
          const _RemoteBook(folderId: 'fr', timestampMs: 120, fraction: 0.5),
      'Remote only': const _RemoteBook(folderId: 'fo'),
    });

    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(useMaterial3: true),
          home: Scaffold(
            body: SyncCompareDialog(db: db, backend: fake),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('golden_files/sync_compare_dialog_wide.png'),
    );
  }, tags: <String>['golden']);
}
