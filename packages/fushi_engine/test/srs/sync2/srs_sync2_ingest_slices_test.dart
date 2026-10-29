// 收段按片投递（SrsDbStore.sync2IngestBatch ↔ 内核 `ingest_commit` 的 `CommitBudget`）：一批分成很多片投，
// 结果与一片投完相同；写锁被一片占着时来排队的写入请内核当场收片，不等这一片投完。
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

const String kProfile = '01928c3e-0000-7000-8000-0000000000ed';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  Future<SrsDbStore> device(String id) async {
    final SrsStorage st = await openTestSrsStorage();
    return SrsDbStore.open(
      db: st.db,
      core: st.core,
      profileUid: kProfile,
      deviceId: id,
      engine: FfiFsrsEngine.tryCreate(),
    );
  }

  Future<String> addNote(SrsDbStore s, String expression) => s.createNote(
    noteTypeId: s.lapisNoteTypeId,
    fieldsById: <String, String>{
      srsLapisFieldId(kProfile, 'Expression'): expression,
    },
  );

  Future<SrsSync2Report> round(SrsSync2Host s, SrsLocationStore loc) =>
      srsSync2Round(
        host: s,
        location: loc,
        locationId: 'loc',
        nowMs: () => DateTime.now().millisecondsSinceEpoch,
      );

  /// A 写 [notes] 条笔记、各答一次，同步到位置上：一批里有几百个操作（远超一片的保底条数）。
  Future<SrsMemoryLocationStore> seeded(int notes) async {
    final SrsMemoryLocationStore loc = SrsMemoryLocationStore();
    final SrsDbStore a = await device('A');
    for (int i = 0; i < notes; i++) {
      final String n = await addNote(a, '語$i');
      await a.answer((await a.cardsOfNote(n)).first.id, 3);
    }
    expect((await round(a, loc)).error, isNull);
    return loc;
  }

  /// 位置的一份副本（各设备同步完会把自己的段写回位置，对照的两台设备各收一份同样的输入）。
  SrsMemoryLocationStore copy(SrsMemoryLocationStore loc) =>
      SrsMemoryLocationStore()..files.addAll(loc.files);

  List<String> events(List<SrsEvent> es) =>
      <String>[for (final SrsEvent e in es) jsonEncode(e.toJson())]..sort();

  test('每片只投一条：汇报与落库的结果都与一片投完相同', () async {
    final SrsMemoryLocationStore loc = await seeded(40);
    final SrsDbStore whole = await device('B1');
    final _SlicingHost sliced = _SlicingHost(await device('B2'), sliceOps: 1);
    final SrsSync2Report rw = await round(whole, copy(loc));
    final SrsSync2Report rs = await round(sliced, copy(loc));
    expect(rw.error, isNull);
    expect(rs.error, isNull);
    expect(rs.applied, rw.applied);
    expect(rs.applied, greaterThan(100));
    expect(rs.pending, rw.pending);
    expect(rs.errors, rw.errors);
    expect(rs.changed, rw.changed);
    final int slices = sliced.results.fold(
      0,
      (int n, Map<String, Object?> r) => n + (r['slices']! as int),
    );
    expect(slices, greaterThanOrEqualTo(rs.applied));
    expect(
      events(await sliced.inner.exportAll()),
      events(await whole.exportAll()),
    );
  });

  test('一片占着写锁时来排队的作答：内核当场收片，作答插在两片之间', () async {
    final SrsMemoryLocationStore loc = await seeded(40);
    final SrsDbStore b = await device('B');
    final String own = await addNote(b, '自分');
    final String card = (await b.cardsOfNote(own)).first.id;
    // 时间上限给得很长：没有让出请求就是一片投完。
    final _SlicingHost host = _SlicingHost(b, sliceMs: 600000);
    final List<String> order = <String>[];
    Future<void>? answered;
    b.debugOnIngestSlice = () {
      if (answered != null) return;
      // 钩子在独占区里：从根 zone 发起，才是真的去排队（独占区内的调用按可重入直接执行）。
      answered = Zone.root.run(
        () => b.answer(card, 3).then((_) => order.add('answer')),
      );
    };
    host.onBatch = () => order.add('batch');
    final SrsSync2Report r = await round(host, loc);
    await answered;
    expect(r.error, isNull);
    expect(host.results.single['slices'], greaterThanOrEqualTo(2));
    expect(order, <String>['answer', 'batch']);
  });
}

/// 收段时给 [SrsDbStore.sync2IngestBatch] 带上切片参数的 host 包装，记下每批的结果。
class _SlicingHost implements SrsSync2Host {
  _SlicingHost(this.inner, {this.sliceOps, this.sliceMs});

  final SrsDbStore inner;
  final int? sliceOps;
  final int? sliceMs;
  final List<Map<String, Object?>> results = <Map<String, Object?>>[];
  void Function()? onBatch;

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
  }) async {
    final Map<String, Object?> r = await inner.sync2IngestBatch(
      segments,
      keyHex: keyHex,
      sliceOps: sliceOps,
      sliceMs: sliceMs,
    );
    results.add(r);
    onBatch?.call();
    return r;
  }

  @override
  Future<Map<String, Object?>> sync2IngestFinish() => inner.sync2IngestFinish();
}
