// head 引用的段在位置上不见了（BUG：设备 01a173ca 的 head 引用了从没传上去的合并段，读者的待应用永久卡住）：作者
// 下一轮按读 head 时列到的本机目录自检（内核 transport.rs `sync2_audit_own`），把缺的段同名补传，读者照常收齐。
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

const String kProfile = '01928c3e-0000-7000-8000-0000000000e7';

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

  Future<SrsSync2Report> round(SrsDbStore s, SrsLocationStore loc) =>
      srsSync2Round(
        host: s,
        location: loc,
        locationId: 'loc',
        nowMs: () => DateTime.now().millisecondsSinceEpoch,
      );

  Future<String> deviceOf(SrsDbStore s) async =>
      (await s.sync2Command(<String, Object?>{
            'op': 'identity',
            'now': 0,
          })).map['device']!
          as String;

  /// [loc] 上 [dev] 代号最大的 head 引用的段文件（相对路径）。
  List<String> referenced(SrsMemoryLocationStore loc, String dev) {
    final List<String> heads =
        loc.files.keys
            .where((String k) => k.startsWith('devices/$dev/head-'))
            .toList()
          ..sort();
    final Map<String, Object?> head =
        jsonDecode(utf8.decode(loc.files[heads.last]!)) as Map<String, Object?>;
    String pad(Object? n) => '$n'.padLeft(12, '0');
    return <String>[
      for (final List<Object?> s
          in (head['segments']! as List<Object?>).cast<List<Object?>>())
        'devices/$dev/seg-${pad(s[0])}-${pad(s[1])}-${s[2]}.bin',
    ];
  }

  test('位置上缺了 head 引用的段：作者下一轮同名补传，读者收齐', () async {
    final SrsMemoryLocationStore loc = SrsMemoryLocationStore();
    final SrsDbStore a = await device('A');
    final SrsDbStore c = await device('C');
    final String first = await addNote(a, '雪');
    expect((await round(a, loc)).error, isNull);
    final String second = await addNote(a, '雨');
    expect((await round(a, loc)).error, isNull);

    final String dev = await deviceOf(a);
    final List<String> segs = referenced(loc, dev);
    final String lost = segs.last;
    final Uint8List bytes = loc.files.remove(lost)!;

    await round(c, loc);
    expect(
      await c.note(second),
      isNull,
      reason: 'the reader cannot get past the hole',
    );

    // 作者这一轮什么都没写：自检照样发现缺段、同名补传（字节相同：同一切法、同一签名）。
    expect((await round(a, loc)).error, isNull);
    expect(loc.files[lost], bytes);
    for (final String s in referenced(loc, dev)) {
      expect(loc.files.containsKey(s), isTrue, reason: s);
    }

    await round(c, loc);
    expect(await c.note(first), isNotNull);
    expect(await c.note(second), isNotNull);
    expect((await c.sync2Status())['pending'], 0);
  });
}
