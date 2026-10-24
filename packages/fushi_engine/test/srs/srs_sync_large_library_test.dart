// 大库上同步 / 媒体引用不在调用方 isolate 上一次物化 O(全库) 的行（反馈 OMWOurRQKb）。
//
// 1.2 万张卡的库开着复习模块，整个 app 主线程卡死：每轮同步写快照时 exportAll 把全部事件读进 UI isolate
// 编码再整份解码校验，发件箱整个读进内存，媒体同步每轮经 allNoteViews 把整库笔记与修改记录物化一遍。
// 这里钉住两件事：
// 1. 口径：媒体引用的新实现（按页读修改记录）与旧实现（物化全部笔记）在含软删、并发候选、
//    删除与并发修改、已删笔记类型的夹具上结果相同（同步口径 / 回收前的保守口径都要保住，HBK-AUDIT-013）；
// 2. 结构：大库上一轮同步（冻结 + 上传 + 快照）与两种媒体引用，任何一条 SELECT 读回的行数都有页大小
//    的上界，不随库大小增长（旧实现单条 SELECT 读回整张日志表 / 全部笔记）。
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_engine/srs/apkg/srs_apkg_common.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_media_sync.dart';
import 'package:fushi_engine/srs/srs_note_type_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'apkg/apkg_test_support.dart';
import 'support/srs_bulk_fixture.dart';

const String kProfile = '01928c3e-0000-7000-8000-0000000a1b2c';

bool _bare(String n) =>
    n.isNotEmpty &&
    !n.contains('/') &&
    !n.contains(r'\') &&
    n != '.' &&
    n != '..';

/// 旧实现（物化全部笔记）：同步口径。
Future<Set<String>> _oracleReferenced(SrsDbStore store) async {
  final Set<String> out = <String>{};
  for (final SrsNoteView n in await store.allNoteViews()) {
    if (n.deletedAt != null) continue;
    for (final String v in n.fields.values) {
      out
        ..addAll(srsMediaRefsIn(v))
        ..addAll(srsStyleRefsIn(v));
    }
  }
  for (final SrsNoteTypeView t in await store.noteTypes()) {
    for (final SrsTemplateDef tpl in t.templates) {
      out
        ..addAll(srsMediaRefsIn(tpl.front, includeStatic: true))
        ..addAll(srsMediaRefsIn(tpl.back, includeStatic: true));
    }
    out.addAll(srsMediaRefsIn(t.css, includeStatic: true));
  }
  return out.where(_bare).toSet();
}

/// 旧实现（物化全部笔记）：回收前的保守口径。
Future<Set<String>> _oracleAll(SrsDbStore store) async {
  final Set<String> out = <String>{};
  for (final SrsNoteView n in await store.allNoteViews()) {
    for (final SrsRegister r in n.edits.registers) {
      if (!r.key.startsWith('f/')) continue;
      for (final SrsFieldEdit e in r.live) {
        final Object? v = e.value;
        if (v is! String) continue;
        out
          ..addAll(srsMediaRefsIn(v))
          ..addAll(srsStyleRefsIn(v));
      }
    }
  }
  final Map<String, SrsNoteTypeView?> types = await store.noteTypesById(
    await store.entityIds(SrsEntityKind.noteType),
  );
  for (final SrsNoteTypeView? t in types.values) {
    if (t == null) continue;
    for (final SrsTemplateDef tpl in t.templates) {
      out
        ..addAll(srsMediaRefsIn(tpl.front, includeStatic: true))
        ..addAll(srsMediaRefsIn(tpl.back, includeStatic: true));
    }
    out.addAll(srsMediaRefsIn(t.css, includeStatic: true));
  }
  return out.where(_bare).toSet();
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  test('媒体引用：按页实现与物化实现同口径（软删 / 并发候选 / 删除与并发修改 / 已删笔记类型）', () async {
    int t = DateTime.utc(2026, 10, 23, 12).millisecondsSinceEpoch;
    final MemoryDir dir = MemoryDir(() => t);
    Future<SrsDbStore> device(String id) =>
        openTestStore(profileUid: kProfile, deviceId: id, now: () => t);
    final SrsDbStore a = await device('a');
    final SrsDbStore b = await device('b');
    Future<void> syncAll() async {
      for (int round = 0; round < 3; round++) {
        for (final SrsDbStore s in <SrsDbStore>[a, b]) {
          t += 1000;
          await SrsSyncEngine(
            directoryKey: 'test',
            directory: dir,
            replica: s,
          ).syncOnce();
        }
      }
    }

    final String expr = srsLapisFieldId(kProfile, 'Expression');
    final String pic = srsLapisFieldId(kProfile, 'Picture');
    final String audio = srsLapisFieldId(kProfile, 'ExpressionAudio');
    Future<String> add(String word, String picture) => a.createNote(
      noteTypeId: a.lapisNoteTypeId,
      fieldsById: <String, String>{
        expr: word,
        pic: '<img src="$picture">',
        audio: '[sound:$word.mp3]',
      },
    );

    await add('live', 'live.png');
    final String deleted = await add('gone', 'gone.png');
    final String contested = await add('both', 'base.png');
    final String delVsEdit = await add('race', 'race.png');
    final String typeId = await a.createStockNoteType(
      SrsStockNoteType.basic,
      'Doomed',
    );
    final SrsNoteTypeView doomed = (await a.noteType(typeId))!;
    await a.updateTemplate(
      typeId,
      doomed.templates.first.id,
      front: '<img src="_doomed_tpl.png">${doomed.templates.first.front}',
    );
    await syncAll();

    await a.deleteNote(deleted);
    // 并发候选：两台设备各改同一个字段，谁也没看见谁。
    await a.updateNote(
      contested,
      fieldsById: <String, String>{pic: '<img src="from_a.png">'},
    );
    await b.updateNote(
      contested,
      fieldsById: <String, String>{pic: '<img src="from_b.png">'},
    );
    // 删除与并发修改：删除优先，修改留作待裁决。
    await a.deleteNote(delVsEdit);
    await b.updateNote(
      delVsEdit,
      fieldsById: <String, String>{pic: '<img src="race_edit.png">'},
    );
    await a.deleteNoteType(typeId);
    await syncAll();

    for (final SrsDbStore s in <SrsDbStore>[a, b]) {
      final Set<String> referenced = await srsReferencedMedia(s);
      final Set<String> all = await srsAllMediaReferences(s);
      expect(referenced, await _oracleReferenced(s));
      expect(all, await _oracleAll(s));
      // 夹具真的覆盖到了这些情形（不然上面两条等式是空的）。
      expect(referenced, containsAll(<String>['live.png', 'live.mp3']));
      expect(
        referenced.intersection(<String>{'from_a.png', 'from_b.png'}),
        hasLength(1),
      );
      expect(
        referenced,
        isNot(anyOf(contains('gone.png'), contains('race_edit.png'))),
      );
      expect(
        all,
        containsAll(<String>[
          'gone.png',
          'from_a.png',
          'from_b.png',
          'race_edit.png',
          '_doomed_tpl.png',
        ]),
      );
      expect(referenced, isNot(contains('_doomed_tpl.png')));
    }
  });

  test('大库：一轮同步（冻结 + 上传 + 快照）与媒体引用，单条 SELECT 读回行数有页大小上界', () async {
    // 2000 条笔记 / 4000 张卡 / 12000 条日志，发件箱约 2.8 万条事件。
    final BulkFixture f = await BulkFixture.open(notes: 2000);
    final SrsDbStore store = f.store;
    final int t = kBulkNowMs;
    final MemoryDir dir = MemoryDir(() => t);
    final int pending = (await store.unpublishedEvents()).length;
    expect(pending, greaterThan(20000));

    f.counter.reset();
    final SrsSyncReport r = await SrsSyncEngine(
      directoryKey: 'big',
      directory: dir,
      replica: store,
      options: const SrsSyncOptions(snapshotEveryBatches: 1),
    ).syncOnce();
    expect(r.error, isNull);
    expect(r.published, pending);
    expect(r.snapshotWritten, isTrue);
    // 旧实现：发件箱整表一条 SELECT 读回（~2.8 万行），快照 exportAll 一条读回整张日志表（1.2 万行）。
    expect(f.counter.maxRowsPerSelect, lessThanOrEqualTo(5000));

    // 快照内容完整（按页导出与整份导出同一份状态）。
    final String snapName = dir.files[store.writerId]!.keys.firstWhere(
      (String n) => srsParseSnapshotName(n) != null,
    );
    final SrsSnapshot snap = (await srsDecodeSnapshot(
      dir.files[store.writerId]![snapName]!,
    )).valueOrNull!;
    expect(
      <String>{for (final SrsEvent e in snap.events) e.canonical()},
      <String>{for (final SrsEvent e in await store.exportAll()) e.canonical()},
    );
    expect(snap.serverTimes, await store.exportServerTimes());

    for (final (String label, Future<Set<String>> Function() run)
        in <(String, Future<Set<String>> Function())>[
          ('srsReferencedMedia', () => srsReferencedMedia(store)),
          ('srsAllMediaReferences', () => srsAllMediaReferences(store)),
        ]) {
      f.counter.reset();
      await run();
      // 旧实现：一条 SELECT 读回全部 2000 条笔记、一条读回全部字段修改记录、一条读回整张服务器时间表。
      expect(
        f.counter.maxRowsPerSelect,
        lessThanOrEqualTo(1000),
        reason: label,
      );
    }

    // 上界不是空的：旧实现在同一个库上确实越界。
    f.counter.reset();
    await _oracleReferenced(store);
    expect(f.counter.maxRowsPerSelect, greaterThan(1000));
    f.counter.reset();
    await store.exportAll();
    expect(f.counter.maxRowsPerSelect, greaterThan(5000));
  });
}
