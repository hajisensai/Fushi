/// 批量操作的往返计数 / 逐条等价测试共用：内存库 + 语句计数 + 固定时钟 + 导入一批 Basic (and reversed) 笔记。
library;

import 'dart:io';

import 'package:drift/drift.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/apkg/srs_apkg_import.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_note_type_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import '../apkg/apkg_test_support.dart';
import '../apkg/srs_apkg_import_bench_test.dart' show benchApkg;
import '../apkg/srs_apkg_import_test.dart' show kBasic, kFullOptions;
import 'srs_query_counter.dart';
import 'srs_test_storage.dart';

const String kBulkUid = '01928c3e-0000-7000-8000-0000000b0175';

/// 固定的「现在」（2026-06-01，晚于基准包里全部 revlog）。
const int kBulkNowMs = 1780272000000;

/// 时钟不走的可信时钟：逐条与成批两条路径的 HLC / 时刻逐位相同，状态可以逐字节比较。
SrsTrustedClock fixedTrustedClock() => SrsTrustedClock(
  wallClockMs: () => kBulkNowMs,
  monotonicMs: () => kBulkNowMs,
  bootId: 'bulk',
);

class BulkFixture {
  BulkFixture._(this.db, this.store, this.counter);

  final SrsDatabase db;
  final SrsDbStore store;
  final CountingInterceptor counter;

  /// 打开临时 srs.db 并导入 [notes] 条笔记（每条两张卡、分在 Lang 与 Lang::JP，每卡 3 条日志）。
  ///
  /// [background]：库开在临时文件上、走后台 isolate（与 app 同一种连接，语句真的跨 isolate
  /// 往返、与别的异步任务交错）；默认同 isolate 执行。
  static Future<BulkFixture> open({
    required int notes,
    String deviceId = 'dev',
    bool background = false,
  }) async {
    final CountingInterceptor counter = CountingInterceptor();
    final Directory tmp = Directory.systemTemp.createTempSync('srs_bulk_');
    addTearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } on FileSystemException {
        // 句柄晚释放。
      }
    });
    final TestSrs srs = await openTestSrsAt(
      '${tmp.path}/srs.db',
      interceptor: counter,
      inline: !background,
    );
    final SrsDatabase db = srs.db;
    final SrsDbStore store = await SrsDbStore.open(
      db: db,
      core: srs.core,
      profileUid: kBulkUid,
      deviceId: deviceId,
      engine: const FakeFsrsEngine(),
      trustedClock: fixedTrustedClock(),
      fallbackRolloverHour: () => 4,
    );
    if (notes > 0) await importBench(store, notes);
    return BulkFixture._(db, store, counter);
  }
}

/// 把基准包（[notes] 条 Basic (and reversed) 笔记，guid `bench-<i>`）导入 [store]。
Future<void> importBench(SrsDbStore store, int notes) async {
  await importAnkiPackage(
    store: store,
    bytes: benchApkg(notes),
    storeMedia: (String name, Uint8List b) async => name,
    options: kFullOptions,
    zstdDecompress: (Uint8List b) => null,
  );
}

/// 全名为 [fullName] 的牌组。
Future<String> deckId(SrsDbStore s, String fullName) async {
  final SrsDeckTree tree = await s.deckTree();
  return tree.decks
      .firstWhere((SrsDeckView d) => tree.fullName(d.id) == fullName)
      .id;
}

String basicTypeId(SrsDbStore s) => SrsIds.noteType(s.profileUid, kBasic);

/// 「更改笔记类型」的一组参数。
class ChangeSpec {
  const ChangeSpec(
    this.noteIds,
    this.targetTypeId,
    this.fieldMap,
    this.templateMap,
  );

  final List<String> noteIds;
  final String targetTypeId;
  final Map<String, String?> fieldMap;
  final Map<String, String?> templateMap;
}

/// 全部笔记从导入的 Basic (and reversed) 换到内置「Fushi 卡片」（ID 确定，两份库相同；
/// 前两个字段、第一个模板按序映射，其余留空 / 从头学）。
Future<ChangeSpec> fushiCardChange(SrsDbStore s) async {
  final SrsNoteTypeView from = (await s.noteType(basicTypeId(s)))!;
  final SrsNoteTypeView to = (await s.noteType(s.fushiCardNoteTypeId))!;
  return ChangeSpec(
    await s.noteIdsOfType(from.id),
    to.id,
    <String, String?>{
      for (int i = 0; i < to.fields.length; i++)
        to.fields[i].id: i < from.fields.length ? from.fields[i].id : null,
    },
    <String, String?>{to.templates.first.id: from.templates.first.id},
  );
}

/// 全部笔记从导入的 Basic (and reversed) 换到新建的 basicReversed（字段、模板按序映射）。
Future<ChangeSpec> reversedChange(SrsDbStore s) async {
  final SrsNoteTypeView from = (await s.noteType(basicTypeId(s)))!;
  final String toId = await s.createStockNoteType(
    SrsStockNoteType.basicReversed,
    'Reversed',
  );
  final SrsNoteTypeView to = (await s.noteType(toId))!;
  return ChangeSpec(
    await s.noteIdsOfType(from.id),
    toId,
    <String, String?>{
      for (int i = 0; i < to.fields.length; i++)
        to.fields[i].id: from.fields[i].id,
    },
    <String, String?>{
      for (int i = 0; i < to.templates.length; i++)
        to.templates[i].id: from.templates[i].id,
    },
  );
}

/// 本 profile 的全部 SRS 行（事件表、发件箱、本机状态、两张缓存），可逐条比较：
/// 只抹掉本机「写入时刻」两列（receivedAt / updatedAt，墙钟，与语义无关），
/// 本机产生的日志 ID（随机 UUIDv7）按 (卡, HLC) 顺序换成序号。
Future<Map<String, List<String>>> dumpSrsState(SrsDatabase db) async {
  Future<List<String>> rows(String sql) async => <String>[
    for (final QueryRow r in await db.customSelect(sql).get())
      r.data.values.join('|'),
  ];
  final List<String> devices = await rows(
    'SELECT srs_idt(device) AS device FROM sync2_self',
  );
  final String device = devices.isEmpty
      ? '\u0000'
      : (await db
                .customSelect(
                  'SELECT srs_idt(device) AS device FROM sync2_self',
                )
                .getSingle())
            .read<String>('device');

  // 排序键不能含 ID 本身（随机）：按 (卡, 抹掉 ID 的规范 JSON) 排。
  final List<(String, String)> logs = <(String, String)>[
    for (final QueryRow r
        in await db
            .customSelect('SELECT id, card_id, json FROM srs_review_logs')
            .get())
      (
        r.read<String>('id'),
        '${r.read<String>('card_id')}|'
            '${r.read<String>('json').replaceAll(r.read<String>('id'), '')}',
      ),
  ]..sort(((String, String) a, (String, String) b) => a.$2.compareTo(b.$2));
  final Map<String, String> logIds = <String, String>{
    for (int i = 0; i < logs.length; i++) logs[i].$1: 'log#$i',
  };
  String norm(String s) {
    String out = s;
    for (final MapEntry<String, String> e in logIds.entries) {
      out = out.replaceAll(e.key, e.value);
    }
    return out;
  }

  final Map<String, List<String>> out = <String, List<String>>{
    'entities': await rows(
      'SELECT id, profile_uid, kind, payload_json, created_at '
      'FROM srs_entities ORDER BY id',
    ),
    // 同步 v2：修改记录的 dot 是 (本机 v2 设备 ID, op seq)，设备 ID 每个库随机生成；ID 由 dot 派生。
    // 设备 ID 换成占位、按 (实体, 字段键, seq) 排、不比 ID 列——比的是语义（同样的写入、同样的先后）。
    'edits': <String>[
      for (final String r in await rows(
        'SELECT entity_kind, entity_id, field_key, writer_id, seq, json '
        'FROM srs_field_edits ORDER BY entity_kind, entity_id, field_key, seq',
      ))
        r
            .replaceAll(device, 'DEV')
            .replaceAll(RegExp(r'"id":"[0-9a-f-]{36}",'), ''),
    ],
    'logs': (await rows(
      'SELECT id, card_id, kind, rating, occurred_at, review_type, origin, '
      'duration_ms, json FROM srs_review_logs',
    )).map(norm).toList()..sort(),
    'unknown': await rows(
      'SELECT id, json FROM srs_unknown_events ORDER BY id',
    ),
    'eventLocal': (await rows(
      'SELECT event_id, outbox_seq, server_time FROM srs_event_local',
    )).map(norm).toList()..sort(),
    // 本机状态里的纪元是开库时随机生成的（每个库各一个），不比。
    'localState': <String>[
      for (final String j in await rows('SELECT json FROM srs_local_state'))
        j.replaceAll(RegExp(r'"epoch":"[^"]*"'), '"epoch":_'),
    ],
    'notesCache': await rows(
      'SELECT id, note_type_id, guid, created_at, deck_id, deleted_at, '
      'term_key, reading_key, sort_field, tags_json, pending_decision '
      'FROM srs_notes_cache ORDER BY id',
    ),
    'cardsCache': (await rows(
      'SELECT id, note_id, template_id, cloze_ord, deck_id, suspended, '
      'buried_until_day, flag, hidden, queue, due_day, due_at, '
      'scheduled_days, reps, lapses, stability, difficulty, '
      'last_reviewed_at, last_log_id, scheduler, note_created_at '
      'FROM srs_cards_cache ORDER BY id',
    )).map(norm).toList(),
  };
  return out;
}

/// 两份状态逐表比较（失败时只报第一处不同，避免把几千行打进日志）。
void expectSameState(
  Map<String, List<String>> actual,
  Map<String, List<String>> expected, {
  String label = '',
}) {
  for (final String table in expected.keys) {
    final List<String> a = actual[table]!;
    final List<String> e = expected[table]!;
    for (int i = 0; i < e.length && i < a.length; i++) {
      if (a[i] != e[i]) {
        fail(
          '$label$table row $i differs:\n  actual:   ${a[i]}\n  expected: ${e[i]}',
        );
      }
    }
    expect(a.length, e.length, reason: '$label$table row count');
  }
}
