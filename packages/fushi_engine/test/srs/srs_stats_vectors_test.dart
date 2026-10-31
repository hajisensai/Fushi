// 统计页装载（`loadSrsStats`）的输入→输出回归向量。
//
// 输入是冻结的库：下面的场景造出的 srs.db 原样（gzip）存成 fixtures/srs_stats_vectors.db.gz（排程带 fuzz、种子是随机
// 生成的卡 ID，每次重造的库都不一样，所以冻结库本身）；两种装载条件（FSRS / 挂上 RWKV-Instant 假打分器）读同一份库。输出由**旧的 Dart 实现**（`allNoteViews` 物化全部笔记取
// 出处 + Drift 整表读卡片缓存 / 笔记缓存 / 有效复习投影，2026-10-29 L3 之前）在这些库上算出，存进
// fixtures/srs_stats_vectors.json；统计装载搬进 Rust（`stats_bundle` 命令，列式结果）之后，新实现必须在同一份库上
// 逐项给出同样的结果：每张可见卡的统计视图（状态 / 暂停 / 搁置 / 排程归属 / 间隔 / 到期 / 记忆状态 / 可提取度 /
// 遗忘 / 次数 / 加入日 / 目标保留率 / 是否按回忆率）、全部有效复习（时刻 / 日 / 小时 / 评分 / 种类 / 用时 / 提前）、
// 成熟事件、出处分组、每个牌组子树里的卡、牌组列表。
//
// 场景覆盖：多层牌组、多种出处（有 / 无标题、标题两侧空白、无出处）、多日评分与撤销、暂停、搁置、改到期日、重置、
// 删除笔记（隐藏卡）、移动卡片、跨日界（翻日时刻 + UTC 偏移）、RWKV-Instant 牌组（假打分器）。
//
// 重新生成（只在有意改变统计语义时）：SRS_STATS_VECTORS_WRITE=1 跑本文件（重造库并重算输出）。
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_rwkv_scheduling.dart';
import 'package:fushi_engine/srs/srs_stats.dart';
import 'package:fushi_engine/srs/srs_stats_loader.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'apkg/apkg_test_support.dart';
import 'support/srs_test_storage.dart';

const String kStatsVecProfile = '01928c3e-0000-7000-8000-0000000000c3';

final String _fixtures = '${Directory.current.path}/test/srs/fixtures'
    .replaceAll('\\', '/');

/// 确定性假打分器：R 只取决于卡 ID 与它最后一条日志是否存在。
final class _FakeRwkv implements SrsRwkvScheduling {
  @override
  bool get ready => true;

  @override
  Future<List<double>?> instantRetrievability(
    List<SrsRwkvCandidate> cards, {
    required int nowMs,
  }) async => <double>[
    for (final SrsRwkvCandidate c in cards)
      ((c.id.codeUnits.fold<int>(0, (int a, int b) => a + b) +
                  (c.lastLogId == null ? 0 : 7)) %
              97) /
          100.0,
  ];

  @override
  Future<void> onAnswered(String cardId, SrsReviewLog log) async {}

  @override
  Future<void> onCardsPurged(List<String> cardIds) async {}
}

/// 造场景库（只在重新生成时跑）。
Future<SrsDbStore> _build(
  int Function() clock,
  void Function(int) setNow,
) async {
  int t = DateTime.utc(2026, 9, 20, 12).millisecondsSinceEpoch;
  setNow(t);
  final SrsDbStore s = await openTestStore(
    profileUid: kStatsVecProfile,
    deviceId: 'v',
    now: clock,
  );
  await s.editField(
    SrsEntityKind.profile,
    kStatsVecProfile,
    SrsFieldKeys.utcOffsetMin,
    540,
  );
  await s.editField(
    SrsEntityKind.profile,
    kStatsVecProfile,
    SrsFieldKeys.dayRolloverHour,
    4,
  );
  final String root = await s.ensureDeckPath('Root');
  final String a = await s.ensureDeckPath('Root::A');
  final String a1 = await s.ensureDeckPath('Root::A::A1');
  final String b = await s.ensureDeckPath('Root::B');
  final String other = await s.ensureDeckPath('Other');
  await s.editField(SrsEntityKind.deck, b, SrsFieldKeys.deckParamsMode, 'own');
  await s.editField(SrsEntityKind.deck, b, SrsFieldKeys.deckRetention, 0.85);
  final List<SrsSourceRef?> sources = <SrsSourceRef?>[
    SrsSourceRef.book(
      bookKey: 'bk1',
      sectionIndex: 0,
      charStart: 3,
      title: '本 A',
    ),
    SrsSourceRef.book(
      bookKey: 'bk2',
      sectionIndex: 1,
      charStart: 0,
      title: '  本 A  ',
    ),
    SrsSourceRef.media(
      kind: SrsSourceKind.video,
      mediaKey: 'v1',
      startMs: 10,
      title: 'Video',
    ),
    SrsSourceRef.web('https://example.com/x'),
    null,
  ];
  int seq = 0;
  final List<String> notes = <String>[];
  Future<List<String>> addNew(String deck, int n) async {
    final List<String> out = <String>[];
    for (int i = 0; i < n; i++) {
      t += 61000;
      setNow(t);
      final String noteId = await s.createNote(
        noteTypeId: s.lapisNoteTypeId,
        fieldsById: <String, String>{
          srsLapisFieldId(kStatsVecProfile, 'Expression'): 'w$seq',
        },
        deckId: deck,
        tags: <String>['t${seq % 3}'],
        source: sources[seq % sources.length],
      );
      notes.add(noteId);
      out.add((await s.cardsOfNote(noteId)).single.id);
      seq++;
    }
    return out;
  }

  final List<String> inRoot = await addNew(root, 3);
  final List<String> inA = await addNew(a, 4);
  final List<String> inA1 = await addNew(a1, 5);
  final List<String> inB = await addNew(b, 4);
  final List<String> inOther = await addNew(other, 4);
  final List<String> all = <String>[
    ...inRoot,
    ...inA,
    ...inA1,
    ...inB,
    ...inOther,
  ];
  // 十几天里的评分：每天答一部分卡，评分按下标轮换；中间撤销一次。
  for (int d = 0; d < 14; d++) {
    t = DateTime.utc(2026, 9, 21 + d, 1 + (d * 5) % 20).millisecondsSinceEpoch;
    for (int k = 0; k < all.length; k++) {
      if ((k + d) % 3 != 0) continue;
      t += 37000;
      setNow(t);
      final SrsReviewLog log = await s.answer(
        all[k],
        1 + (k + d) % 4,
        durationMs: 1000 + 250 * k,
      );
      if (d == 5 && k == 3) {
        expect(await s.undo(all[k], log.id), isTrue);
      }
    }
  }
  t = DateTime.utc(2026, 10, 6, 3).millisecondsSinceEpoch;
  setNow(t);
  await s.setSuspended(inA[1], true);
  final int today = (await s.dayContext()).dayIndexOf(t);
  await s.buryUntil(inA1[2], today + 1);
  await s.setDueDay(inB[0], today + 3);
  await s.resetCard(inB[1]);
  await s.moveCard(inOther[0], a1);
  await s.deleteNote(notes[2]);
  return s;
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final bool write = Platform.environment['SRS_STATS_VECTORS_WRITE'] == '1';
  final File vectors = File('$_fixtures/srs_stats_vectors.json');
  final Map<String, Object?> produced = <String, Object?>{};
  bool built = false;
  final Map<String, Object?> expected = write
      ? const <String, Object?>{}
      : (jsonDecode(vectors.readAsStringSync()) as Map).cast<String, Object?>();

  tearDownAll(() {
    if (write) {
      vectors.writeAsStringSync(
        '${const JsonEncoder.withIndent(' ').convert(produced)}\n',
      );
    }
  });

  Future<void> scenario(String name, {required bool rwkv}) async {
    int t = 0;
    final File db = File('$_fixtures/srs_stats_vectors.db.gz');
    final SrsDbStore s;
    if (write && !built) {
      built = true;
      s = await _build(() => t, (int v) => t = v);
      final Directory tmp = Directory.systemTemp.createTempSync('srs_vec_');
      final String snap = p.join(tmp.path, 'snap.db');
      s.core.snapshotInto(snap, stripDeviceLocal: false);
      db.writeAsBytesSync(gzip.encode(File(snap).readAsBytesSync()));
      tmp.deleteSync(recursive: true);
    } else {
      final Directory dir = Directory.systemTemp.createTempSync('srs_vec_');
      addTearDown(() {
        try {
          dir.deleteSync(recursive: true);
        } on FileSystemException {
          // 句柄晚释放。
        }
      });
      final String path = p.join(dir.path, 'srs.db');
      File(path).writeAsBytesSync(gzip.decode(db.readAsBytesSync()));
      final TestSrs srs = await openTestSrsAt(path);
      s = await SrsDbStore.open(
        db: srs.db,
        core: srs.core,
        profileUid: kStatsVecProfile,
        deviceId: 'v',
        engine: const FakeFsrsEngine(),
        trustedClock: SrsTrustedClock(
          wallClockMs: () => t,
          bootClockMs: () => t,
          bootId: 'boot-v',
        ),
        fallbackRolloverHour: () => 4,
      );
    }
    if (rwkv) s.rwkv = _FakeRwkv();
    final int now = DateTime.utc(2026, 10, 6, 9).millisecondsSinceEpoch;
    t = now;
    final SrsStatsBundle bundle = await loadSrsStats(s, nowMs: now);
    final SrsStatsData d = bundle.data;
    String fmt(double? v) => v == null ? '-' : v.toStringAsFixed(9);
    final List<SrsStatCard> cards = List<SrsStatCard>.of(d.cards)
      ..sort((SrsStatCard x, SrsStatCard y) => x.id.compareTo(y.id));
    final Map<String, String> deckName = <String, String>{
      for (final (String, String) e in bundle.index.decks) e.$1: e.$2,
    };
    produced[name] = <String, Object?>{
      'today': d.today,
      'cards': <Object?>[
        for (final SrsStatCard c in cards)
          <Object?>[
            c.id,
            c.noteId,
            deckName[c.deckId] ?? '?',
            c.state.name,
            c.suspended,
            c.buried,
            c.fushiScheduled,
            c.intervalDays,
            c.dueDay,
            c.dueAt,
            fmt(c.stability),
            fmt(c.difficulty),
            fmt(c.retrievability),
            c.lapses,
            c.reps,
            c.addedDay,
            fmt(c.desiredRetention),
            c.byRecall,
          ],
      ],
      'reviews': <Object?>[
        for (final SrsStatReview r in d.reviews)
          <Object?>[
            r.cardId,
            r.at,
            r.day,
            r.hour,
            r.rating,
            r.kind.name,
            r.durationMs,
            r.early,
          ],
      ],
      'maturity': <Object?>[
        for (final SrsStatMaturityEvent e in d.maturityEvents)
          <Object?>[e.cardId, e.day, e.delta],
      ],
      'sources': <Object?>[
        for (final SrsSourceShare x in d.sourceShares())
          <Object?>[x.kind, x.title, x.notes],
      ],
      'decks': <Object?>[
        for (final (String, String) e in bundle.index.decks)
          <Object?>[e.$2, (bundle.index.cardIdsInDeck(e.$1).toList()..sort())],
      ],
      'retrievabilityAvailable': d.retrievabilityAvailable,
    };
    if (!write) {
      expect(
        jsonDecode(jsonEncode(produced[name])),
        expected[name],
        reason: name,
      );
    }
  }

  test('FSRS 牌组', () => scenario('fsrs', rwkv: false));
  test('RWKV-Instant 打分器在', () => scenario('rwkv', rwkv: true));
}
