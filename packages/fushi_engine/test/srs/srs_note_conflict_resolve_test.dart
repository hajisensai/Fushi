// BUG-5551（反馈 mvf7Wfz8Q-）：同一份 Anki 数据在两台设备各导入一次，一台读到了媒体、把引用改写成内容寻址名，
// 一台没读到、保留原名 → 每条带媒体的笔记都成了「两台设备同时改了这个字段」。这类伪冲突自动消解；真冲突不动；
// 另有「整批采用某一台设备的版本」。
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_core/fushi_core.dart' show SrsNoteCacheRow;
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_media_store.dart';
import 'package:fushi_engine/srs/srs_note_conflict_resolve.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:fushi_engine/srs/sync2/srs_sync2_round.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'support/srs_fake_engine.dart';
import 'support/srs_test_storage.dart';

const String kProfile = '01928c3e-0000-7000-8000-000000000001';

void main() {
  int t = DateTime.utc(2026, 11, 26, 12).millisecondsSinceEpoch;
  late SrsMemoryLocationStore loc;
  late Directory tmp;

  Future<SrsDbStore> device(String id) async {
    final SrsStorage storage = await openTestSrsStorage();
    final SrsTrustedClock clock = SrsTrustedClock(
      wallClockMs: () => t,
      bootClockMs: () => t,
    );
    return SrsDbStore.open(
      core: storage.core,
      profileUid: kProfile,
      deviceId: id,
      engine: const SrsFakeEngine(),
      trustedClock: clock,
    );
  }

  Future<void> syncAll(List<SrsDbStore> stores) async {
    for (int round = 0; round < 3; round++) {
      for (final SrsDbStore s in stores) {
        await srsSync2Round(
          host: s,
          location: loc,
          locationId: 'test',
          nowMs: () => t,
        );
      }
    }
  }

  SrsMediaStore mediaOf(String device) =>
      SrsMediaStore(Directory('${tmp.path}/$device'));

  final String sentence = srsLapisFieldId(kProfile, 'Sentence');
  final String key = SrsFieldKeys.noteField(sentence);

  Map<String, String> lapis(String expr) => <String, String>{
    srsLapisFieldId(kProfile, 'Expression'): expr,
    sentence: '',
    srsLapisFieldId(kProfile, 'ExpressionReading'): '',
  };

  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  setUp(() async {
    t = DateTime.utc(2026, 11, 26, 12).millisecondsSinceEpoch;
    loc = SrsMemoryLocationStore();
    tmp = await Directory.systemTemp.createTemp('fushi_note_conflict_');
  });

  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } on FileSystemException {
      // Windows 句柄晚释放：留给系统清理。
    }
  });

  const String orig = '無用_ムヨー_0_NHK-2016-260118.mp3';
  final Uint8List audio = Uint8List.fromList(<int>[1, 2, 3, 4, 5]);
  final String hashed = SrsMediaStore.contentName(orig, audio);

  group('srsMediaRefsSubsume', () {
    bool Function(String) only(Set<String> files) =>
        (String n) => files.contains(n);

    test('只差断掉的原名 ↔ 本机有的内容寻址名：有文件的一边包含另一边', () {
      expect(
        srsMediaRefsSubsume(
          resolved: '前 [sound:$hashed] 後 <img src="$hashed">',
          dangling: '前 [sound:$orig] 後 <img src="$orig">',
          exists: only(<String>{hashed}),
        ),
        isTrue,
      );
    });

    test('文字不同 / 原名文件本机就有 / 内容寻址文件本机没有 / 扩展名不符 / 两边都是内容寻址名：都不算', () {
      final bool Function(String) onlyHashed = only(<String>{hashed});
      expect(
        srsMediaRefsSubsume(
          resolved: 'A [sound:$hashed]',
          dangling: 'B [sound:$orig]',
          exists: onlyHashed,
        ),
        isFalse,
        reason: '文字不同是真冲突',
      );
      expect(
        srsMediaRefsSubsume(
          resolved: '[sound:$hashed]',
          dangling: '[sound:$orig]',
          exists: only(<String>{hashed, orig}),
        ),
        isFalse,
        reason: '原名文件本机就有：不是断掉的引用',
      );
      expect(
        srsMediaRefsSubsume(
          resolved: '[sound:$hashed]',
          dangling: '[sound:$orig]',
          exists: only(const <String>{}),
        ),
        isFalse,
        reason: '内容寻址文件本机也没有：不往另一个断掉的引用上改',
      );
      final String wrongExt = hashed.replaceAll('.mp3', '.ogg');
      expect(
        srsMediaRefsSubsume(
          resolved: '[sound:$wrongExt]',
          dangling: '[sound:$orig]',
          exists: only(<String>{wrongExt}),
        ),
        isFalse,
        reason: '扩展名对不上，不可能是这个文件存进来的名字',
      );
      final String other = SrsMediaStore.contentName(
        orig,
        Uint8List.fromList(<int>[9]),
      );
      expect(
        srsMediaRefsSubsume(
          resolved: '[sound:$hashed]',
          dangling: '[sound:$other]',
          exists: onlyHashed,
        ),
        isFalse,
        reason: '两边都是内容寻址名 = 两个不同的文件',
      );
      expect(
        srsMediaRefsSubsume(
          resolved: '[sound:$hashed][sound:$other]',
          dangling: '[sound:$orig][sound:$orig]',
          exists: only(<String>{hashed, other}),
        ),
        isFalse,
        reason: '同一个原名对应了两个不同的内容寻址名',
      );
    });
  });

  test('两台设备各导入一次、一台没读到媒体：伪冲突在有文件的设备上自动消解，同步后两边都不再待裁决', () async {
    final SrsDbStore a = await device('a');
    final SrsDbStore b = await device('b');
    final String noteId = await a.createNote(
      noteTypeId: a.lapisNoteTypeId,
      fieldsById: lapis('無用'),
    );
    await syncAll(<SrsDbStore>[a, b]);
    // a 导入时没读到媒体：引用保留原名；b 读到了：改写成内容寻址名。两边并发。
    await a.updateNote(
      noteId,
      fieldsById: <String, String>{sentence: '例 [sound:$orig]'},
    );
    t += 1000;
    await b.updateNote(
      noteId,
      fieldsById: <String, String>{sentence: '例 [sound:$hashed]'},
    );
    await syncAll(<SrsDbStore>[a, b]);
    expect(
      (await a.notesPendingDecision()).single.id,
      noteId,
      reason: '前提：修复前这就是用户看到的「等你决定的笔记」',
    );
    final SrsMediaStore mediaB = mediaOf('b');
    expect(await mediaB.store(orig, audio), hashed);

    // a 本机两个文件都没有：判不了，不动。
    expect(await srsReconcileMediaRefConflicts(a, mediaOf('a')), 0);
    expect(await a.notesPendingDecision(), hasLength(1));

    expect(await srsReconcileMediaRefConflicts(b, mediaB), 1);
    expect(await b.notesPendingDecision(), isEmpty);
    await syncAll(<SrsDbStore>[a, b]);
    expect(await a.notesPendingDecision(), isEmpty);
    expect((await a.note(noteId))!.field(sentence), '例 [sound:$hashed]');
    expect(
      (await a.note(noteId))!.edits[key]!.conflicted,
      isFalse,
      reason: '消解记录在因果上覆盖了两边',
    );
  });

  test('真冲突（文字不同）不自动消解；整批采用某一台设备的版本', () async {
    final SrsDbStore a = await device('a');
    final SrsDbStore b = await device('b');
    final List<String> notes = <String>[
      for (int i = 0; i < 3; i++)
        await a.createNote(
          noteTypeId: a.lapisNoteTypeId,
          fieldsById: lapis('語$i'),
        ),
    ];
    await syncAll(<SrsDbStore>[a, b]);
    for (final String n in notes) {
      await a.updateNote(
        n,
        fieldsById: <String, String>{sentence: 'A の例文 [sound:$orig]'},
      );
    }
    t += 1000;
    for (final String n in notes) {
      await b.updateNote(
        n,
        fieldsById: <String, String>{sentence: 'B の例文 [sound:$hashed]'},
      );
    }
    await syncAll(<SrsDbStore>[a, b]);
    final SrsMediaStore mediaB = mediaOf('b');
    await mediaB.store(orig, audio);
    expect(await srsReconcileMediaRefConflicts(b, mediaB), 0, reason: '文字不同');
    final List<String> pending = <String>[
      for (final SrsNoteCacheRow row in await b.notesPendingDecision()) row.id,
    ];
    expect(pending.toSet(), notes.toSet());

    final Map<String, int> writers = await srsNoteConflictWriters(b, pending);
    expect(writers.values, everyElement(3));
    expect(writers, hasLength(2));
    final String writerA = (await b.note(notes.first))!.edits[key]!.live
        .firstWhere((SrsFieldEdit e) => '${e.value}'.startsWith('A'))
        .dot
        .writerId;
    expect(await srsAdoptNoteConflictSide(b, pending, writerA), 3);
    await syncAll(<SrsDbStore>[a, b]);
    for (final SrsDbStore s in <SrsDbStore>[a, b]) {
      expect(await s.notesPendingDecision(), isEmpty);
      for (final String n in notes) {
        expect((await s.note(n))!.field(sentence), 'A の例文 [sound:$orig]');
      }
    }
  });
}
