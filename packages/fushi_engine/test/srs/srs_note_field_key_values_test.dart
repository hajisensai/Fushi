/// [SrsDbStore.noteFieldKeyValues]：只读一个字段键的批量读者（全景的作品出处）不物化整条笔记。
///
/// 反馈 lGXA8zC1A2 / i8qNDs_V_D：约 2 万卡、每条都带出处、字段里是整段释义 HTML 的库，首页全景对「带出处的
/// 笔记」整批 [SrsDbStore.notes]，把全部字段原文读进主 isolate 再整批过一次 `ffsrs_materialize`，启动时主线程
/// ANR（PSS 1.58 GB）。这里钉两件事：
/// 1. 与整条物化后取同一个键逐值相同（含同一个键上被后来的修改支配的旧值）；
/// 2. 2 万条笔记的合成大库上，读回的字节只与这个键有关，与字段正文大小无关。
library;

import 'dart:io';

import 'package:drift/drift.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'apkg/apkg_test_support.dart' show FakeFsrsEngine;
import 'support/srs_test_storage.dart';

const String kProfile = '01928c3e-0000-7000-8000-0000000000b7';

/// 统计 SELECT 读回的字节（字符串按 UTF-8 长度、BLOB 按长度）。
class _ByteCounter extends QueryInterceptor {
  int bytes = 0;

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    final List<Map<String, Object?>> rows = await executor.runSelect(
      statement,
      args,
    );
    for (final Map<String, Object?> r in rows) {
      for (final Object? v in r.values) {
        if (v is String) bytes += v.length;
        if (v is Uint8List) bytes += v.length;
      }
    }
    return rows;
  }
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  int t = DateTime.utc(2026, 11, 1, 12).millisecondsSinceEpoch;

  Future<(SrsDbStore, _ByteCounter)> open() async {
    final Directory tmp = Directory.systemTemp.createTempSync('srs_fkv_');
    addTearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } on FileSystemException {
        // 句柄晚释放。
      }
    });
    final _ByteCounter counter = _ByteCounter();
    final TestSrs srs = await openTestSrsAt(
      '${tmp.path}/srs.db',
      interceptor: counter,
    );
    final SrsDbStore store = await SrsDbStore.open(
      db: srs.db,
      core: srs.core,
      profileUid: kProfile,
      deviceId: 'dev',
      engine: const FakeFsrsEngine(),
      trustedClock: SrsTrustedClock(
        wallClockMs: () => t,
        bootClockMs: () => t,
        bootId: 'boot',
      ),
      fallbackRolloverHour: () => 4,
    );
    return (store, counter);
  }

  String expression(SrsDbStore s) =>
      srsFushiCardFieldId(s.profileUid, 'Expression');
  String glossary(SrsDbStore s) =>
      srsFushiCardFieldId(s.profileUid, 'MiscInfo');

  SrsSourceRef book(int i) => SrsSourceRef.book(
    bookKey: 'book-${i % 37}',
    sectionIndex: i % 11,
    charStart: i,
    title: '作品 ${i % 37}',
  );

  test('equals the source of the fully materialized note, including a later '
      'edit that dominates the first value', () async {
    final (SrsDbStore s, _) = await open();
    final List<String> ids = <String>[];
    for (int i = 0; i < 6; i++) {
      t += 1000;
      ids.add(
        await s.createNote(
          noteTypeId: s.fushiCardNoteTypeId,
          fieldsById: <String, String>{expression(s): '語$i'},
          guid: 'g$i',
          // 一条没有出处：结果里不出现。
          source: i == 3 ? null : book(i),
        ),
      );
    }
    t += 1000;
    await s.editFields(SrsEntityKind.note, ids[1], <String, Object?>{
      SrsFieldKeys.noteSource: book(999).toJson(),
    });

    final Map<String, Object?> got = await s.noteFieldKeyValues(<String>[
      ...ids,
      'missing-note',
    ], SrsFieldKeys.noteSource);
    final Map<String, SrsNoteView?> views = await s.notes(ids);
    expect(got.keys.toSet(), <String>{
      for (final String id in ids)
        if (views[id]!.source != null) id,
    });
    for (final MapEntry<String, Object?> e in got.entries) {
      expect(
        SrsSourceRef.fromJson(e.value)!.toJson(),
        views[e.key]!.source!.toJson(),
        reason: e.key,
      );
    }
    expect(SrsSourceRef.fromJson(got[ids[1]])!.data['bookKey'], 'book-0');
    expect(SrsSourceRef.fromJson(got[ids[1]])!.data['start'], 999);
  });

  test('20k-note library: reads only the source edits, independent of how '
      'large the note fields are', () async {
    final (SrsDbStore s, _ByteCounter counter) = await open();
    const int notes = 20000;
    // 每条笔记一段 4 KiB 的「释义 HTML」：整库字段正文约 80 MiB（真实反馈里是上 GB）。
    final String html = '<div class="gloss">${'意味の説明。' * 680}</div>';
    final List<String> ids = <String>[];
    final Stopwatch build = Stopwatch()..start();
    for (int start = 0; start < notes; start += 500) {
      final List<SrsEventDraft> drafts = <SrsEventDraft>[];
      for (int i = start; i < start + 500 && i < notes; i++) {
        drafts.addAll(
          s.newNoteDrafts(
            noteTypeId: s.fushiCardNoteTypeId,
            fieldsById: <String, String>{
              expression(s): '語$i',
              glossary(s): html,
            },
            guid: 'big-$i',
            source: book(i),
          ),
        );
        ids.add(SrsIds.note(kProfile, 'big-$i'));
      }
      await s.importDrafts(drafts);
    }
    build.stop();
    final int fieldBytes = notes * html.length;

    counter.bytes = 0;
    final Stopwatch read = Stopwatch()..start();
    final Map<String, Object?> sources = await s.noteFieldKeyValues(
      ids,
      SrsFieldKeys.noteSource,
    );
    read.stop();
    final int perNote = counter.bytes ~/ notes;

    // 对照：以前的读法（整条物化）在 1000 条上每条读回多少。
    const int slice = 1000;
    counter.bytes = 0;
    final Stopwatch whole = Stopwatch()..start();
    await s.notes(ids.sublist(0, slice));
    whole.stop();
    final int wholePerNote = counter.bytes ~/ slice;
    // ignore: avoid_print
    print(
      'noteFieldKeyValues: $notes notes (field text $fieldBytes B, built in '
      '${build.elapsedMilliseconds} ms): read ${perNote * notes} B '
      '($perNote B/note) in ${read.elapsedMilliseconds} ms; '
      'materializing $slice notes read $wholePerNote B/note in '
      '${whole.elapsedMilliseconds} ms',
    );
    expect(sources, hasLength(notes));
    expect(
      SrsSourceRef.fromJson(sources[ids[12345]])!.data['bookKey'],
      'book-${12345 % 37}',
    );
    // 只有出处那一个键的记录（含修改记录的信封）回到 Dart：每条笔记几百字节、与字段正文大小无关；
    // 整条物化每条要读回全部 4 KiB 正文。
    expect(perNote, lessThan(1024));
    expect(perNote * 5, lessThan(wholePerNote));
  }, timeout: const Timeout(Duration(minutes: 10)));
}
