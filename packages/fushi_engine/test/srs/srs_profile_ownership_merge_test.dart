// BUG-4843（BUG-4626 在新代的并入场景，交接 T1 节「待 G9-5 确认」）：同库两份 profile 时 A 拿 B 的实体 ID 下手。
// 设计稿 2026-11-11 §2 下 ID 不再按 uid 加盐、并入 = 操作并集：A 的集合之后并进 B 的集合（另一台设备上的 B 确认导入
// A 的 `.fushisrs`，内核 `import` + `collection_adopt`）时，A 当初写下的指向 B 的实体的操作会对 B 的同名实体生效。
// 内核在写入口设实体归属闸（`native/fushi_fsrs/src/store/gen4/cmd/writes_owner.rs`）：别的集合有、本集合没有痕迹的
// 实体不写。这里钉住端到端：A 的那些写一条都不落，并入之后 B 的笔记与卡片不被改。
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_core/fushi_core.dart' show SrsCardCacheRow;
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_engine/srs/sync2/srs_fushisrs.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'support/srs_fake_engine.dart';
import 'support/srs_test_storage.dart';

const String kA = '01928c3e-0000-7000-8000-0000000000a1';
const String kB = '01928c3e-0000-7000-8000-0000000000b2';

Future<SrsDbStore> _open(SrsStorage st, String uid, String device) =>
    SrsDbStore.open(
      core: st.core,
      profileUid: uid,
      deviceId: device,
      engine: const SrsFakeEngine(),
    );

/// [s] 本机日志的长度（内核 `status` 的 `nextSeq` − 1）。
Future<int> _ops(SrsDbStore s) async =>
    ((await s.sync2Status())['nextSeq']! as int) - 1;

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  test('A 写 B 的 ID（同库）一条都不落 → A 的集合并进 B → B 的笔记与卡片不被改', () async {
    // 本机：A 与 B 两份 profile 同库。B 的数据在 B 的集合里。
    final SrsStorage local = await openTestSrsStorage();
    final SrsDbStore a = await _open(local, kA, 'dev-local');
    final SrsDbStore b = await _open(local, kB, 'dev-local');
    final String expression = srsLapisFieldId(kB, 'Expression');
    final String note = await b.createNote(
      noteTypeId: b.lapisNoteTypeId,
      fieldsById: <String, String>{expression: '鳥'},
      tags: <String>['tag-鳥'],
    );
    final String card = (await b.cardsOfNote(note)).single.id;

    // A 拿 B 的 ID 下手：实体归属闸拦下，A 的日志一条不多。
    final int before = await _ops(a);
    await a.editField(
      SrsEntityKind.note,
      note,
      SrsFieldKeys.noteField(expression),
      '被 A 改',
    );
    await a.editFields(SrsEntityKind.note, note, <String, Object?>{
      SrsFieldKeys.noteTags: <String>['串了'],
    });
    await a.setFlag(card, 3);
    await a.setSuspended(card, true);
    // 身份记录（复核实测：以前这一条落了，并入后按「规范 JSON 最小者胜」换掉 B 的笔记类型与 guid）与 profile 设置
    // （没有身份记录痕迹的实体：以前 A 拿 B 的 uid 改翻日时刻，并入后成了 B 的设置）。
    await b.setDayRolloverHour(5);
    final SrsNoteView original = (await b.note(note))!;
    await a.writeEdits(
      const <SrsEditSpec>[],
      records: <SrsEntityRecord>[
        SrsEntityRecord(
          id: note,
          profileUid: kA,
          kind: SrsEntityKind.note,
          payload: <String, Object?>{
            'noteTypeId': a.fushiCardNoteTypeId,
            'guid': 'stolen',
            'createdAt': 1,
          },
        ),
      ],
    );
    await a.editField(
      SrsEntityKind.profile,
      kB,
      SrsFieldKeys.dayRolloverHour,
      9,
    );
    // 第六波（BUG-4843 残余二）：用 B 的**真实** guid（ID 能按规则重算出来）、只换笔记类型的身份记录，带同批改字段——与 B 的
    // 定义结构冲突，不写。残余一：牌组身份记录 + 同批改名（名字重算不出这个 ID），以前牌组身份记录不判、替改名作保。
    await a.writeEdits(
      <SrsEditSpec>[
        SrsEditSpec(
          SrsEntityKind.note,
          note,
          SrsFieldKeys.noteField(expression),
          '被 A 改',
        ),
      ],
      records: <SrsEntityRecord>[
        SrsEntityRecord(
          id: note,
          profileUid: kA,
          kind: SrsEntityKind.note,
          payload: <String, Object?>{
            'noteTypeId': a.fushiCardNoteTypeId,
            'guid': original.guid,
            'createdAt': 1,
          },
        ),
      ],
    );
    final String deck = await b.createDeck('B 牌组');
    await a.writeEdits(
      <SrsEditSpec>[
        SrsEditSpec(SrsEntityKind.deck, deck, SrsFieldKeys.name, '被 A 改'),
      ],
      records: <SrsEntityRecord>[
        SrsEntityRecord(
          id: deck,
          profileUid: kA,
          kind: SrsEntityKind.deck,
          payload: const <String, Object?>{'createdAt': 0},
        ),
      ],
    );
    expect(await _ops(a), before, reason: 'A 的日志里不能有指向 B 的实体的操作');
    expect((await b.note(note))!.field(expression), '鳥');

    // 另一台设备上的 B（同一个 B 集合）：先拿到 B 的全部数据。
    final Directory tmp = Directory.systemTemp.createTempSync('srs_4836_');
    addTearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } on FileSystemException {
        // 句柄尚未释放；临时目录留给系统清理。
      }
    });
    final File bFile = File('${tmp.path}${Platform.pathSeparator}b.fushisrs');
    await srsExportFushiSrs(b, bFile, withMedia: false);
    final SrsStorage remote = await openTestSrsStorage();
    final SrsDbStore b2 = await _open(remote, kB, 'dev-remote');
    await srsImportFushiSrs(
      b2,
      bFile,
      confirmForeign: (SrsFushiSrsForeign _) async => true,
    );
    expect((await b2.note(note))!.field(expression), '鳥');

    // 用户在那台设备上确认把 A 的集合并进来（导入 A 的 `.fushisrs`：另一个集合，确认后并入）。
    final File aFile = File('${tmp.path}${Platform.pathSeparator}a.fushisrs');
    await srsExportFushiSrs(a, aFile, withMedia: false);
    bool asked = false;
    await srsImportFushiSrs(
      b2,
      aFile,
      confirmForeign: (SrsFushiSrsForeign _) async => asked = true,
    );
    expect(asked, isTrue, reason: 'A 的集合是另一个集合，要问过用户才并入');

    final SrsNoteView? merged = await b2.note(note);
    expect(merged, isNotNull);
    expect(merged!.field(expression), '鳥', reason: 'A 的写不能改到 B 的笔记');
    expect(merged.tags, <String>['tag-鳥']);
    expect(merged.noteTypeId, original.noteTypeId, reason: 'B 的笔记类型不能被换掉');
    expect(merged.guid, original.guid);
    expect((await b2.syncedDayRollover())?.hour, 5, reason: 'B 的翻日时刻');
    expect((await b2.deckTree())[deck]?.name, 'B 牌组', reason: 'B 的牌组名');
    final SrsCardCacheRow row = (await b2.cardRow(card))!;
    expect(row.flag, 0);
    expect(row.suspended, isFalse);
  });
}
