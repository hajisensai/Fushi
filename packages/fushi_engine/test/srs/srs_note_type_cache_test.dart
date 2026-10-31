// 笔记类型物化缓存（SrsDbStore._noteTypeCache）：同一内容版本下 noteType / noteTypes 不再读库；任何笔记类型
// 结构写入（本机改名 / 加字段 / 新建 / 删除、同步收来的修改）之后立刻读到新值；复习作答不让缓存失效。
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_note_type_store.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:fushi_engine/srs/sync2/srs_sync2_round.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'apkg/apkg_test_support.dart' show FakeFsrsEngine;
import 'support/srs_query_counter.dart';
import 'support/srs_test_storage.dart';

const String kNtProfile = '01928c3e-0000-7000-8000-0000000000e1';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  int t = DateTime.utc(2026, 10, 28, 12).millisecondsSinceEpoch;

  setUp(() {
    t = DateTime.utc(2026, 10, 28, 12).millisecondsSinceEpoch;
  });

  SrsTrustedClock clock(String id) =>
      SrsTrustedClock(wallClockMs: () => t, bootId: 'boot-$id');

  Future<(SrsDbStore, CountingInterceptor)> counted(String id) async {
    final CountingInterceptor counter = CountingInterceptor();
    final Directory tmp = Directory.systemTemp.createTempSync('srs_ntc_');
    addTearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } on FileSystemException {
        // 句柄晚释放。
      }
    });
    final TestSrs srs = await openTestSrsAt(
      '${tmp.path}/$kSrsDatabaseFileName',
      interceptor: counter,
    );
    final SrsDbStore s = await SrsDbStore.open(
      db: srs.db,
      core: srs.core,
      profileUid: kNtProfile,
      deviceId: id,
      engine: const FakeFsrsEngine(),
      trustedClock: clock(id),
      fallbackRolloverHour: () => 4,
    );
    return (s, counter);
  }

  Future<SrsDbStore> plain(String id) async {
    final SrsStorage storage = await openTestSrsStorage();
    return SrsDbStore.open(
      db: storage.db,
      core: storage.core,
      profileUid: kNtProfile,
      deviceId: id,
      engine: const FakeFsrsEngine(),
      trustedClock: clock(id),
      fallbackRolloverHour: () => 4,
    );
  }

  List<String> names(List<SrsNoteTypeView> ts) => <String>[
    for (final SrsNoteTypeView v in ts) v.name,
  ];

  List<String> fieldNames(SrsNoteTypeView v) => <String>[
    for (final SrsFieldDef f in v.fields) f.name,
  ];

  test('同一内容版本下重复读不碰库；作答不失效；本机结构写入后立刻读到新值', () async {
    final (SrsDbStore s, CountingInterceptor counter) = await counted('a');
    final String lapis = s.lapisNoteTypeId;
    final SrsNoteTypeView first = (await s.noteType(lapis))!;
    final List<SrsNoteTypeView> all = await s.noteTypes();

    counter.reset();
    expect(identical(await s.noteType(lapis), first), isTrue);
    expect(names(await s.noteTypes()), names(all));
    expect(await s.noteType('no-such-type'), isNull);
    final int afterMiss = counter.count('select');
    expect(await s.noteType('no-such-type'), isNull);
    expect(
      counter.count('select'),
      afterMiss,
      reason: 'a cached miss read the store again: ${counter.summary()}',
    );
    counter.reset();
    expect(await s.noteType(lapis), same(first));
    await s.noteTypes();
    expect(counter.count('select'), 0, reason: counter.summary());

    // 复习作答（只落日志）不推进内容修订号：缓存照旧命中。
    t += 1000;
    final String note = await s.createNote(
      noteTypeId: lapis,
      fieldsById: <String, String>{
        srsLapisFieldId(kNtProfile, 'Expression'): '雪',
      },
    );
    final String card = (await s.cardsOfNote(note)).single.id;
    expect(await s.noteType(lapis), isNot(same(first)), reason: '建笔记是内容写入');
    final SrsNoteTypeView afterNote = (await s.noteType(lapis))!;
    await s.noteTypes();
    t += 1000;
    await s.answer(card, 3);
    counter.reset();
    expect(await s.noteType(lapis), same(afterNote));
    await s.noteTypes();
    expect(counter.count('select'), 0, reason: counter.summary());

    // 改字段名：noteType / noteTypes 立刻是新值。
    final String expr = srsLapisFieldId(kNtProfile, 'Expression');
    await s.renameField(lapis, expr, '表記');
    expect(fieldNames((await s.noteType(lapis))!), contains('表記'));
    expect(
      fieldNames(
        (await s.noteTypes()).singleWhere((SrsNoteTypeView v) => v.id == lapis),
      ),
      contains('表記'),
    );

    // 新建 / 加字段 / 删除。
    final String custom = await s.createStockNoteType(
      SrsStockNoteType.basic,
      'Custom',
    );
    expect(names(await s.noteTypes()), contains('Custom'));
    await s.addField(custom, 'Extra');
    expect(fieldNames((await s.noteType(custom))!), contains('Extra'));
    await s.deleteNoteType(custom);
    expect(names(await s.noteTypes()), isNot(contains('Custom')));
    expect((await s.noteType(custom))!.deletedAt, isNotNull);
  });

  test('同步收来的笔记类型修改立刻可见', () async {
    final SrsMemoryLocationStore loc = SrsMemoryLocationStore();
    final (SrsDbStore a, CountingInterceptor _) = await counted('a');
    final SrsDbStore b = await plain('b');
    Future<void> sync() async {
      for (int round = 0; round < 3; round++) {
        for (final SrsDbStore s in <SrsDbStore>[a, b]) {
          await srsSync2Round(
            host: s,
            location: loc,
            locationId: 'test',
            nowMs: () => t,
          );
        }
      }
    }

    await sync();
    final String lapis = a.lapisNoteTypeId;
    final String expr = srsLapisFieldId(kNtProfile, 'Expression');
    expect(fieldNames((await a.noteType(lapis))!), isNot(contains('単語')));
    expect(await a.noteTypes(), isNotEmpty);
    t += 1000;
    await b.renameField(lapis, expr, '単語');
    final String custom = await b.createStockNoteType(
      SrsStockNoteType.basic,
      'FromB',
    );
    await sync();
    expect(fieldNames((await a.noteType(lapis))!), contains('単語'));
    expect(names(await a.noteTypes()), contains('FromB'));
    expect((await a.noteType(custom))!.name, 'FromB');
  });
}
