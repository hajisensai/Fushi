// 新设备收段通道（native/fushi_fsrs/src/store/sync2/channel.rs）没做完时来的命令：内核的分发器在要完整投影的命令之前
// 先按片把通道做完（每片一个事务）。那些片没有自己的回包，落进投影的变化由内核攒着、随这个 profile 的下一条命令的
// 回包交回（`settled`），SrsDbStore 接进内容 / 视图 / 分数表的刷新信号（srs_db_store.dart `_absorbSettled`）。
// 修复前这些变化从不到 Dart：按 `deckTreeKey` / `contentFingerprint` / `rwkvScoresKey` 记的缓存不失效。
//
// 场景：新设备第一次同步收尾做到一半时 App 被杀；重开后副本照常打开（通道还开着，由 `identity` 回报），之后来一条
// 要完整投影的只读命令（`digest`）。全程真实 srs.db + Rust 内核；通道那一段直接对内核发收段命令（通道只在
// 这个 profile 的操作日志与投影都还是空的时候开）。
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:fushi_engine/srs/sync2/srs_sync2_round.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/srs_test_storage.dart';

const String kProfile = '01928c3e-0000-7000-8000-0000000000ee';

int _now() => DateTime.now().millisecondsSinceEpoch;

/// 收尾做到一半「App 被杀」。
final class _KilledMidFinish implements Exception {
  const _KilledMidFinish();
}

/// 直接对内核发命令的同步 host（还没有 [SrsDbStore]：新设备第一次同步时投影是空的，通道才开）。收尾一片一片做，
/// 做到 [killAt] 为真就抛 [_KilledMidFinish]。
final class _CoreHost implements SrsSync2Host {
  _CoreHost(this.core, this.killAt);

  final SrsCore core;
  final bool Function() killAt;

  @override
  String get profileUid => kProfile;

  Map<String, Object?> _cmd(
    Map<String, Object?> request, [
    List<Uint8List> blobs = const <Uint8List>[],
  ]) => core.sync2(<String, Object?>{
    ...request,
    'profile': kProfile,
  }, blobs: blobs).map;

  @override
  Future<SrsSync2Result> sync2Command(
    Map<String, Object?> request, {
    List<Uint8List> blobs = const <Uint8List>[],
  }) async => core.sync2(<String, Object?>{
    ...request,
    'profile': kProfile,
  }, blobs: blobs);

  @override
  Future<void> sync2IngestBegin() async {
    _cmd(const <String, Object?>{'op': 'ingest_begin'});
  }

  @override
  Future<Map<String, Object?>> sync2IngestBatch(
    List<Uint8List> segments, {
    String? keyHex,
  }) async {
    _cmd(<String, Object?>{'op': 'ingest_prepare', 'key': keyHex}, segments);
    Map<String, Object?> r;
    do {
      r = _cmd(<String, Object?>{'op': 'ingest_commit', 'now': _now()});
    } while (r['more'] == true);
    return r;
  }

  @override
  Future<Map<String, Object?>> sync2IngestFinish() async {
    Map<String, Object?> r = _cmd(<String, Object?>{
      'op': 'ingest_finish',
      'now': _now(),
      'sliceOps': 1,
    });
    while (r['more'] == true && !killAt()) {
      r = _cmd(<String, Object?>{
        'op': 'replay_pending',
        'now': _now(),
        'sliceOps': 1,
      });
    }
    if (r['more'] != true) {
      throw StateError('the finish ran to its end before the kill point');
    }
    throw const _KilledMidFinish();
  }

  @override
  Future<void> sync2IngestEnd() async {
    _cmd(const <String, Object?>{'op': 'ingest_end'});
  }
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  Future<SrsDbStore> openOn(SrsStorage st, String deviceId) => SrsDbStore.open(
    db: st.db,
    core: st.core,
    profileUid: kProfile,
    deviceId: deviceId,
    engine: FfiFsrsEngine.tryCreate(),
  );

  Future<bool> channelInCore(SrsDbStore s) async =>
      (await s.sync2Command(<String, Object?>{
        'op': 'identity',
        'now': _now(),
      })).map['channel'] ==
      true;

  test('通道在一条命令之前自己做完的片：内容 / 视图 / 分数表的刷新信号跟着推进', () async {
    // A：一个牌组、几条带标签的笔记各答一次、删掉一条、打一个检查点，同步到位置上。标签、删除、检查点在通道里
    // 走「逐条」那一段（归并之后），收尾做到一半时它们还没落进投影。
    final SrsMemoryLocationStore loc = SrsMemoryLocationStore();
    final SrsDbStore a = await openOn(await openTestSrsStorage(), 'A');
    final String deck = await a.createDeck('通道');
    final List<String> notes = <String>[];
    for (int i = 0; i < 6; i++) {
      final String n = await a.createNote(
        noteTypeId: a.lapisNoteTypeId,
        deckId: deck,
        tags: <String>['tag$i'],
        fieldsById: <String, String>{
          srsLapisFieldId(kProfile, 'Expression'): '語$i',
        },
      );
      notes.add(n);
      await a.answer((await a.cardsOfNote(n)).first.id, 3);
    }
    await a.deleteNote(notes.last);
    await a.sync2Checkpoint('cp', 'manual');
    expect(
      (await srsSync2Round(
        host: a,
        location: loc,
        locationId: 'loc',
        nowMs: _now,
      )).error,
      isNull,
    );

    // B：新设备，收段走通道；收尾做到内置实体已归并进投影时被杀。
    final Directory dir = Directory.systemTemp.createTempSync('srs_channel_');
    addTearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } on FileSystemException {
        // 句柄晚释放。
      }
    });
    final String path = p.join(dir.path, kSrsDatabaseFileName);
    {
      final SrsCore core = SrsCore.open(path);
      bool builtinsLanded() => srsBuiltinEntities(kProfile).every(
        (SrsEntityRecord r) => core.debugQuery(
          'SELECT 1 AS x FROM srs_entities WHERE id = srs_id(?)',
          <Object?>[r.id],
        ).isNotEmpty,
      );
      try {
        core.sync2(<String, Object?>{
          'op': 'identity',
          'profile': kProfile,
          'now': _now(),
        });
        await expectLater(
          srsSync2Round(
            host: _CoreHost(core, builtinsLanded),
            location: loc,
            locationId: 'loc',
            nowMs: _now,
          ),
          throwsA(isA<_KilledMidFinish>()),
        );
        expect(builtinsLanded(), isTrue);
      } finally {
        core.close();
      }
    }

    // 重开：内置实体都在（不补写），迁移推迟（app 打开时同样推迟到首次同步确认之后）——打开不碰通道。
    final TestSrs t = await openTestSrsAt(path);
    final SrsDbStore b = await SrsDbStore.open(
      db: t.db,
      core: t.core,
      profileUid: kProfile,
      deviceId: 'B',
      engine: FfiFsrsEngine.tryCreate(),
      deferMigration: true,
    );
    expect(await channelInCore(b), isTrue, reason: '打开时通道还没做完');

    final String content = b.contentFingerprint;
    final String tree = b.deckTreeKey;
    final String rwkv = b.rwkvScoresKey;
    final String stats = b.statsFingerprint;
    final Object treeBefore = await b.deckTree();
    expect(identical(await b.deckTree(), treeBefore), isTrue, reason: '按键缓存');

    // 摘要要完整投影：分发器先把通道做完，再算。命令本身只读。
    await b.sync2Command(const <String, Object?>{'op': 'digest'});
    expect(await channelInCore(b), isFalse);

    expect(b.contentFingerprint, isNot(content), reason: '内容修订号没推进');
    expect(b.deckTreeKey, isNot(tree), reason: '牌组树的缓存键没变');
    expect(b.rwkvScoresKey, isNot(rwkv), reason: '分数表没有重新刷新');
    expect(b.statsFingerprint, isNot(stats), reason: '库修订号没跟上');
    expect(identical(await b.deckTree(), treeBefore), isFalse);
    // 只交一次：再来一条命令，信号不再动。
    final String content2 = b.contentFingerprint;
    final String rwkv2 = b.rwkvScoresKey;
    await b.sync2Command(const <String, Object?>{'op': 'digest'});
    expect(b.contentFingerprint, content2);
    expect(b.rwkvScoresKey, rwkv2);
  });
}
