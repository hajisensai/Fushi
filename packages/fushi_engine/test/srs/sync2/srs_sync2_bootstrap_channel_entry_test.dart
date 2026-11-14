// BUG-4478：新设备收段通道（native/fushi_fsrs/src/store/sync2/channel.rs，先追加后折叠）在真实新设备上要能被
// **自然**选中。`SrsDbStore.open` 在任何同步之前就写下内置身份记录（默认牌组 + 两个内置笔记类型，`ensureBuiltins`），
// 以前的判据要求操作日志与投影全空，所以生产里通道一次都没开过；别的通道测试要么用不带内置实体的裸内核库
// （Rust `tests_channel.rs` 的裸起点），要么手工往 `sync2_boot` 插行（srs_sync2_channel_settle_test.dart）。
//
// 这里两台设备都用真实 `SrsDbStore.open`：A 有数据（改过内置牌组与内置笔记类型、删过笔记）并已同步，B 是新装的。
// 断言 B 第一次同步时 `ingest_begin` 回报走通道、收段途中 `sync2_boot*` 里有行、收尾后通道表清空，且 B 与 A 收敛
// （摘要相同、投影三张表逐行相同）。通道与逐条投递逐表相同由 Rust 侧 `tests_channel.rs` 对拍。
import 'dart:typed_data';

import 'package:drift/drift.dart' show QueryRow, Variable, driftRuntimeOptions;
import 'package:fushi_core/fushi_core.dart' show srsIdType;
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:fushi_engine/srs/sync2/srs_sync2_round.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import '../support/srs_test_storage.dart';

const String kProfile = '01928c3e-0000-7000-8000-0000000000b7';

typedef _Device = ({SrsDbStore store, SrsStorage storage});

Future<int> _count(SrsStorage st, String table) async {
  final QueryRow r = await st.db
      .customSelect(
        'SELECT COUNT(*) AS c FROM $table WHERE profile_uid = ?',
        variables: <Variable<Object>>[Variable<String>(kProfile, srsIdType)],
      )
      .getSingle();
  return r.read<int>('c');
}

/// 投影三张表（身份记录、修改记录、复习日志）逐行，排好序。
Future<List<String>> _projection(SrsStorage st) async {
  final List<String> out = <String>[];
  for (final (String table, String body) in <(String, String)>[
    ('srs_entities', "kind || '|' || payload_json"),
    ('srs_field_edits', 'json'),
    ('srs_review_logs', 'json'),
  ]) {
    final List<QueryRow> rows = await st.db
        .customSelect(
          'SELECT srs_idt(id) AS id, $body AS body FROM $table '
          'WHERE profile_uid = ? ORDER BY id',
          variables: <Variable<Object>>[Variable<String>(kProfile, srsIdType)],
        )
        .get();
    for (final QueryRow r in rows) {
      out.add('$table ${r.read<String>('id')} ${r.read<String>('body')}');
    }
  }
  return out;
}

/// 把一轮同步对内核的收段调用原样转给 [inner]，顺手记下通道的状态。
class _ProbeHost implements SrsSync2Host {
  _ProbeHost(this.inner, this.storage);

  final SrsDbStore inner;
  final SrsStorage storage;

  /// 每次 `ingest_begin` 之后：内核是否回报这个会话走通道。
  final List<bool> channelAtBegin = <bool>[];

  /// 每批收完之后 `sync2_boot_order`（通道追加阶段记下的投递顺序）的行数。
  final List<int> orderRowsAfterBatch = <int>[];

  /// 每批收完之后投影里的修改记录数（通道追加阶段不投影）。
  final List<int> fieldEditsAfterBatch = <int>[];

  @override
  String get profileUid => inner.profileUid;

  @override
  Future<SrsSync2Result> sync2Command(
    Map<String, Object?> request, {
    List<Uint8List> blobs = const <Uint8List>[],
  }) => inner.sync2Command(request, blobs: blobs);

  @override
  Future<void> sync2IngestBegin() async {
    await inner.sync2IngestBegin();
    channelAtBegin.add(inner.debugChannelLive);
  }

  @override
  Future<Map<String, Object?>> sync2IngestBatch(
    List<Uint8List> segments, {
    String? keyHex,
  }) async {
    final Map<String, Object?> r = await inner.sync2IngestBatch(
      segments,
      keyHex: keyHex,
    );
    orderRowsAfterBatch.add(await _count(storage, 'sync2_boot_order'));
    fieldEditsAfterBatch.add(await _count(storage, 'srs_field_edits'));
    return r;
  }

  @override
  Future<Map<String, Object?>> sync2IngestFinish() => inner.sync2IngestFinish();

  @override
  Future<void> sync2IngestEnd() => inner.sync2IngestEnd();
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  Future<_Device> device(String id) async {
    final SrsStorage st = await openTestSrsStorage();
    final SrsDbStore s = await SrsDbStore.open(
      db: st.db,
      core: st.core,
      profileUid: kProfile,
      deviceId: id,
      engine: FfiFsrsEngine.tryCreate(),
    );
    return (store: s, storage: st);
  }

  Future<String> addNote(SrsDbStore s, String expression) => s.createNote(
    noteTypeId: s.lapisNoteTypeId,
    fieldsById: <String, String>{
      srsLapisFieldId(kProfile, 'Expression'): expression,
    },
  );

  Future<SrsSync2Report> round(SrsSync2Host host, SrsLocationStore loc) =>
      srsSync2Round(
        host: host,
        location: loc,
        locationId: 'loc',
        nowMs: () => DateTime.now().millisecondsSinceEpoch,
      );

  /// A：用户数据，外加对内置实体的改动（默认牌组改名、内置笔记类型改名）与一次删除。
  Future<List<String>> populate(SrsDbStore a) async {
    final List<String> notes = <String>[
      for (int i = 0; i < 24; i++) await addNote(a, '語$i'),
    ];
    for (final String n in notes.take(16)) {
      await a.answer((await a.cardsOfNote(n)).first.id, 3);
    }
    await a.editField(
      SrsEntityKind.deck,
      a.defaultDeckId,
      SrsFieldKeys.name,
      'Mine',
    );
    await a.editField(
      SrsEntityKind.noteType,
      a.lapisNoteTypeId,
      SrsFieldKeys.name,
      'My Lapis',
    );
    await a.deleteNote(notes.last);
    return notes;
  }

  test('真实新设备（开库已写内置实体）第一次同步：走收段通道，收敛后与 A 一致', () async {
    final SrsLocationStore loc = SrsMemoryLocationStore();
    final _Device a = await device('A');
    final List<String> notes = await populate(a.store);
    expect((await round(a.store, loc)).error, isNull);

    final _Device b = await device('B');
    // 真实新设备在第一次同步之前：操作日志里是开库时写的三条内置身份记录，投影里是它们的三行。
    expect(await _count(b.storage, 'sync2_ops'), 3);
    expect(await _count(b.storage, 'srs_entities'), 3);
    expect(await _count(b.storage, 'srs_field_edits'), 0);
    expect(await _count(b.storage, 'srs_review_logs'), 0);
    expect(b.store.debugChannelLive, isFalse);

    final _ProbeHost probe = _ProbeHost(b.store, b.storage);
    final SrsSync2Report r = await round(probe, loc);
    expect(r.error, isNull);
    expect(r.applied, greaterThan(50));
    expect(
      probe.channelAtBegin,
      isNotEmpty,
      reason: 'the round opened an ingest session',
    );
    expect(
      probe.channelAtBegin.first,
      isTrue,
      reason: 'ingest_begin put the first sync of a new device on the channel',
    );
    expect(
      probe.orderRowsAfterBatch.first,
      greaterThan(50),
      reason: 'the batch was appended to the channel, not projected',
    );
    expect(
      probe.fieldEditsAfterBatch.first,
      0,
      reason: 'nothing is projected before the channel folds',
    );
    // 收尾后通道做完，五张通道表清空。
    for (final String t in <String>[
      'sync2_boot',
      'sync2_boot_order',
      'sync2_boot_complex',
      'sync2_boot_moves',
      'sync2_boot_rows',
    ]) {
      expect(await _count(b.storage, t), 0, reason: t);
    }

    // B 看到 A 的数据，包括 A 对内置实体的改动与删除。
    expect(await b.store.note(notes.first), isNotNull);
    expect((await b.store.deckTree())[b.store.defaultDeckId]?.name, 'Mine');
    expect((await b.store.noteType(b.store.lapisNoteTypeId))?.name, 'My Lapis');
    expect(
      (await b.store.note(notes.last))?.deletedAt,
      (await a.store.note(notes.last))?.deletedAt,
    );
    final String card = (await a.store.cardsOfNote(notes.first)).first.id;
    expect(
      srsCanonicalJson((await b.store.history(card)).state.toJson()),
      srsCanonicalJson((await a.store.history(card)).state.toJson()),
    );

    // A 收下 B 的三条内置身份记录（与自己的同 ID 同内容）之后，两边摘要相同、投影逐行相同。
    expect((await round(a.store, loc)).error, isNull);
    expect((await round(b.store, loc)).error, isNull);
    expect(await _projection(b.storage), await _projection(a.storage));
    expect(
      (await b.store.sync2Digest())['digest'],
      (await a.store.sync2Digest())['digest'],
    );
    expect((await b.store.sync2Status())['pending'], 0);

    // 通道做完之后本机照常写、照常同步。
    final String mine = await addNote(b.store, '後');
    expect(b.store.debugChannelLive, isFalse);
    expect((await round(b.store, loc)).error, isNull);
    expect((await round(a.store, loc)).error, isNull);
    expect(await a.store.note(mine), isNotNull);
    expect(
      (await b.store.sync2Digest())['digest'],
      (await a.store.sync2Digest())['digest'],
    );
  });

  test('已经有自己数据的设备（改过内置牌组的名字）：照常逐条投递', () async {
    final SrsLocationStore loc = SrsMemoryLocationStore();
    final _Device a = await device('A');
    await populate(a.store);
    expect((await round(a.store, loc)).error, isNull);

    final _Device b = await device('B');
    await b.store.editField(
      SrsEntityKind.deck,
      b.store.defaultDeckId,
      SrsFieldKeys.name,
      'Renamed here',
    );
    final _ProbeHost probe = _ProbeHost(b.store, b.storage);
    expect((await round(probe, loc)).error, isNull);
    expect(probe.channelAtBegin, <bool>[false]);
    expect(probe.orderRowsAfterBatch.first, 0);
    expect(probe.fieldEditsAfterBatch.first, greaterThan(0));
  });

  test('自然开的通道在追加途中遇到本机写入：先按片做完，再写', () async {
    final SrsMemoryLocationStore loc = SrsMemoryLocationStore();
    final _Device a = await device('A');
    final List<String> notes = await populate(a.store);
    expect((await round(a.store, loc)).error, isNull);
    final List<Uint8List> segments = <Uint8List>[
      for (final MapEntry<String, Uint8List> f in loc.files.entries)
        if (f.key.contains('/seg-')) f.value,
    ];
    final List<Uint8List> heads = <Uint8List>[
      for (final MapEntry<String, Uint8List> f in loc.files.entries)
        if (f.key.contains('/head-')) f.value,
    ];
    expect(segments, isNotEmpty);
    expect(heads, isNotEmpty);

    final _Device b = await device('B');
    await b.store.sync2Command(<String, Object?>{'op': 'plan'}, blobs: heads);
    await b.store.sync2IngestBegin();
    expect(b.store.debugChannelLive, isTrue);
    await b.store.sync2IngestBatch(segments);
    expect(await _count(b.storage, 'sync2_boot_order'), greaterThan(50));
    expect(await b.store.note(notes.first), isNull);

    // App 没等收尾：会话放掉，用户制了一张卡。
    await b.store.sync2IngestEnd();
    final String mine = await addNote(b.store, '中');
    expect(b.store.debugChannelLive, isFalse);
    expect(await _count(b.storage, 'sync2_boot'), 0);
    expect(await b.store.note(notes.first), isNotNull);
    expect(await b.store.note(mine), isNotNull);

    // 之后的同步逐条投递，照样收敛。
    final _ProbeHost probe = _ProbeHost(b.store, b.storage);
    expect((await round(probe, loc)).error, isNull);
    expect(probe.channelAtBegin, everyElement(isFalse));
    expect((await round(a.store, loc)).error, isNull);
    expect((await round(b.store, loc)).error, isNull);
    expect(await _projection(b.storage), await _projection(a.storage));
    expect(
      (await b.store.sync2Digest())['digest'],
      (await a.store.sync2Digest())['digest'],
    );
  });
}
