/// 卡片浏览的按需读取：列表只装笔记缓存行 + 卡片缓存行（显示 / 排序 / 搜索的数值列），
/// 笔记的字段原文与「最后改动时刻」不常驻，搜索 / 排序真用到时才分块读、分块物化。
///
/// 以前浏览页一打开就 [SrsDbStore.allNoteViews]：全部笔记的全部修改记录（含字段全文、寄存器、
/// 因果上下文）整表解析进 Dart 堆，再加整张发布元信息表（服务器时刻）做生效值选取。
library;

import 'dart:convert';
import 'dart:math';

import 'package:drift/drift.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_srs/fushi_srs.dart';

import 'package:fushi_engine/srs/srs_db_store.dart';

/// 浏览列表的一条笔记：只有笔记缓存（`srs_notes_cache`）里的列，不带字段原文与修改记录。
///
/// 字段值经 [SrsDbStoreBrowseQueries.browseNoteFieldValues] 按需取；最后改动时刻经
/// [SrsDbStoreBrowseQueries.browseNoteModifiedAt] 按需算好后填进 [loadedModifiedAt]。
class SrsBrowseNoteHeader {
  SrsBrowseNoteHeader({
    required this.id,
    required this.noteTypeId,
    required this.createdAt,
    required this.sortField,
    required this.tags,
    required this.hasPendingDecision,
  });

  final String id;
  final String noteTypeId;
  final int createdAt;

  /// 排序字段（笔记类型第一个字段）去 HTML、trim 后的文本；缓存里截到前 200 个码元。
  final String sortField;
  final List<String> tags;

  /// 内容类待裁决（字段并发冲突 / 删除与并发修改），同 [SrsNoteView.hasPendingDecision]。
  final bool hasPendingDecision;

  /// 最后改动时刻（[srsEditsModifiedAt]）；没取过为 null。
  int? loadedModifiedAt;
}

/// 一组修改记录里最后一次改动的时刻：全部字段键当前生效记录里 HLC 物理时刻最大的一条；
/// 没有记录 = [createdAt]。
int srsEditsModifiedAt(int createdAt, SrsEntityEdits edits) {
  int out = createdAt;
  for (final SrsRegister r in edits.registers) {
    final SrsFieldEdit? w = r.winner;
    if (w != null && w.hlc.physical > out) out = w.hlc.physical;
  }
  return out;
}

const int _chunk = 500;

/// 浏览页专用的分块读取。
extension SrsDbStoreBrowseQueries on SrsDbStore {
  /// 未删除笔记的缓存行（不读修改记录）。
  Future<List<SrsBrowseNoteHeader>> browseNoteHeaders() async {
    final List<QueryRow> rows = await db
        .customSelect(
          'SELECT id, note_type_id, created_at, sort_field, tags_json, '
          'pending_decision FROM srs_notes_cache '
          'WHERE profile_uid = ? AND deleted_at IS NULL',
          variables: <Variable<Object>>[Variable<String>(profileUid)],
        )
        .get();
    return <SrsBrowseNoteHeader>[
      for (final QueryRow r in rows)
        SrsBrowseNoteHeader(
          id: r.read<String>('id'),
          noteTypeId: r.read<String>('note_type_id'),
          createdAt: r.read<int>('created_at'),
          sortField: r.read<String>('sort_field'),
          tags: _tags(r.read<String>('tags_json')),
          hasPendingDecision: r.read<bool>('pending_decision'),
        ),
    ];
  }

  /// 可见（未隐藏）卡片的缓存行。
  Future<List<SrsCardCacheRow>> browseCardRows() =>
      (db.select(db.srsCardsCache)..where(
            (c) => c.profileUid.equals(profileUid) & c.hidden.equals(false),
          ))
          .get();

  /// [notes]（`(笔记 id, 创建时刻)`）各自最后一次改动的时刻（与 [SrsNoteView] 物化后
  /// [srsEditsModifiedAt] 同值）。按块读修改记录、按块物化寄存器，读完即丢。
  Future<Map<String, int>> browseNoteModifiedAt(
    List<(String, int)> notes,
  ) async {
    final Map<String, int> out = <String, int>{};
    for (int i = 0; i < notes.length; i += _chunk) {
      final List<(String, int)> chunk = notes.sublist(
        i,
        min(i + _chunk, notes.length),
      );
      final Map<String, SrsEntityEdits> edits = await _noteEdits(<String>[
        for (final (String id, int _) in chunk) id,
      ]);
      for (final (String id, int createdAt) in chunk) {
        final SrsEntityEdits? e = edits[id];
        out[id] = e == null ? createdAt : srsEditsModifiedAt(createdAt, e);
      }
    }
    return out;
  }

  /// [noteIds] 各自 [fieldIds] 字段的当前生效原文（与 [SrsNoteView.field] 同值；没有记录的字段
  /// 不出现在结果里，读出时当空串）。只读这几个字段键的修改记录，按块物化。
  Future<Map<String, Map<String, String>>> browseNoteFieldValues(
    List<String> noteIds,
    Set<String> fieldIds,
  ) async {
    final Map<String, Map<String, String>> out =
        <String, Map<String, String>>{};
    if (fieldIds.isEmpty) return out;
    final List<String> keys = <String>[
      for (final String f in fieldIds) SrsFieldKeys.noteField(f),
    ];
    for (int i = 0; i < noteIds.length; i += _chunk) {
      final Map<String, SrsEntityEdits> edits = await _noteEdits(
        noteIds.sublist(i, min(i + _chunk, noteIds.length)),
        fieldKeys: keys,
      );
      for (final MapEntry<String, SrsEntityEdits> e in edits.entries) {
        final Map<String, String> values = <String, String>{};
        for (final String key in e.value.keys) {
          final Object? v = e.value.value(key);
          values[key.substring(2)] = v is String ? v : '';
        }
        out[e.key] = values;
      }
    }
    return out;
  }

  /// 一块笔记（≤ [_chunk] 条）的修改记录按笔记物化成寄存器；[fieldKeys] 非空时只读这些字段键。
  /// 生效值选取要的服务器时刻只查这些记录的（不读整张发布元信息表）。
  Future<Map<String, SrsEntityEdits>> _noteEdits(
    List<String> noteIds, {
    List<String> fieldKeys = const <String>[],
  }) async {
    if (noteIds.isEmpty) return const <String, SrsEntityEdits>{};
    String marks(int n) => List<String>.filled(n, '?').join(', ');
    final List<QueryRow> rows = await db
        .customSelect(
          'SELECT entity_id, json FROM srs_field_edits '
          'WHERE profile_uid = ? AND entity_kind = ? '
          'AND entity_id IN (${marks(noteIds.length)})'
          '${fieldKeys.isEmpty ? '' : ' AND field_key IN (${marks(fieldKeys.length)})'}',
          variables: <Variable<Object>>[
            Variable<String>(profileUid),
            Variable<String>(SrsEntityKind.note.wire),
            for (final String id in noteIds) Variable<String>(id),
            for (final String k in fieldKeys) Variable<String>(k),
          ],
        )
        .get();
    final Map<String, List<SrsFieldEdit>> byNote =
        <String, List<SrsFieldEdit>>{};
    final List<String> editIds = <String>[];
    for (final QueryRow r in rows) {
      final SrsFieldEdit e = SrsFieldEdit.fromJson(
        (jsonDecode(r.read<String>('json')) as Map).cast<String, Object?>(),
      );
      (byNote[r.read<String>('entity_id')] ??= <SrsFieldEdit>[]).add(e);
      editIds.add(e.id);
    }
    final Map<String, int> serverTimes = <String, int>{};
    for (int i = 0; i < editIds.length; i += _chunk) {
      final List<String> chunk = editIds.sublist(
        i,
        min(i + _chunk, editIds.length),
      );
      for (final QueryRow r
          in await db
              .customSelect(
                'SELECT event_id, server_time FROM srs_event_local '
                'WHERE server_time IS NOT NULL '
                'AND event_id IN (${marks(chunk.length)})',
                variables: <Variable<Object>>[
                  for (final String id in chunk) Variable<String>(id),
                ],
              )
              .get()) {
        serverTimes[r.read<String>('event_id')] = r.read<int>('server_time');
      }
    }
    return <String, SrsEntityEdits>{
      for (final MapEntry<String, List<SrsFieldEdit>> e in byNote.entries)
        e.key: SrsEntityEdits.build(
          e.value,
          serverTimeOf: (String id) => serverTimes[id],
        ),
    };
  }
}

List<String> _tags(String json) {
  final Object? v = jsonDecode(json);
  return v is List ? v.whereType<String>().toList() : <String>[];
}
