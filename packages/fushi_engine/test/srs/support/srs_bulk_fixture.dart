/// 批量操作的往返计数 / 逐条等价测试共用：临时库 + 读命令计数 + 固定时钟 + 导入一批 Basic (and reversed) 笔记。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_core/fushi_core.dart'
    show SrsCardCacheRow, SrsNoteCacheRow;
import 'package:fushi_engine/srs/apkg/srs_apkg_import.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_note_type_store.dart';
import 'package:fushi_engine/srs/sync2/srs_fushisrs.dart';
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
  bootClockMs: () => kBulkNowMs,
);

class BulkFixture {
  BulkFixture._(this.core, this.store, this.counter);

  final SrsCore core;
  final SrsDbStore store;
  final SrsReadCounter counter;

  /// 打开临时 srs.db 并导入 [notes] 条笔记（每条两张卡、分在 Lang 与 Lang::JP，每卡 3 条日志）。
  ///
  /// 读命令一律经内核命令 worker 的查询道（与 app 相同）。
  static Future<BulkFixture> open({
    required int notes,
    String deviceId = 'dev',
  }) async {
    final SrsReadCounter counter = SrsReadCounter();
    final Directory tmp = Directory.systemTemp.createTempSync('srs_bulk_');
    addTearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } on FileSystemException {
        // 句柄晚释放。
      }
    });
    final TestSrs srs = openTestSrsIn(tmp.path);
    final SrsDbStore store = await SrsDbStore.open(
      core: srs.core,
      profileUid: kBulkUid,
      deviceId: deviceId,
      engine: const FakeFsrsEngine(),
      trustedClock: fixedTrustedClock(),
      fallbackRolloverHour: () => 4,
    );
    if (notes > 0) await importBench(store, notes);
    return BulkFixture._(srs.core, store, counter);
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

String basicTypeId(SrsDbStore s) => SrsKernelIds(s.profileUid).noteType(kBasic);

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

/// 本 profile 的全部 SRS 状态，可逐条比较，只经公开读命令（新代没有协议 3 那几张表，也不再直接看表）：
/// - 真相：导出的身份记录 / 修改记录 / 复习日志 / 不认识的事件（内核 `read events`），本机设备 ID（每个库随机）
///   换成 `DEV`，修改记录不比自己的 ID（由 dot 派生），本机产生的日志 ID（随机 UUIDv7）按 (卡, 抹掉 ID 的规范 JSON)
///   的顺序换成序号；
/// - 操作日志条数与本机下一个序号（内核 `status` 的 `ops` / `nextSeq`：导出的是投影后的值，同一字段改两次只剩一条，
///   写了几次靠这两个数）。本机修订号不比：新代按写命令推进（一条命令一次），逐条走与成批走命令数本来就不同；
/// - 派生层：笔记缓存行、卡片缓存行（[SrsDbStore.listNotes] / [SrsDbStore.allCardRows]），按 ID 排。卡片行第 9 列
///   （下标 8）是 hidden（`0` / `1`）。
/// - 服务器时刻：`server_times` 读命令（日志 ID → 收到它的同步段的服务器时刻；统计与排程按它取时刻），日志 ID 同上
///   换成序号后排序。
Future<Map<String, List<String>>> dumpSrsState(SrsDbStore s) async {
  final String device = s.sync2Device ?? '\u0000';
  final List<SrsEvent> events = await s.exportAll();
  String dev(String text) => text.replaceAll(device, 'DEV');

  // 排序键不能含 ID 本身（随机）：按 (卡, 抹掉 ID 的规范 JSON) 排。
  final List<(String, String)> logs = <(String, String)>[
    for (final SrsEvent e in events)
      if (e case SrsLogEvent(:final SrsReviewLog log))
        (
          log.id,
          '${log.cardId}|'
              '${dev(jsonEncode(log.toJson()).replaceAll(log.id, ''))}',
        ),
  ]..sort(((String, String) a, (String, String) b) => a.$2.compareTo(b.$2));
  final Map<String, String> logIds = <String, String>{
    for (int i = 0; i < logs.length; i++) logs[i].$1: 'log#$i',
  };
  String norm(String text) {
    String out = text;
    for (final MapEntry<String, String> e in logIds.entries) {
      out = out.replaceAll(e.key, e.value);
    }
    return out;
  }

  String bit(bool b) => b ? '1' : '0';
  final Map<String, Object?> status = await s.sync2Status();
  final SrsColumns serverTimes = await s.readTable(
    'server_times',
    const <String, Object?>{},
  );
  return <String, List<String>>{
    'entities': <String>[
      for (final SrsEvent e in events)
        if (e case SrsEntityEvent(:final SrsEntityRecord record))
          jsonEncode(record.toJson()),
    ]..sort(),
    // 同步 v2：修改记录的 dot 是 (本机设备 ID, op seq)，设备 ID 每个库随机生成；ID 由 dot 派生，不比——比的是语义
    // （同样的写入、同样的先后）。
    'edits': <String>[
      for (final SrsEvent e in events)
        if (e case SrsEditEvent(:final SrsFieldEdit edit))
          dev(
            jsonEncode(edit.toJson()),
          ).replaceAll(RegExp(r'"id":"[0-9a-f-]{36}",'), ''),
    ]..sort(),
    'logs': <String>[for (final (String _, String k) in logs) norm(k)],
    'unknown': <String>[
      for (final SrsEvent e in events)
        if (e is SrsUnknownEvent) jsonEncode(e.toJson()),
    ]..sort(),
    'ops': <String>['${status['ops']}|${status['nextSeq']}'],
    'serverTimes': <String>[
      for (int i = 0; i < serverTimes.strings('id').length; i++)
        '${norm(serverTimes.strings('id')[i])}|${serverTimes.ints('st')[i]}',
    ]..sort(),
    'notesCache': <String>[
      for (final SrsNoteCacheRow n in await s.listNotes(limit: 1 << 30))
        <Object?>[
          n.id,
          n.noteTypeId,
          n.guid,
          n.createdAt,
          n.deckId,
          n.deletedAt,
          n.termKey,
          n.readingKey,
          n.sortField,
          n.tagsJson,
          bit(n.pendingDecision),
        ].join('|'),
    ]..sort(),
    'cardsCache': <String>[
      for (final SrsCardCacheRow c in await s.allCardRows())
        norm(
          <Object?>[
            c.id,
            c.noteId,
            c.templateId,
            c.clozeOrd,
            c.deckId,
            bit(c.suspended),
            c.buriedUntilDay,
            c.flag,
            bit(c.hidden),
            c.queue,
            c.dueDay,
            c.dueAt,
            c.scheduledDays,
            c.reps,
            c.lapses,
            c.stability,
            c.difficulty,
            c.lastReviewedAt,
            c.lastLogId,
            c.scheduler,
            c.noteCreatedAt,
          ].join('|'),
        ),
    ]..sort(),
  };
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

/// 把 [src] 整个集合经 `.fushisrs`（导出 → 导入，内核 `import` + 另一个集合时 `collection_adopt`，用户确认）并进
/// [dst]：新代里对端的数据只经集合并入 / 收段进来（`apply` 拒绝外来已盖戳的事件，`gen4/cmd/writes.rs`）。
Future<void> joinCollectionFrom(SrsDbStore dst, SrsDbStore src) async {
  final Directory tmp = Directory.systemTemp.createTempSync('srs_join_');
  try {
    final File file = File('${tmp.path}${Platform.pathSeparator}peer.fushisrs');
    await srsExportFushiSrs(src, file, withMedia: false);
    await srsImportFushiSrs(
      dst,
      file,
      confirmForeign: (SrsFushiSrsForeign _) async => true,
    );
  } finally {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // 句柄晚释放。
    }
  }
}
