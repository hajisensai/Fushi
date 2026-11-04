// BUG（srs-store-same-uid-retired）：收段途中副本被作废（SrsDbStore.retire：切配置 / 重开），在跑的一轮在下一片
// 明确失败（SrsStoreRetiredError）；作废那段独占区里先把收段会话放掉（内核 `ingest_end`），这一轮 finally 里的
// sync2IngestEnd 不再进独占区抛错。之后同一 uid 的新副本上，内核没有残留会话（回到空闲），下一轮把剩下的段收完、
// 收尾补齐，结果与一次收完的设备相同。全程真实 srs.db + Rust 内核。
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:fushi_engine/srs/sync2/srs_sync2_round.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import '../support/srs_test_storage.dart';

const String kProfile = '01928c3e-0000-7000-8000-0000000000ee';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  Future<SrsDbStore> openOn(SrsStorage st, String deviceId) => SrsDbStore.open(
    db: st.db,
    core: st.core,
    profileUid: kProfile,
    deviceId: deviceId,
    engine: FfiFsrsEngine.tryCreate(),
  );

  Future<SrsSync2Report> round(SrsSync2Host s, SrsLocationStore loc) =>
      srsSync2Round(
        host: s,
        location: loc,
        locationId: 'loc',
        nowMs: () => DateTime.now().millisecondsSinceEpoch,
      );

  List<String> events(List<SrsEvent> es) =>
      <String>[for (final SrsEvent e in es) jsonEncode(e.toJson())]..sort();

  test('收段途中作废：这一轮明确失败、会话已放掉；同 uid 新副本内核空闲，下一轮收完与一次收完相同', () async {
    // A 写 40 条笔记各答一次，同步到位置上：一批几百个操作，按每片 1 条投就是几百片。
    final SrsMemoryLocationStore loc = SrsMemoryLocationStore();
    final SrsDbStore a = await openOn(await openTestSrsStorage(), 'A');
    for (int i = 0; i < 40; i++) {
      final String n = await a.createNote(
        noteTypeId: a.lapisNoteTypeId,
        fieldsById: <String, String>{
          srsLapisFieldId(kProfile, 'Expression'): '語$i',
        },
      );
      await a.answer((await a.cardsOfNote(n)).first.id, 3);
    }
    expect((await round(a, loc)).error, isNull);
    SrsMemoryLocationStore copy() =>
        SrsMemoryLocationStore()..files.addAll(loc.files);

    // 对照：一次收完的设备。
    final SrsDbStore whole = await openOn(await openTestSrsStorage(), 'W');
    expect((await round(whole, copy())).error, isNull);

    final SrsStorage st = await openTestSrsStorage();
    final SrsDbStore b = await openOn(st, 'B');
    final SrsMemoryLocationStore bLoc = copy();
    int slices = 0;
    Future<SrsDbStore>? retiring;
    b.debugOnIngestSlice = () {
      if (++slices != 3 || retiring != null) return;
      // 钩子在独占区里：从根 zone 发起，才是真的去排队（与切配置时 activate 的交接同形）。
      retiring = Zone.root.run(
        () => b.retire(() => openOn(st, 'B'), reason: 'test handover'),
      );
    };
    final _SlicingHost host = _SlicingHost(b, sliceOps: 1);
    await expectLater(round(host, bLoc), throwsA(isA<SrsStoreRetiredError>()));
    final SrsDbStore b2 = await retiring!;
    expect(b.isUsable, isFalse);
    expect(b.isWindingDown, isTrue);
    expect(b.debugIngestOpen, isFalse, reason: '作废时已放掉会话');
    // 会话已放掉：内核里这个 profile 没有收段会话（泄漏的话这里会把旧会话收尾）。
    await expectLater(
      b2.sync2IngestFinish(),
      throwsA(
        predicate<Object>((Object e) => '$e'.contains('no ingest session')),
      ),
    );

    // 新副本接着同步：剩下的段收完、被打断那批的收尾补齐。
    final SrsSync2Report r = await round(b2, bLoc);
    expect(r.error, isNull);
    expect(b2.debugIngestOpen, isFalse);
    expect(events(await b2.exportAll()), events(await whole.exportAll()));
  });
}

/// 收段时给 [SrsDbStore.sync2IngestBatch] 带上切片参数的 host 包装。
class _SlicingHost implements SrsSync2Host {
  _SlicingHost(this.inner, {this.sliceOps});

  final SrsDbStore inner;
  final int? sliceOps;

  @override
  String get profileUid => inner.profileUid;

  @override
  Future<SrsSync2Result> sync2Command(
    Map<String, Object?> request, {
    List<Uint8List> blobs = const <Uint8List>[],
  }) => inner.sync2Command(request, blobs: blobs);

  @override
  Future<void> sync2IngestBegin() => inner.sync2IngestBegin();

  @override
  Future<Map<String, Object?>> sync2IngestBatch(
    List<Uint8List> segments, {
    String? keyHex,
  }) => inner.sync2IngestBatch(segments, keyHex: keyHex, sliceOps: sliceOps);

  @override
  Future<Map<String, Object?>> sync2IngestFinish() => inner.sync2IngestFinish();

  @override
  Future<void> sync2IngestEnd() => inner.sync2IngestEnd();
}
