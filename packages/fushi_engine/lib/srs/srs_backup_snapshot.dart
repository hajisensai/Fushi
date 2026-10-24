/// SRS 备份读快照：全部事件的规范行、服务器时间表、清单计数。
///
/// 读法与连接无关（[SrsSqlSelect]）。备份时由 [SrsBackupSnapshotReader] 在 srs.db 上另开一条
/// **独立只读连接**（Rust 打开，[SrsCore.beginRead]；Dart 的 SQLite 绝不打开 srs.db）、在后台 isolate
/// 里读：库是 WAL，读事务拿的是开会话那一刻的快照，写连接上的复习写入照常进行，不再排在二三十秒的
/// 备份读取后面（BUG-3579 只做到「给复习界面让路」，读的时候仍占着主连接）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:fushi_srs/fushi_srs.dart';
import 'package:meta/meta.dart' show visibleForTesting;

/// 一条只读查询：`?` 占位，结果每行一个列名 → 值的表。
typedef SrsSqlSelect =
    Future<List<Map<String, Object?>>> Function(String sql, List<Object?> args);

/// 清单里显示的计数（见 [srsBackupCounts]）。
typedef SrsBackupCounts = ({int notes, int cards, int reviews});

/// 按页导出全部事件的规范 JSON 行（与 `SrsEvent.canonical()` 逐字节相同；按表、表内按 rowid 排）：
/// 每页最多 [pageSize] 行交给 [onPage]，内存只占一页。修改记录 / 复习日志 / 不认识的事件在库里本来就
/// 存规范编码，直接拼外层，不解析再编码。要一致快照就在同一个读事务里调用。
Future<void> srsForEachCanonicalLinePage(
  SrsSqlSelect select,
  String profileUid,
  Future<void> Function(List<String> lines) onPage, {
  int pageSize = 2000,
}) async {
  await _pageRows(
    select,
    profileUid,
    'srs_entities',
    'id, profile_uid, kind, payload_json',
    pageSize,
    (List<Map<String, Object?>> rows) => onPage(<String>[
      for (final Map<String, Object?> r in rows)
        SrsEntityEvent(
          SrsEntityRecord(
            id: r['id']! as String,
            profileUid: r['profile_uid']! as String,
            kind:
                SrsEntityKind.tryParse(r['kind']! as String) ??
                SrsEntityKind.note,
            payload: (jsonDecode(r['payload_json']! as String) as Map)
                .cast<String, Object?>(),
          ),
        ).canonical(),
    ]),
  );
  await _pageRows(
    select,
    profileUid,
    'srs_field_edits',
    'json',
    pageSize,
    (List<Map<String, Object?>> rows) => onPage(<String>[
      for (final Map<String, Object?> r in rows)
        '{"t":"edit","x":${r['json']! as String}}',
    ]),
  );
  await _pageRows(
    select,
    profileUid,
    'srs_review_logs',
    'json',
    pageSize,
    (List<Map<String, Object?>> rows) => onPage(<String>[
      for (final Map<String, Object?> r in rows)
        '{"t":"log","x":${r['json']! as String}}',
    ]),
  );
  await _pageRows(
    select,
    profileUid,
    'srs_unknown_events',
    'json',
    pageSize,
    (List<Map<String, Object?>> rows) => onPage(<String>[
      for (final Map<String, Object?> r in rows) r['json']! as String,
    ]),
  );
}

/// 按页导出已知的「事件 ID → 服务器时间 S」（备份用）。
Future<void> srsForEachServerTimePage(
  SrsSqlSelect select,
  String profileUid,
  Future<void> Function(List<(String, int)> page) onPage, {
  int pageSize = 5000,
}) => _pageRows(
  select,
  profileUid,
  'srs_event_local',
  'event_id, server_time',
  pageSize,
  (List<Map<String, Object?>> rows) => onPage(<(String, int)>[
    for (final Map<String, Object?> r in rows)
      (r['event_id']! as String, r['server_time']! as int),
  ]),
  extraWhere: 'server_time IS NOT NULL',
);

/// 备份清单里显示的计数：未删除的笔记、可见的卡片、有效的复习（评分且没被撤销）。
Future<SrsBackupCounts> srsBackupCounts(
  SrsSqlSelect select,
  String profileUid,
) async {
  Future<int> count(String sql, List<Object?> args) async =>
      (await select(sql, args)).single['c']! as int;
  final int notes = await count(
    'SELECT COUNT(*) AS c FROM srs_notes_cache '
    'WHERE profile_uid = ? AND deleted_at IS NULL',
    <Object?>[profileUid],
  );
  final int cards = await count(
    'SELECT COUNT(*) AS c FROM srs_cards_cache '
    'WHERE profile_uid = ? AND hidden = 0',
    <Object?>[profileUid],
  );
  // 有效复习 = 有评分的 review 日志里没被 undo 撤销的。只解码 undo 日志（通常很少）拿被撤销的 ID，
  // 其余全用计数查询，不把整张日志表读进内存。
  final Set<String> revoked = <String>{};
  for (final Map<String, Object?> r in await select(
    'SELECT json FROM srs_review_logs WHERE profile_uid = ? AND kind = ?',
    <Object?>[profileUid, SrsLogKind.undo],
  )) {
    final Object? target = (jsonDecode(r['json']! as String) as Map)['revokes'];
    if (target is String) revoked.add(target);
  }
  const String validReview =
      'profile_uid = ? AND kind = ? AND rating IS NOT NULL';
  int reviews = await count(
    'SELECT COUNT(*) AS c FROM srs_review_logs WHERE $validReview',
    <Object?>[profileUid, SrsLogKind.review],
  );
  final List<String> ids = revoked.toList();
  for (int i = 0; i < ids.length; i += 500) {
    final List<String> chunk = ids.sublist(i, min(i + 500, ids.length));
    reviews -= await count(
      'SELECT COUNT(*) AS c FROM srs_review_logs '
      'WHERE $validReview AND id IN '
      '(${List<String>.filled(chunk.length, '?').join(',')})',
      <Object?>[profileUid, SrsLogKind.review, ...chunk],
    );
  }
  return (notes: notes, cards: cards, reviews: reviews);
}

/// 本 profile 在 [table] 里的行，按 rowid 键集分页（不用 OFFSET：深页不退化成 O(n²)）。
Future<void> _pageRows(
  SrsSqlSelect select,
  String profileUid,
  String table,
  String columns,
  int pageSize,
  Future<void> Function(List<Map<String, Object?>> rows) onPage, {
  String? extraWhere,
}) async {
  int after = -1 << 62;
  while (true) {
    final List<Map<String, Object?>> rows = await select(
      'SELECT rowid AS rid_, $columns FROM $table '
      'WHERE profile_uid = ? AND rowid > ?'
      '${extraWhere == null ? '' : ' AND $extraWhere'} '
      'ORDER BY rowid LIMIT ?',
      <Object?>[profileUid, after, pageSize],
    );
    if (rows.isEmpty) return;
    await onPage(rows);
    if (rows.length < pageSize) return;
    after = rows.last['rid_']! as int;
  }
}

/// 把一份快照的事件与服务器时间流式写进两个暂存文件（`events` 每行一条规范 JSON，`serverTimes` 是
/// 一个 JSON 对象），返回事件条数与清单计数。[checkStop] 每读完一页调一次（抛异常即中止）。
Future<({int eventCount, SrsBackupCounts counts})> srsWriteSnapshotFiles(
  SrsSqlSelect select,
  String profileUid, {
  required String eventsPath,
  required String serverTimesPath,
  required FutureOr<void> Function() checkStop,
  int pageSize = 2000,
}) async {
  int eventCount = 0;
  final IOSink ev = File(eventsPath).openWrite();
  try {
    await srsForEachCanonicalLinePage(select, profileUid, (
      List<String> lines,
    ) async {
      await checkStop();
      final StringBuffer sb = StringBuffer();
      for (final String l in lines) {
        sb
          ..write(l)
          ..write('\n');
      }
      ev.add(utf8.encode(sb.toString()));
      eventCount += lines.length;
      await ev.flush();
    }, pageSize: pageSize);
  } finally {
    await ev.close();
  }
  final IOSink st = File(serverTimesPath).openWrite();
  try {
    st.write('{');
    bool first = true;
    await srsForEachServerTimePage(select, profileUid, (
      List<(String, int)> page,
    ) async {
      await checkStop();
      final StringBuffer sb = StringBuffer();
      for (final (String eventId, int s) in page) {
        if (!first) sb.write(',');
        first = false;
        sb
          ..write(jsonEncode(eventId))
          ..write(':')
          ..write(s);
      }
      st.write(sb.toString());
      await st.flush();
    }, pageSize: pageSize);
    st.write('}');
  } finally {
    await st.close();
  }
  return (
    eventCount: eventCount,
    counts: await srsBackupCounts(select, profileUid),
  );
}

/// 读快照时被叫停（宿主要用数据库 / 界面）。
class SrsSnapshotCancelled implements Exception {
  const SrsSnapshotCancelled();

  @override
  String toString() => 'SrsSnapshotCancelled';
}

/// 后台 isolate 里的快照读取：独立只读连接、一个读事务（[SrsReadSession]），读完写两个暂存文件。
///
/// [start] 在读事务**已经拿到快照**之后才返回：调用方在写锁里调它，锁一放开写连接上的新写入
/// 都不在这份快照里（与锁里取的变化指纹一致）。之后读取全在后台，写连接与界面 isolate 都不等它。
class SrsBackupSnapshotReader {
  SrsBackupSnapshotReader._(this._control, this._done);

  final SendPort _control;
  final Future<({int eventCount, SrsBackupCounts counts})> _done;

  /// 读完：事件条数与计数。叫停时抛 [SrsSnapshotCancelled]，读失败时抛原错误（文本）。
  Future<({int eventCount, SrsBackupCounts counts})> get done => _done;

  /// 叫停：后台读完当前页就停，[done] 抛 [SrsSnapshotCancelled]（会话在后台退出后结束）。
  void cancel() => _control.send('cancel');

  /// [shouldStop] 后台每读完一页就在本 isolate 问一次（与在同一条连接上读时同一粒度），为 true 时叫停。
  static Future<SrsBackupSnapshotReader> start({
    required SrsCore core,
    required String profileUid,
    required String eventsPath,
    required String serverTimesPath,
    bool Function()? shouldStop,
    @visibleForTesting int pageSize = 2000,
  }) async {
    // 快照在这里（调用方的写锁里）定下；后台 isolate 只借用这个会话，会话由本 isolate 在后台
    // 退出后结束（不论读完、叫停还是出错）。
    final SrsReadSession session = core.beginRead();
    final ReceivePort port = ReceivePort();
    final Completer<SendPort> ready = Completer<SendPort>();
    final Completer<({int eventCount, SrsBackupCounts counts})> done =
        Completer<({int eventCount, SrsBackupCounts counts})>();
    // 后台还没起来就失败时调用方拿不到 [done]（错误经 [start] 抛出），别让它成为未处理的异步错误。
    done.future.ignore();
    void fail(Object error) {
      if (!ready.isCompleted) ready.completeError(error);
      if (!done.isCompleted) done.completeError(error);
    }

    SendPort? reply;
    port.listen((Object? m) {
      if (m is SendPort) {
        reply = m;
        ready.complete(m);
      } else if (m == 'page') {
        // 后台读完一页、等着回话：这里问叫停与否（读库在后台，这一问不碰库）。
        reply?.send((shouldStop?.call() ?? false) ? 'cancel' : 'go');
      } else if (m is List && m.isNotEmpty && m.first == 'done') {
        done.complete((
          eventCount: m[1] as int,
          counts: (
            notes: m[2] as int,
            cards: m[3] as int,
            reviews: m[4] as int,
          ),
        ));
      } else if (m == 'cancelled') {
        fail(const SrsSnapshotCancelled());
      } else if (m is List && m.isNotEmpty && m.first == 'error') {
        fail(StateError('SRS backup snapshot: ${m[1]}\n${m[2]}'));
      } else if (m == null) {
        // onExit：后台已经不再用会话了，这里才结束它。没回报就退出 = 被杀 / 崩溃。
        session.close();
        port.close();
        fail(StateError('SRS backup snapshot isolate exited'));
      }
    });
    try {
      await Isolate.spawn<List<Object?>>(_main, <Object?>[
        port.sendPort,
        session.address,
        core.libraryPath,
        profileUid,
        eventsPath,
        serverTimesPath,
        pageSize,
      ], onExit: port.sendPort);
    } catch (_) {
      session.close();
      port.close();
      rethrow;
    }
    final SendPort control = await ready.future;
    return SrsBackupSnapshotReader._(control, done.future);
  }

  static Future<void> _main(List<Object?> args) async {
    final SendPort out = args[0]! as SendPort;
    final SrsReadSession session = SrsReadSession.fromAddress(
      args[1]! as int,
      libraryPath: args[2] as String?,
    );
    final String profileUid = args[3]! as String;
    final ReceivePort control = ReceivePort();
    bool cancelled = false;
    Completer<void>? waiting;
    control.listen((Object? m) {
      if (m == 'cancel') cancelled = true;
      if (m == 'cancel' || m == 'go') waiting?.complete();
    });
    out.send(control.sendPort);
    try {
      Future<List<Map<String, Object?>>> select(
        String sql,
        List<Object?> params,
      ) async => session.query(sql, params);
      final ({int eventCount, SrsBackupCounts counts}) r =
          await srsWriteSnapshotFiles(
            select,
            profileUid,
            eventsPath: args[4]! as String,
            serverTimesPath: args[5]! as String,
            pageSize: args[6]! as int,
            checkStop: () async {
              // 每页问一次调用方要不要停（[start] 的 shouldStop），等它回话；外部的 [cancel] 也在这里生效。
              if (cancelled) throw const SrsSnapshotCancelled();
              final Completer<void> reply = waiting = Completer<void>();
              out.send('page');
              await reply.future;
              waiting = null;
              if (cancelled) throw const SrsSnapshotCancelled();
            },
          );
      out.send(<Object?>[
        'done',
        r.eventCount,
        r.counts.notes,
        r.counts.cards,
        r.counts.reviews,
      ]);
    } on SrsSnapshotCancelled {
      out.send('cancelled');
    } catch (e, stack) {
      out.send(<Object?>['error', '$e', '$stack']);
    } finally {
      control.close();
    }
  }
}
