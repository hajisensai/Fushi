/// HBK-AUDIT-022：本地音频库的删除墓碑按**内容身份**求交，不按显示名。
///
/// 同一份库在各端可以叫不同的名字（拍板 pr3481 之后同步按内容认库），旧实现的删除
/// 墓碑却发显示名：对端把内容 X 叫 `android.db` 并「从所有设备删除」，本机恰好有
/// 另一份内容 Y 也叫 `android.db`，删除确认就落到 Y 上，X 反而留下。
///
/// 这里跑真的 [SyncOrchestrator.syncDeletionTombstones]（云通道与互联通道共用同一份
/// 在库键收集），钉住：内容身份墓碑命中本机那份（不管它叫什么）；按显示名写的旧墓碑
/// 确认不了是哪份库，不进候选。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_orchestrator.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/models/local_audio_content_id.dart';
import 'package:fushi_engine/models/local_audio_db_entry.dart';
import 'package:fushi_engine/sync/deletion_propagation.dart';
import 'package:fushi_engine/sync/sync_asset_store.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'fake_asset_store.dart';

void _writeAudioDb(String path, List<int> audio) {
  final Database db = sqlite3.open(path);
  try {
    db.execute(
      'CREATE TABLE entries (expression TEXT, reading TEXT, file TEXT, '
      'source TEXT)',
    );
    db.execute('CREATE TABLE android (file TEXT, source TEXT, data BLOB)');
    db.execute('INSERT INTO entries VALUES (?, ?, ?, ?)', <Object?>[
      '猫',
      'ねこ',
      'neko.mp3',
      'nhk16',
    ]);
    db.execute('INSERT INTO android VALUES (?, ?, ?)', <Object?>[
      'neko.mp3',
      'nhk16',
      Uint8List.fromList(audio),
    ]);
  } finally {
    db.dispose();
  }
}

void main() {
  late FushiDatabase db;
  late FakeAssetStore store;
  late _Backend backend;
  late Directory tmp;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    store = FakeAssetStore();
    backend = _Backend(store);
    tmp = await Directory.systemTemp.createTemp('la_deletion_identity');
  });
  tearDown(() async {
    await db.close();
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  final String kind = SyncTombstoneKind.localaudio.dbValue;

  Future<void> putRemoteTombstone(String itemKey, int deletedAt) async {
    final String ns = await backend.ensureNamespace(kSyncTombstonesNamespace);
    await backend.putJsonAsset(
      ns,
      deletionTombstoneAssetName(kind, itemKey),
      deletionTombstoneJson(kind, itemKey, deletedAt),
    );
  }

  test('内容身份墓碑命中本机那份（名字不同也算）；同名的另一份库与按名旧墓碑都不进候选', () async {
    final String xPath = p.join(tmp.path, 'x.db');
    final String yPath = p.join(tmp.path, 'y.db');
    // 元数据完全相同，只有录音不同（HBK-AUDIT-001 的同一前提）。
    _writeAudioDb(xPath, <int>[1, 1, 1]);
    _writeAudioDb(yPath, <int>[2, 2, 2]);
    final String x = computeLocalAudioContentId(xPath)!;
    final String y = computeLocalAudioContentId(yPath)!;
    expect(x, isNot(y));

    // 对端把内容 X 叫 android.db 并删掉了它；本机 X 叫 Japanese audio，
    // 内容 Y 恰好叫 android.db。
    await putRemoteTombstone(x, 5000);
    await putRemoteTombstone('android.db', 5000); // 升级前按显示名写的旧墓碑

    final SyncOrchestrator orchestrator = SyncOrchestrator(
      db: db,
      backend: backend,
      dictionaryResourceRoot: tmp,
      audioDatabaseRoot: tmp,
      tempDir: tmp,
      syncStats: false,
      syncAudioBookPosition: false,
      syncContent: false,
      syncMangaContent: false,
      syncAudioBookFiles: false,
      syncDictionary: false,
      localAudioEntries: <LocalAudioDbEntry>[
        LocalAudioDbEntry(
          path: xPath,
          displayName: 'Japanese audio',
          contentId: x,
        ),
        // 旧登记没存身份：在库键现算，不退回显示名。
        LocalAudioDbEntry(path: yPath, displayName: 'android.db'),
      ],
    );
    final SyncRunReport report = SyncRunReport();
    await orchestrator.syncDeletionTombstones(report);

    expect(
      report.deletionCandidates
          .where((DeletionPropagationCandidate c) => c.mediaType == kind)
          .map((DeletionPropagationCandidate c) => c.itemKey)
          .toList(),
      <String>[x],
    );
  });
}

class _Backend implements SyncBackend {
  _Backend(this._store);
  final FakeAssetStore _store;

  @override
  Future<String> ensureNamespace(String name) => _store.ensureNamespace(name);
  @override
  Future<List<AssetEntry>> listChildren(String namespaceId) =>
      _store.listChildren(namespaceId);
  @override
  Future<Uint8List?> getBytesAsset(String assetId) =>
      _store.getBytesAsset(assetId);
  @override
  Future<void> putBytesAsset(
    String namespaceId,
    String name,
    Uint8List bytes,
  ) => _store.putBytesAsset(namespaceId, name, bytes);
  @override
  Future<Object?> getJsonAsset(String assetId) => _store.getJsonAsset(assetId);
  @override
  Future<void> putJsonAsset(String namespaceId, String name, Object? json) =>
      _store.putJsonAsset(namespaceId, name, json);
  @override
  Future<bool> get isAuthenticated async => true;
  @override
  Future<bool> restoreAuth(SyncRepository repo) async => true;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('_Backend.${invocation.memberName}');
}
