/// 编辑类撤销（暂停 / 搁置 / 旗标 / 移牌组 / 改字段 / 标签 / 删除笔记 / 冲突裁决 / 合并重复……）的统一语义。
///
/// 一次可撤销的写入留下一份 [SrsEditUndo]：每个被改的字段键记「改前 / 改后」与那次写下的修改记录的 dot
/// （内核分配的设备 + 序号，`apply` 交回）。撤销（`SrsDbStore.revertEdits`）在写锁里先让内核按库里的修改记录
/// 裁决每个键（store/sync2/undo_check.rs）：
///
/// - 自那次写入以来没被别人动过（那条记录仍是唯一的现值，或之后的改动又全改回了它的值）→ 写回改前的值；
/// - 被动过（同步拉进来的别的设备的修改、AI / 别处又改过、有并发候选）→ **保留现值**，记进
///   [SrsEditUndoResult.kept] 交给调用方（界面提示、操作目录的撤销结果）。
///
/// 标签是 OR-Set，按差量撤：这次加上的标签现在还在就去掉、这次去掉的现在还没有就加回，别人之后加 / 删的标签不动，
/// 所以标签不会「撤不成」。
///
/// 撤销写下的仍是普通修改操作（走 `apply`），照常同步、照常重放。评分 / 重置 / 改期的撤销是日志撤销
/// （`SrsDbStore.undo` / `SrsDbStore.undoLogs`，内核只认最后一条有效日志），不在这里。
library;

import 'package:fushi_srs/fushi_srs.dart';

/// 一个被改过的字段键。
class SrsEditUndoItem {
  const SrsEditUndoItem({
    required this.kind,
    required this.entityId,
    required this.key,
    required this.before,
    required this.after,
    this.writer,
    this.seq,
  });

  final SrsEntityKind kind;
  final String entityId;
  final String key;

  /// 改前的生效值（写锁里从库读的物化值）；撤销写回它。
  final Object? before;

  /// 这次写下的值。有 dot 时只用于标签差量与展示；没有 dot（这一版之前记下的载荷）时内核按它比值。
  final Object? after;

  /// 那次写下的修改记录的 dot（设备 ID 文本、序号）。没落库（值没变、被扣住）或旧载荷为 null。
  final String? writer;
  final int? seq;

  bool get isTags => kind == SrsEntityKind.note && key == SrsFieldKeys.noteTags;

  SrsEditUndoItem withAfter(Object? after, {String? writer, int? seq}) =>
      SrsEditUndoItem(
        kind: kind,
        entityId: entityId,
        key: key,
        before: before,
        after: after,
        writer: writer,
        seq: seq,
      );

  Map<String, Object?> toJson() => <String, Object?>{
    'k': kind.wire,
    'e': entityId,
    'f': key,
    'b': before,
    'a': after,
    if (writer != null) 'w': writer,
    if (seq != null) 's': seq,
  };

  static SrsEditUndoItem? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final SrsEntityKind? kind = SrsEntityKind.tryParse(raw['k'] as String?);
    final Object? e = raw['e'], f = raw['f'];
    if (kind == null || e is! String || f is! String) return null;
    final Object? w = raw['w'], s = raw['s'];
    return SrsEditUndoItem(
      kind: kind,
      entityId: e,
      key: f,
      before: raw['b'],
      after: raw['a'],
      writer: w is String ? w : null,
      seq: s is int ? s : null,
    );
  }
}

/// 一次可撤销写入的撤销凭据（可 JSON 往返：浏览页撤销栈、复习页撤销栈、操作目录的撤销载荷、远程复习线格式）。
class SrsEditUndo {
  const SrsEditUndo(this.items);

  static const SrsEditUndo empty = SrsEditUndo(<SrsEditUndoItem>[]);

  final List<SrsEditUndoItem> items;

  bool get isEmpty => items.isEmpty;
  bool get isNotEmpty => items.isNotEmpty;

  /// 涉及的实体数（同一实体的几个键算一个）。
  int get entityCount => <String>{
    for (final SrsEditUndoItem i in items) '${i.kind.wire}/${i.entityId}',
  }.length;

  /// 两份按顺序拼起来（同一键以先出现的「改前」、后出现的「改后 / dot」为准）。
  SrsEditUndo merge(SrsEditUndo later) {
    final Map<String, SrsEditUndoItem> byKey = <String, SrsEditUndoItem>{};
    for (final SrsEditUndoItem i in <SrsEditUndoItem>[
      ...items,
      ...later.items,
    ]) {
      final String k = '${i.kind.wire}/${i.entityId}/${i.key}';
      final SrsEditUndoItem? first = byKey[k];
      byKey[k] = first == null
          ? i
          : first.withAfter(i.after, writer: i.writer, seq: i.seq);
    }
    return SrsEditUndo(byKey.values.toList());
  }

  List<Object?> toJson() => <Object?>[
    for (final SrsEditUndoItem i in items) i.toJson(),
  ];

  static SrsEditUndo fromJson(Object? raw) => SrsEditUndo(<SrsEditUndoItem>[
    if (raw is List)
      for (final Object? x in raw) ?SrsEditUndoItem.fromJson(x),
  ]);
}

/// 没撤成的一个字段键：之后被别人动过，保留了现值 [current]。
class SrsEditUndoKept {
  const SrsEditUndoKept({
    required this.kind,
    required this.entityId,
    required this.key,
    required this.current,
  });

  final SrsEntityKind kind;
  final String entityId;
  final String key;
  final Object? current;

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': kind.wire,
    'entity': entityId,
    'key': key,
    'current': current,
  };

  static SrsEditUndoKept? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final SrsEntityKind? kind = SrsEntityKind.tryParse(raw['kind'] as String?);
    final Object? e = raw['entity'], k = raw['key'];
    if (kind == null || e is! String || k is! String) return null;
    return SrsEditUndoKept(
      kind: kind,
      entityId: e,
      key: k,
      current: raw['current'],
    );
  }
}

/// 一次撤销的结果。
class SrsEditUndoResult {
  const SrsEditUndoResult({required this.reverted, required this.kept});

  static const SrsEditUndoResult none = SrsEditUndoResult(
    reverted: 0,
    kept: <SrsEditUndoKept>[],
  );

  /// 撤回了的字段键数。
  final int reverted;

  /// 没撤成（保留现值）的字段键。
  final List<SrsEditUndoKept> kept;

  bool get complete => kept.isEmpty;

  /// 有没撤成的字段键的实体数。
  int get keptEntities => <String>{
    for (final SrsEditUndoKept k in kept) '${k.kind.wire}/${k.entityId}',
  }.length;

  Map<String, Object?> toJson() => <String, Object?>{
    'reverted': reverted,
    'kept': <Object?>[for (final SrsEditUndoKept k in kept) k.toJson()],
  };

  static SrsEditUndoResult fromJson(Object? raw) {
    if (raw is! Map) return none;
    final Object? r = raw['reverted'];
    return SrsEditUndoResult(
      reverted: r is int ? r : 0,
      kept: <SrsEditUndoKept>[
        if (raw['kept'] case final List<Object?> xs)
          for (final Object? x in xs) ?SrsEditUndoKept.fromJson(x),
      ],
    );
  }
}
