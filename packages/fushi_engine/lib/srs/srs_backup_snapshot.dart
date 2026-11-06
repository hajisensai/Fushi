/// SRS 事件的分页读取：全部事件的规范行（整 app 备份合并、测试比对用）与库内计数。
///
/// 读法与连接无关（[SrsSqlSelect]）。旧版定时备份的后台快照读取已随同步 v2 删除（设计 §10：时间线 + 归档 +
/// 手动导出取代）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:fushi_srs/fushi_srs.dart';

/// 一条只读查询：`?` 占位，结果每行一个列名 → 值的表。
typedef SrsSqlSelect =
    Future<List<Map<String, Object?>>> Function(String sql, List<Object?> args);

/// 绑定给 ID 列的参数（srs.db 里 ID 列存编码值，绑定要走 `srsIdType`）：[SrsSqlSelect] 的实现遇到它
/// 按 ID 绑定，其它 String 照原样。
class SrsId {
  const SrsId(this.value);
  final String value;
}

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
    <Object?>[SrsId(profileUid)],
  );
  final int cards = await count(
    'SELECT COUNT(*) AS c FROM srs_cards_cache '
    'WHERE profile_uid = ? AND hidden = 0',
    <Object?>[SrsId(profileUid)],
  );
  // 有效复习 = 有评分的 review 日志里没被 undo 撤销的。只解码 undo 日志（通常很少）拿被撤销的 ID，
  // 其余全用计数查询，不把整张日志表读进内存。
  final Set<String> revoked = <String>{};
  for (final Map<String, Object?> r in await select(
    'SELECT json FROM srs_review_logs WHERE profile_uid = ? AND kind = ?',
    <Object?>[SrsId(profileUid), SrsLogKind.undo],
  )) {
    final Object? target = (jsonDecode(r['json']! as String) as Map)['revokes'];
    if (target is String) revoked.add(target);
  }
  const String validReview =
      'profile_uid = ? AND kind = ? AND rating IS NOT NULL';
  int reviews = await count(
    'SELECT COUNT(*) AS c FROM srs_review_logs WHERE $validReview',
    <Object?>[SrsId(profileUid), SrsLogKind.review],
  );
  final List<String> ids = revoked.toList();
  for (int i = 0; i < ids.length; i += 500) {
    final List<String> chunk = ids.sublist(i, min(i + 500, ids.length));
    reviews -= await count(
      'SELECT COUNT(*) AS c FROM srs_review_logs '
      'WHERE $validReview AND id IN '
      '(${List<String>.filled(chunk.length, '?').join(',')})',
      <Object?>[
        SrsId(profileUid),
        SrsLogKind.review,
        for (final String c in chunk) SrsId(c),
      ],
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
      <Object?>[SrsId(profileUid), after, pageSize],
    );
    if (rows.isEmpty) return;
    await onPage(rows);
    if (rows.length < pageSize) return;
    after = rows.last['rid_']! as int;
  }
}
