// 缓存刷新（笔记 / 卡片缓存行与有效复习投影）的固定向量回归。
//
// 向量来源：test/srs/fixtures/cache_vectors.json.gz，由收编进 Rust **之前**的 Dart 实现
// （srs_db_store.dart `_flushCachesNow` / `_planNote` / `_mediaRefsOf` / `_applyNotePlan` / `_cardCacheRow` /
// `_refreshCardChunk` / `_refreshStatProjection`）生成，生成脚本留档在 fixtures/gen_cache_vectors.dart.txt。
// 向量里是原始事件表（srs_entities / srs_field_edits / srs_review_logs / srs_event_local）的全部行，与
// `rebuildCaches()` 之后的三张缓存表（srs_notes_cache 去 updated_at / srs_cards_cache / srs_stat_reviews）。
// 原始表里还有两类只来自遗留数据（旧同步 / 备份恢复）的行，同样由旧实现重建出期望：srs_event_local 的服务器时刻
// （排序键钳位，改变并发修改的胜者与历史顺序）与一个谁也没见过的写者的并发修改 / 并发删除（pending_decision = 1）。
//
// 期望表取重建结果。删除前的 Dart 增量刷新会把「不再应有的卡」（删掉的模板、更改笔记类型的前身卡、消失的
// cloze 序号）留成 hidden=1 行、重建又不写它们，两条路径结果不同；Rust 版两条路径都删这些行，所以增量用例
// 与重建用例同样逐行全等（一行不多），并且先往被刷新的笔记下塞一张不该有的卡，证明增量刷新会把它删掉。
//
// - 用例 1：空库灌原始四张表 → rebuildCaches → 三张缓存表逐行等于向量（浮点逐位比较）。
// - 用例 2：同上重建后，再走两条增量刷新路径（被刷新的行先改坏，证明真的重算了）：
//   a. 对一批笔记改标签再改回、对另一批卡改旗标再改回（公开 API，本机写入 → `_flushCachesNow`，走
//      `_applyNotePlan` 与 `_refreshCardChunk`）；
//   b. 把本机缓存修订号写回 0 再打开（`SrsDbStore.open` → 升级路径：全部笔记 + 有新卡位置的卡 + 全部有日志的
//      卡标脏，走增量刷新而不是删表重建）。
//   两条路径前都给被刷新的笔记各塞一张不该有的卡（复制它的一张卡、换个卡 ID）。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show QueryRow, Variable, driftRuntimeOptions;
import 'package:fushi_core/fushi_core.dart' show srsIdType;
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'support/srs_test_storage.dart';

const List<String> kRawTables = <String>[
  'srs_entities',
  'srs_field_edits',
  'srs_review_logs',
  'srs_event_local',
];

/// 原始表里的 ID 列（与内核 store/ids.rs 的列清单一致）：导入向量时绑成存储编码。
/// `json` 是生成列、写入走 `jslim` 的表（srs.db v18）。
const Set<String> _kSlimTables = <String>{'srs_review_logs', 'srs_field_edits'};

const Map<String, Set<String>> _kIdColumns = <String, Set<String>>{
  'srs_entities': <String>{'id', 'profile_uid'},
  'srs_field_edits': <String>{'id', 'profile_uid', 'entity_id', 'writer_id'},
  'srs_review_logs': <String>{'id', 'profile_uid', 'card_id'},
  'srs_event_local': <String>{'event_id', 'profile_uid'},
};

const List<String> kCacheTables = <String>[
  'srs_notes_cache',
  'srs_cards_cache',
  'srs_stat_reviews',
];

/// 表 → {columns, pk, rows}。
typedef Table = ({
  List<String> columns,
  List<String> pk,
  List<List<Object?>> rows,
});

Table _table(Object? j) {
  final Map<String, Object?> m = (j! as Map<Object?, Object?>)
      .cast<String, Object?>();
  return (
    columns: (m['columns']! as List<Object?>).cast<String>(),
    pk: (m['pk']! as List<Object?>).cast<String>(),
    rows: <List<Object?>>[
      for (final Object? r in m['rows']! as List<Object?>)
        (r! as List<Object?>).toList(),
    ],
  );
}

Object? _cellIn(Object? v) => v is Map ? base64Decode(v['b64']! as String) : v;

/// 比较用的规范形：浮点按位、字节按 base64。
String _canon(Object? v) {
  if (v is double) {
    final ByteData b = ByteData(8)..setFloat64(0, v);
    return 'f64:${b.getUint64(0).toRadixString(16)}';
  }
  if (v is Uint8List) return 'b64:${base64Encode(v)}';
  if (v is Map) return 'b64:${v['b64']}';
  return jsonEncode(v);
}

String _rowKey(List<Object?> row, List<int> pkIdx) =>
    pkIdx.map((int i) => _canon(row[i])).join('|');

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final Map<String, Object?> vec =
      (jsonDecode(
                utf8.decode(
                  gzip.decode(
                    File(
                      'test/srs/fixtures/cache_vectors.json.gz',
                    ).readAsBytesSync(),
                  ),
                ),
              )
              as Map<Object?, Object?>)
          .cast<String, Object?>();
  final String profile = vec['profile']! as String;
  final String deviceId = vec['device']! as String;
  final Map<String, Object?> raw = (vec['tables']! as Map<Object?, Object?>)
      .cast<String, Object?>();
  final Map<String, Object?> expected =
      (vec['expected']! as Map<Object?, Object?>).cast<String, Object?>();

  // 向量时刻之后的固定时钟（本机新写的修改记录要比向量里的晚）。
  int t = DateTime.utc(2031, 1, 1).millisecondsSinceEpoch;

  Future<SrsDbStore> openOn(SrsStorage st) => SrsDbStore.open(
    db: st.db,
    core: st.core,
    profileUid: profile,
    deviceId: deviceId,
    engine: FfiFsrsEngine.tryCreate(),
    trustedClock: SrsTrustedClock(
      wallClockMs: () => t += 1000,
      monotonicMs: () => t,
      bootId: 'boot-vec',
    ),
    fallbackRolloverHour: () => 4,
  );

  /// 空库 → 换成向量里的原始四张表 → 重建。
  Future<(SrsStorage, SrsDbStore)> loaded() async {
    final SrsStorage st = await openTestSrsStorage();
    final SrsDbStore s = await openOn(st);
    await s.db.transaction(() async {
      for (final String name in kRawTables) {
        final Table tb = _table(raw[name]);
        await s.db.customStatement('DELETE FROM $name');
        final Set<String> idCols = _kIdColumns[name]!;
        final String sql =
            // 两张投影表的 `json` 是生成列（srs.db v18）：原文写进 `jslim`（不瘦也合法）。
            'INSERT INTO $name (${tb.columns.map((String c) => c == 'json' && _kSlimTables.contains(name) ? '"jslim"' : '"$c"').join(', ')}) '
            'VALUES (${tb.columns.map((String c) => idCols.contains(c) ? 'srs_id(?)' : '?').join(', ')})';
        for (final List<Object?> r in tb.rows) {
          await s.db.customStatement(sql, <Object?>[
            for (final Object? v in r) _cellIn(v),
          ]);
        }
      }
    });
    for (final String name in kRawTables) {
      final int n =
          (await s.db
                  .customSelect('SELECT COUNT(*) AS n FROM $name')
                  .getSingle())
              .read<int>('n');
      expect(n, _table(raw[name]).rows.length, reason: '$name rows after load');
    }
    await s.rebuildCaches();
    return (st, s);
  }

  /// 读出一张缓存表（列取向量的列，按向量的主键排序）。
  Future<List<List<Object?>>> read(SrsDbStore s, String name) async {
    final Table want = _table(expected[name]);
    final List<QueryRow> rows = await s.db
        .customSelect(
          'SELECT ${want.columns.map((String c) => '"$c"').join(', ')} FROM $name '
          'WHERE profile_uid = ? ORDER BY ${want.pk.map((String c) => '"$c"').join(', ')}',
          variables: <Variable<Object>>[Variable<String>(profile, srsIdType)],
        )
        .get();
    return <List<Object?>>[
      for (final QueryRow r in rows)
        <Object?>[for (final String c in want.columns) r.data[c]],
    ];
  }

  /// 逐行逐列对向量，多一行少一行都算错。
  Future<void> check(SrsDbStore s, String name) async {
    final Table want = _table(expected[name]);
    final List<int> pkIdx = <int>[
      for (final String c in want.pk) want.columns.indexOf(c),
    ];
    final List<List<Object?>> got = await read(s, name);
    final Map<String, List<Object?>> gotBy = <String, List<Object?>>{
      for (final List<Object?> r in got) _rowKey(r, pkIdx): r,
    };
    final List<String> problems = <String>[];
    for (final List<Object?> w in want.rows) {
      final String k = _rowKey(w, pkIdx);
      final List<Object?>? g = gotBy.remove(k);
      if (g == null) {
        problems.add('missing $k');
        continue;
      }
      for (int i = 0; i < want.columns.length; i++) {
        if (_canon(w[i]) != _canon(g[i])) {
          problems.add(
            '$k ${want.columns[i]}: want ${_canon(w[i])} got ${_canon(g[i])}',
          );
        }
      }
    }
    for (final String k in gotBy.keys) {
      problems.add('extra $k');
    }
    expect(
      problems.take(20).toList(),
      isEmpty,
      reason: '$name: ${problems.length} problems',
    );
  }

  test('灌原始事件 → rebuildCaches → 三张缓存表逐行等于向量', () async {
    final (_, SrsDbStore s) = await loaded();
    for (final String name in kCacheTables) {
      await check(s, name);
    }
    for (final String name in kCacheTables) {
      expect((await read(s, name)).length, _table(expected[name]).rows.length);
    }
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('重建后再走增量刷新（本机写入 / 升级路径），结果仍与向量一致', () async {
    final (SrsStorage st, SrsDbStore s) = await loaded();
    final Table notes = _table(expected['srs_notes_cache']);
    final Table cards = _table(expected['srs_cards_cache']);
    int col(Table tb, String c) => tb.columns.indexOf(c);

    // 改坏一批行：增量刷新必须把它们重算回来（否则这个用例对「刷新了没有」毫无约束）。
    Future<void> corrupt({List<String>? noteIds, List<String>? cardIds}) async {
      String where(String c, List<String>? ids) => ids == null
          ? ''
          : ' AND $c IN (${ids.map((String i) => "srs_id('$i')").join(',')})';
      await s.db.customStatement(
        "UPDATE srs_notes_cache SET guid = '#', created_at = -1, deck_id = '#', deleted_at = -1, "
        "term_key = '#', reading_key = '#', sort_field = '#', tags_json = '[\"#\"]', "
        "media_refs = '#' WHERE 1 = 1${where('id', noteIds)}",
      );
      await s.db.customStatement(
        "UPDATE srs_cards_cache SET deck_id = '#', suspended = 1 - suspended, buried_until_day = -1, "
        "flag = 99, queue = '#', due_day = -1, due_at = -1, scheduled_days = -1, reps = -1, lapses = -1, "
        "stability = -1.0, difficulty = -1.0, last_reviewed_at = -1, last_log_id = '#', scheduler = '#', "
        'note_created_at = -1, new_position = -1 WHERE 1 = 1${where('id', cardIds)}',
      );
      await s.db.customStatement(
        'UPDATE srs_stat_reviews SET occurred_at = -1, utc_offset_min = -1, rating = -1, kind = -1, '
        'duration_ms = -1, prev_due_day = -1, maturity_delta = 99 WHERE 1 = 1${where('card_id', cardIds)}',
      );
    }

    /// 给 [noteIds] 各塞一张不该有的卡：复制它的第一张卡、卡 ID 换成固定前缀（不会与真卡撞）。返回塞了几张。
    Future<int> plantStale(Iterable<String> noteIds) async {
      final List<String> all = <String>[
        for (final QueryRow r
            in await s.db
                .customSelect('PRAGMA table_info(srs_cards_cache)')
                .get())
          '"${r.read<String>('name')}"',
      ];
      final String rest = all.where((String c) => c != '"id"').join(', ');
      final Set<String> want = noteIds.toSet();
      final Set<String> done = <String>{};
      for (final List<Object?> c in cards.rows) {
        final String note = c[col(cards, 'note_id')]! as String;
        if (!want.contains(note) || !done.add(note)) continue;
        await s.db.customStatement(
          'INSERT INTO srs_cards_cache ("id", $rest) '
          'SELECT srs_id(?), $rest FROM srs_cards_cache WHERE id = srs_id(?)',
          <Object?>['stale-$note', c[col(cards, 'id')]],
        );
      }
      return done.length;
    }

    // a. 本机写入：没有待裁决的笔记里每 7 条取一条改标签再改回；它们以外的卡每 11 张取一张改旗标再改回。
    final List<List<Object?>> sampleNotes = <List<Object?>>[
      for (int i = 0; i < notes.rows.length; i += 7)
        if (notes.rows[i][col(notes, 'pending_decision')] == 0) notes.rows[i],
    ];
    final Set<String> sampleNoteIds = <String>{
      for (final List<Object?> n in sampleNotes) n[col(notes, 'id')]! as String,
    };
    final List<String> noteCards = <String>[
      for (final List<Object?> c in cards.rows)
        if (sampleNoteIds.contains(c[col(cards, 'note_id')]))
          c[col(cards, 'id')]! as String,
    ];
    final List<List<Object?>> otherCards = <List<Object?>>[
      for (final List<Object?> c in cards.rows)
        if (!sampleNoteIds.contains(c[col(cards, 'note_id')])) c,
    ];
    final List<List<Object?>> sampleCards = <List<Object?>>[
      for (int i = 0; i < otherCards.length; i += 11) otherCards[i],
    ];
    await corrupt(
      noteIds: sampleNoteIds.toList(),
      cardIds: <String>[
        ...noteCards,
        for (final List<Object?> c in sampleCards)
          c[col(cards, 'id')]! as String,
      ],
    );
    expect(await plantStale(sampleNoteIds), greaterThan(0));
    for (final List<Object?> n in sampleNotes) {
      final String id = n[col(notes, 'id')]! as String;
      final List<String> tags =
          (jsonDecode(n[col(notes, 'tags_json')]! as String) as List<Object?>)
              .cast<String>();
      await s.updateNote(id, tags: <String>[...tags, '__vec_touch']);
      await s.updateNote(id, tags: tags);
    }
    for (final List<Object?> c in sampleCards) {
      final String id = c[col(cards, 'id')]! as String;
      final int flag = c[col(cards, 'flag')]! as int;
      await s.setFlag(id, (flag + 1) % 8);
      await s.setFlag(id, flag);
    }
    for (final String name in kCacheTables) {
      await check(s, name);
    }

    // b. 升级路径：全表改坏、每条笔记塞一张不该有的卡，缓存修订号写回 0，重新打开同一个库。
    await corrupt();
    expect(
      await plantStale(<String>[
        for (final List<Object?> n in notes.rows)
          n[col(notes, 'id')]! as String,
      ]),
      greaterThan(100),
    );
    final QueryRow ls = await s.db
        .customSelect(
          'SELECT json FROM srs_local_state WHERE profile_uid = ?',
          variables: <Variable<Object>>[Variable<String>(profile, srsIdType)],
        )
        .getSingle();
    final Map<String, Object?> j =
        (jsonDecode(ls.read<String>('json')) as Map<Object?, Object?>)
            .cast<String, Object?>();
    expect(j['cacheRev'], isA<int>());
    j['cacheRev'] = 0;
    await s.db.customStatement(
      'UPDATE srs_local_state SET json = ? WHERE profile_uid = srs_id(?)',
      <Object?>[jsonEncode(j), profile],
    );
    final SrsDbStore reopened = await openOn(st);
    for (final String name in kCacheTables) {
      await check(reopened, name);
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}
