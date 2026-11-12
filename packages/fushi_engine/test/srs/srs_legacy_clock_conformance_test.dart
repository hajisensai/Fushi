// 旧版 HLC（本机日志的排序键、本机状态行的 `hlc` / `writerId`）的对拍：SRS 收掉 Dart 写路径第 6 步把这只时钟从
// `SrsDbStore`（`_clock` / `_writer`）搬进内核（native/fushi_fsrs/src/store/legacy_clock.rs）。
//
// 夹具 `fixtures/legacy_clock_store_vectors.json` 是搬之前（4cadefd4f，第 5 步头，Dart 持有时钟）在真 `SrsDbStore` 上
// 跑下面这段脚本冻结下来的：每一步之后本机状态行的 `hlc` / `writerId`、库里全部复习日志的 HLC（排序后的列表）、
// 这一步交回的日志的 HLC。搬之后同一段脚本逐值对上 = 已落库的 HLC 的字节表示与推进规则没变。
//
// 重新生成（只在有意改变推进规则时；本步不允许）：`FUSHI_GEN_LEGACY_CLOCK=<输出路径> dart test <本文件>`。
import 'dart:convert';
import 'dart:io';

import 'package:fushi_core/fushi_core.dart' show SrsCardCacheRow;
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'apkg/apkg_test_support.dart' show FakeFsrsEngine;
import 'support/srs_bulk_fixture.dart' show basicTypeId, importBench;

const String _uid = '01928c3e-0000-7000-8000-00000c10c0de';

/// 脚本的时间轴起点（晚于基准包里全部 revlog）。
const int _t0 = 1780272000000;

class _Replica {
  _Replica(this.path, this.deviceId, this.nowMs);

  final String path;
  final String deviceId;

  /// 可信时间（脚本逐步拨动）。
  int nowMs;

  late SrsCore core;
  late SrsDbStore store;

  Future<void> open() async {
    core = SrsCore.open(path);
    store = await SrsDbStore.open(
      core: core,
      profileUid: _uid,
      deviceId: deviceId,
      engine: const FakeFsrsEngine(),
      trustedClock: SrsTrustedClock(
        wallClockMs: () => nowMs,
        bootClockMs: () => nowMs,
        bootId: 'conformance',
      ),
      fallbackRolloverHour: () => 4,
      localOffsetMin: () => 0,
    );
  }

  Future<void> close() async {
    core.close();
  }

  /// 本机状态行里的旧版时钟与写入者、库里全部日志的 HLC（排序）。
  Future<Map<String, Object?>> snapshot() async {
    // 测试专用的原始通道直接看表（ID 参数写 srs_id(?)）。
    final List<Map<String, Object?>> state = core.debugSelectRaw(
      'SELECT json FROM srs_local_state WHERE profile_uid = srs_id(?)',
      <Object?>[_uid],
    );
    final Map<String, Object?> j = state.isEmpty
        ? const <String, Object?>{}
        : (jsonDecode(state.single['json']! as String) as Map)
              .cast<String, Object?>();
    final List<String> logs = <String>[
      for (final Map<String, Object?> r in core.debugSelectRaw(
        'SELECT json FROM srs_review_logs WHERE profile_uid = srs_id(?)',
        <Object?>[_uid],
      ))
        (jsonDecode(r['json']! as String) as Map)['hlc']! as String,
    ]..sort();
    return <String, Object?>{
      'hlc': j['hlc'],
      'writerId': j['writerId'],
      'logs': logs,
    };
  }
}

SrsReviewLog _foreignLog(String id, String card, Hlc hlc, int at) =>
    SrsReviewLog(
      id: id,
      profileUid: _uid,
      cardId: card,
      kind: SrsLogKind.review,
      rating: 3,
      hlc: hlc,
      occurredAt: at,
      timeSource: SrsTimeSource.wall,
      origin: SrsLogOrigin.anki,
      reviewType: SrsReviewType.review,
      algorithm: 'anki',
      result: const SrsScheduleResult(queue: SrsQueue.review, dueDay: 30000),
    );

String _logId(int n) =>
    '01928c3e-1111-7000-8000-${n.toRadixString(16).padLeft(12, '0')}';

/// 跑脚本，返回每一步的记录。
Future<List<Map<String, Object?>>> _run(Directory tmp) async {
  final List<Map<String, Object?>> steps = <Map<String, Object?>>[];
  final _Replica a = _Replica('${tmp.path}/a.db', 'devA', _t0);
  final _Replica b = _Replica('${tmp.path}/b.db', 'devB', _t0 + 77);
  await a.open();
  await b.open();
  try {
    Future<void> step(
      String name,
      Future<Object?> Function() body, {
      _Replica? on,
    }) async {
      final Object? returned = await body();
      steps.add(<String, Object?>{
        'step': name,
        ...await (on ?? a).snapshot(),
        'returned': ?returned,
      });
    }

    await step('open', () async => null);
    await step('import bench', () => importBench(a.store, 4).then((_) => null));
    final SrsDbStore s = a.store;
    final SrsNoteTypeView basic = (await s.noteType(basicTypeId(s)))!;
    final List<String> cards = <String>[
      for (final SrsCardCacheRow c in await s.allCardRows()) c.id,
    ]..sort();
    int made = 0;
    Future<String> newNote() => s.createNote(
      noteTypeId: basic.id,
      fieldsById: <String, String>{
        basic.fields[0].id: 'front ${made++}',
        basic.fields[1].id: 'back',
      },
    );

    a.nowMs += 1000;
    late String note;
    await step('createNote', () async {
      note = await newNote();
      return null;
    });
    // 同一毫秒再写：计数器接着走。
    await step('createNote same ms', () async {
      await newNote();
      return null;
    });
    await step('editFields', () async {
      final List<SrsFieldEdit>? out = await s
          .editFields(SrsEntityKind.note, note, <String, Object?>{
            SrsFieldKeys.noteField(basic.fields[0].id): 'changed',
            SrsFieldKeys.noteField(basic.fields[1].id): 'changed too',
          });
      return out?.length;
    });
    late SrsReviewLog first;
    await step('answer same ms', () async {
      first = await s.answer(cards[0], 3);
      return first.hlc.encode();
    });
    a.nowMs += 5;
    await step(
      'answer later',
      () async => (await s.answer(cards[1], 4)).hlc.encode(),
    );
    // 可信时间倒退（换了校时来源）：物理部分不退、计数器走。
    a.nowMs -= 4000;
    await step(
      'answer after clock went back',
      () async => (await s.answer(cards[2], 2)).hlc.encode(),
    );
    await step('undo', () => s.undo(cards[0], first.id));
    await step('resetCard', () async {
      await s.resetCard(cards[3]);
      return null;
    });
    await step('setDueDay', () async {
      await s.setDueDay(cards[4], 30123);
      return null;
    });
    await step('createDeck', () async {
      await s.createDeck('Conformance');
      return null;
    });
    await step('resolveConflict', () async {
      await s.resolveConflict(
        SrsEntityKind.card,
        cards[0],
        SrsFieldKeys.flag,
        1,
      );
      return null;
    });
    await step('writeEdits with a record', () async {
      final String id = await s.deckIdForNew('WithRecord');
      final List<SrsFieldEdit> out = await s.writeEdits(
        <SrsEditSpec>[
          SrsEditSpec(SrsEntityKind.deck, id, SrsFieldKeys.name, 'WithRecord'),
          SrsEditSpec(SrsEntityKind.card, cards[1], SrsFieldKeys.flag, 3),
        ],
        records: <SrsEntityRecord>[
          SrsEntityRecord(
            id: id,
            profileUid: _uid,
            kind: SrsEntityKind.deck,
            payload: const <String, Object?>{'createdAt': 0},
          ),
        ],
      );
      return out.length;
    });
    // 标签在内核里展开成若干条标签操作（一项输入不对应恰好一条修改记录）：时钟仍按项推进一次。
    await step('editFields: tags', () async {
      final List<SrsFieldEdit>? out = await s.editFields(
        SrsEntityKind.note,
        note,
        <String, Object?>{
          SrsFieldKeys.noteTags: <String>['a', 'b'],
        },
      );
      return out?.length;
    });
    a.nowMs += 9000;
    await step('editFieldsBatch', () async {
      final List<SrsFieldEdit> out = await s.editFieldsBatch(<SrsFieldChange>[
        for (final String c in cards.take(3))
          SrsFieldChange(SrsEntityKind.card, c, SrsFieldKeys.flag, 2),
      ]);
      return out.length;
    });
    // 来源自带 HLC 的日志（导入）：按收到对端事件的规则推进，没有服务器时间 → 钳到 可信时间 + 10 分钟。
    await step('importEvents: within tolerance', () async {
      await s.importEvents(<SrsEvent>[
        SrsLogEvent(
          _foreignLog(
            _logId(1),
            cards[5],
            Hlc(a.nowMs + 60000, 7, 'anki'),
            a.nowMs - 5,
          ),
        ),
      ]);
      return null;
    });
    await step('importEvents: far future is clamped', () async {
      await s.importEvents(<SrsEvent>[
        SrsLogEvent(
          _foreignLog(
            _logId(2),
            cards[5],
            Hlc(a.nowMs + 86400000, 3, 'anki'),
            a.nowMs - 4,
          ),
        ),
        SrsLogEvent(
          _foreignLog(
            _logId(3),
            cards[6],
            Hlc(a.nowMs + srsClockToleranceMs, 9, 'a:b:c'),
            a.nowMs - 3,
          ),
        ),
      ]);
      return null;
    });
    await step(
      'answer after import',
      () async => (await s.answer(cards[6], 3)).hlc.encode(),
    );
    // 草稿导入：已定稿事件先按「收到」推进，修改记录草稿再逐条 tick。
    a.nowMs += srsClockToleranceMs + 5000;
    await step('importDrafts: ready logs + edit drafts', () async {
      await s.importDrafts(<SrsEventDraft>[
        SrsEditDraft(SrsEntityKind.card, cards[0], SrsFieldKeys.flag, 4),
        SrsReadyDraft(
          SrsLogEvent(
            _foreignLog(
              _logId(4),
              cards[7],
              Hlc(a.nowMs + 1234, 2, 'anki'),
              a.nowMs - 2,
            ),
          ),
        ),
        SrsEditDraft(SrsEntityKind.card, cards[1], SrsFieldKeys.flag, 4),
        SrsEditDraft(
          SrsEntityKind.card,
          cards[2],
          SrsFieldKeys.flag,
          1,
          initial: true,
        ),
      ]);
      return null;
    });
    await step(
      'answer after drafts',
      () async => (await s.answer(cards[7], 3)).hlc.encode(),
    );

    // 另一台设备上写的事件，作为外来已盖戳事件并入。
    final SrsDbStore sb = b.store;
    await importBench(sb, 2);
    final List<String> bCards = <String>[
      for (final SrsCardCacheRow c in await sb.allCardRows()) c.id,
    ]..sort();
    b.nowMs = a.nowMs + 2 * srsClockToleranceMs;
    await step(
      'peer answers ahead of us',
      () async => (await sb.answer(bCards[0], 3)).hlc.encode(),
      on: b,
    );
    await sb.setFlag(bCards[1], 3);
    final List<SrsEvent> remote = await sb.exportAll();
    await step('applyRemote: no server time', () async {
      await s.applyRemote(remote);
      return null;
    });
    await step(
      'answer after applyRemote',
      () async => (await s.answer(cards[1], 3)).hlc.encode(),
    );
    b.nowMs += 5 * srsClockToleranceMs;
    await sb.answer(bCards[1], 2);
    await sb.resetCard(bCards[0]);
    final List<SrsEvent> remote2 = await sb.exportAll();
    // 服务器时间：整批一个 + 个别事件单独给（都比事件自己的物理时间早得多 → 钳到 S + 10 分钟）。
    final List<SrsEvent> late = <SrsEvent>[
      for (final SrsEvent e in remote2)
        if (e is SrsLogEvent && e.log.hlc.physical >= b.nowMs) e,
    ];
    await step('applyRemote: batch server time + per-event', () async {
      await s.applyRemote(
        remote2,
        serverTimeMs: a.nowMs + 3 * srsClockToleranceMs,
        serverTimes: <String, int>{
          late.first.id: a.nowMs + 4 * srsClockToleranceMs + 17,
        },
      );
      return null;
    });
    await step(
      'answer after server-timed applyRemote',
      () async => (await s.answer(cards[2], 3)).hlc.encode(),
    );
    await step('undoLogs', () async {
      final SrsReviewLog l = await s.answer(cards[3], 3);
      return <Object?>[
        l.hlc.encode(),
        await s.undoLogs(<(String, String)>[(cards[3], l.id)]),
      ];
    });

    // 重开副本：时钟从本机状态行接着走。
    await a.close();
    await a.open();
    await step('reopen', () async => null);
    a.nowMs += 3;
    // 作答的卡取自导入时那份（ID 确定）：新建笔记的卡 ID 是随机的，按全表排序取会让后面的重排条数不确定。
    await step(
      'answer after reopen',
      () async => (await a.store.answer(cards[4], 3)).hlc.encode(),
    );
    await step('rescheduleDeck', () async {
      final SrsDeckTree tree = await a.store.deckTree();
      final String lang = tree.decks
          .firstWhere((SrsDeckView d) => tree.fullName(d.id) == 'Lang')
          .id;
      return a.store.rescheduleDeck(lang);
    });
    await step('deleteDeck: child', () async {
      final SrsDeckTree tree = await a.store.deckTree();
      final String jp = tree.decks
          .firstWhere((SrsDeckView d) => tree.fullName(d.id) == 'Lang::JP')
          .id;
      return (await a.store.deleteDeck(jp)).length;
    });
    a.nowMs += 1;
    await step('deleteDeck: with cards', () async {
      final SrsDeckTree tree = await a.store.deckTree();
      final String lang = tree.decks
          .firstWhere((SrsDeckView d) => tree.fullName(d.id) == 'Lang')
          .id;
      return (await a.store.deleteDeck(lang, deleteCards: true)).length;
    });
  } finally {
    await a.close();
    await b.close();
  }
  return steps;
}

void main() {
  test('旧版 HLC 的推进与本机状态行：与搬进内核之前逐值相同', () async {
    final Directory tmp = Directory.systemTemp.createTempSync('srs_lclock_');
    addTearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } on FileSystemException {
        // 句柄晚释放。
      }
    });
    final List<Map<String, Object?>> got = await _run(tmp);
    final String? gen = Platform.environment['FUSHI_GEN_LEGACY_CLOCK'];
    if (gen != null && gen.isNotEmpty) {
      File(gen).writeAsStringSync(
        '${const JsonEncoder.withIndent(' ').convert(<String, Object?>{'steps': got})}\n',
      );
      return;
    }
    final List<Object?> want =
        (jsonDecode(
                  File(
                    'test/srs/fixtures/legacy_clock_store_vectors.json',
                  ).readAsStringSync(),
                )
                as Map)['steps']!
            as List<Object?>;
    expect(got.length, want.length);
    for (int i = 0; i < want.length; i++) {
      expect(
        jsonDecode(jsonEncode(got[i])),
        want[i],
        reason: 'step $i (${got[i]['step']})',
      );
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
