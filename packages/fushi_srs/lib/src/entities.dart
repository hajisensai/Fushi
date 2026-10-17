/// 实体的不可变身份记录与物化视图。
///
/// 同步的数据只有三种事件：身份记录（牌组 / 笔记类型 / 笔记的不可变部分）、修改记录（全部可编辑字段）、
/// 复习日志。卡片行不同步：由笔记 + 模板 + clozeOrd 确定性派生（铁律 D），它的可编辑字段（暂停、埋卡、
/// 旗标、牌组）是以 cardId 为实体的修改记录。
library;

import 'field_edit.dart';
import 'source_ref.dart';

/// 身份记录：创建即不可变，同 ID 内容必须相同。
class SrsEntityRecord {
  const SrsEntityRecord({
    required this.id,
    required this.profileUid,
    required this.kind,
    required this.payload,
  });

  final String id;
  final String profileUid;
  final SrsEntityKind kind;

  /// deck: {createdAt, builtin?}；notetype: {ankiNum, ntKind, createdAt, builtin?}；
  /// note: {noteTypeId, guid, createdAt}。
  final Map<String, Object?> payload;

  int get createdAt => (payload['createdAt'] as int?) ?? 0;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'p': profileUid,
    'k': kind.wire,
    'd': payload,
  };

  static SrsEntityRecord fromJson(Map<String, Object?> json) {
    final SrsEntityKind? kind = SrsEntityKind.tryParse(json['k'] as String?);
    if (kind == null) throw FormatException('unknown entity kind ${json['k']}');
    final Object? d = json['d'];
    return SrsEntityRecord(
      id: json['id']! as String,
      profileUid: json['p']! as String,
      kind: kind,
      payload: d is Map ? d.cast<String, Object?>() : const <String, Object?>{},
    );
  }

  String canonical() => srsCanonicalJson(toJson());

  /// 同 ID 异内容（只可能是 bug 或数据损坏）：取规范编码较小的一份，确定性。
  static SrsEntityRecord pick(SrsEntityRecord a, SrsEntityRecord b) =>
      a.canonical().compareTo(b.canonical()) <= 0 ? a : b;
}

/// 笔记类型种类。
abstract final class SrsNoteTypeKind {
  static const String standard = 'standard';
  static const String cloze = 'cloze';
}

/// 字段定义（笔记类型里一项，按 fieldId 逐项合并）。
class SrsFieldDef {
  const SrsFieldDef({
    required this.id,
    required this.name,
    required this.ord,
    this.ankiNum,
    this.deleted = false,
  });

  final String id;
  final String name;
  final int ord;

  /// Anki 的 Field.Config.id。按名字回退生成的字段后来带上 ankiNum 时，只把它记在这里当别名，ID 不换。
  final int? ankiNum;
  final bool deleted;

  SrsFieldDef copyWith({String? name, int? ord, bool? deleted}) => SrsFieldDef(
    id: id,
    name: name ?? this.name,
    ord: ord ?? this.ord,
    ankiNum: ankiNum,
    deleted: deleted ?? this.deleted,
  );

  Map<String, Object?> toValue() => <String, Object?>{
    'name': name,
    'ord': ord,
    if (ankiNum != null) 'ankiNum': ankiNum,
    if (deleted) 'deleted': true,
  };

  static SrsFieldDef fromValue(String id, Object? v) {
    final Map<Object?, Object?> m = v is Map ? v : const <Object?, Object?>{};
    return SrsFieldDef(
      id: id,
      name: (m['name'] as String?) ?? '',
      ord: (m['ord'] as int?) ?? 0,
      ankiNum: m['ankiNum'] as int?,
      deleted: m['deleted'] == true,
    );
  }
}

/// 卡面模板定义。正文按 fieldId 存引用（`{{fld:<fieldId>}}`）。
class SrsTemplateDef {
  const SrsTemplateDef({
    required this.id,
    required this.name,
    required this.ord,
    required this.front,
    required this.back,
    this.ankiNum,
    this.deleted = false,
  });

  final String id;
  final String name;
  final int ord;
  final String front;
  final String back;
  final int? ankiNum;
  final bool deleted;

  SrsTemplateDef copyWith({
    String? name,
    int? ord,
    String? front,
    String? back,
    bool? deleted,
  }) => SrsTemplateDef(
    id: id,
    name: name ?? this.name,
    ord: ord ?? this.ord,
    front: front ?? this.front,
    back: back ?? this.back,
    ankiNum: ankiNum,
    deleted: deleted ?? this.deleted,
  );

  Map<String, Object?> toValue() => <String, Object?>{
    'name': name,
    'ord': ord,
    'front': front,
    'back': back,
    if (ankiNum != null) 'ankiNum': ankiNum,
    if (deleted) 'deleted': true,
  };

  static SrsTemplateDef fromValue(String id, Object? v) {
    final Map<Object?, Object?> m = v is Map ? v : const <Object?, Object?>{};
    return SrsTemplateDef(
      id: id,
      name: (m['name'] as String?) ?? '',
      ord: (m['ord'] as int?) ?? 0,
      front: (m['front'] as String?) ?? '',
      back: (m['back'] as String?) ?? '',
      ankiNum: m['ankiNum'] as int?,
      deleted: m['deleted'] == true,
    );
  }
}

/// 内置笔记类型的代码默认值（第六轮审查第 8 条：内置模板版本化）。
///
/// 用户没改过的内置定义**不写修改记录**，直接跟随代码（升级后模板自动更新，每台设备也不会各写一份）；
/// 用户改过某一项之后，这一项才由修改记录决定，成为普通内容。
class SrsBuiltinNoteType {
  const SrsBuiltinNoteType({
    required this.key,
    required this.name,
    required this.kind,
    required this.fields,
    required this.templates,
    required this.css,
    this.termFieldId,
  });

  final String key;
  final String name;
  final String kind;
  final List<SrsFieldDef> fields;
  final List<SrsTemplateDef> templates;
  final String css;
  final String? termFieldId;
}

/// 带冲突信息的字段值。
class SrsMergedValue<T> {
  const SrsMergedValue(this.value, this.register);

  final T value;

  /// 这个字段键的寄存器（无记录时为 null）。
  final SrsRegister? register;

  bool get conflicted => register?.conflicted ?? false;
}

/// 一组修改记录按字段键分好的寄存器（同一个实体）。
class SrsEntityEdits {
  SrsEntityEdits(Map<String, SrsRegister> registers) : _r = registers;

  final Map<String, SrsRegister> _r;

  SrsRegister? operator [](String key) => _r[key];

  Iterable<String> get keys => _r.keys;

  Iterable<SrsRegister> get registers => _r.values;

  Object? value(String key) => _r[key]?.value;

  int? get deletedAt {
    final SrsRegister? d = _r[SrsFieldKeys.deleted];
    return d == null ? null : srsEffectiveDeletedAt(d);
  }

  /// 有冲突的寄存器。
  Iterable<SrsRegister> get conflicted =>
      _r.values.where((SrsRegister r) => r.conflicted);

  /// 由一个实体的全部修改记录构造。
  static SrsEntityEdits build(
    Iterable<SrsFieldEdit> edits, {
    int? Function(String eventId)? serverTimeOf,
  }) {
    final Map<String, List<SrsFieldEdit>> byKey =
        <String, List<SrsFieldEdit>>{};
    for (final SrsFieldEdit e in edits) {
      (byKey[e.fieldKey] ??= <SrsFieldEdit>[]).add(e);
    }
    return SrsEntityEdits(<String, SrsRegister>{
      for (final MapEntry<String, List<SrsFieldEdit>> e in byKey.entries)
        e.key: srsResolveRegister(e.key, e.value, serverTimeOf: serverTimeOf),
    });
  }
}

/// 物化后的笔记类型。
class SrsNoteTypeView {
  SrsNoteTypeView({
    required this.id,
    required this.ankiNum,
    required this.kind,
    required this.name,
    required this.fields,
    required this.templates,
    required this.css,
    required this.termFieldId,
    required this.deletedAt,
    required this.builtinKey,
    required this.edits,
  });

  final String id;
  final int ankiNum;
  final String kind;
  final String name;

  /// 未删除的字段，按 ord 排。
  final List<SrsFieldDef> fields;

  /// 未删除的模板，按 ord 排。
  final List<SrsTemplateDef> templates;
  final String css;
  final String? termFieldId;
  final int? deletedAt;
  final String? builtinKey;
  final SrsEntityEdits edits;

  bool get isCloze => kind == SrsNoteTypeKind.cloze;

  SrsFieldDef? fieldById(String id) {
    for (final SrsFieldDef f in fields) {
      if (f.id == id) return f;
    }
    return null;
  }

  static SrsNoteTypeView materialize(
    SrsEntityRecord record,
    SrsEntityEdits edits, {
    SrsBuiltinNoteType? builtin,
  }) {
    final Map<String, SrsFieldDef> fields = <String, SrsFieldDef>{
      if (builtin != null)
        for (final SrsFieldDef f in builtin.fields) f.id: f,
    };
    final Map<String, SrsTemplateDef> templates = <String, SrsTemplateDef>{
      if (builtin != null)
        for (final SrsTemplateDef t in builtin.templates) t.id: t,
    };
    for (final String key in edits.keys) {
      if (key.startsWith('fieldDef/')) {
        final String id = key.substring('fieldDef/'.length);
        fields[id] = SrsFieldDef.fromValue(id, edits.value(key));
      } else if (key.startsWith('tmplDef/')) {
        final String id = key.substring('tmplDef/'.length);
        templates[id] = SrsTemplateDef.fromValue(id, edits.value(key));
      }
    }
    int byOrd(dynamic a, dynamic b) {
      final int c = (a.ord as int).compareTo(b.ord as int);
      return c != 0 ? c : (a.id as String).compareTo(b.id as String);
    }

    return SrsNoteTypeView(
      id: record.id,
      ankiNum: (record.payload['ankiNum'] as int?) ?? 0,
      kind: (record.payload['ntKind'] as String?) ?? SrsNoteTypeKind.standard,
      name: (edits.value(SrsFieldKeys.name) as String?) ?? builtin?.name ?? '',
      fields: fields.values.where((SrsFieldDef f) => !f.deleted).toList()
        ..sort(byOrd),
      templates:
          templates.values.where((SrsTemplateDef t) => !t.deleted).toList()
            ..sort(byOrd),
      css: (edits.value(SrsFieldKeys.css) as String?) ?? builtin?.css ?? '',
      termFieldId:
          (edits.value(SrsFieldKeys.termField) as String?) ??
          builtin?.termFieldId,
      deletedAt: edits.deletedAt,
      builtinKey: record.payload['builtin'] as String?,
      edits: edits,
    );
  }
}

/// 物化后的笔记。
class SrsNoteView {
  SrsNoteView({
    required this.id,
    required this.noteTypeId,
    required this.guid,
    required this.createdAt,
    required this.fields,
    required this.tags,
    required this.source,
    required this.deckId,
    required this.deletedAt,
    required this.edits,
  });

  final String id;

  /// 当前笔记类型：「更改笔记类型」的修改记录优先，没有时取身份记录里的创建类型。
  final String noteTypeId;
  final String guid;
  final int createdAt;

  /// fieldId → 值（没有修改记录的字段读出来当空值，不回填）。
  final Map<String, String> fields;
  final List<String> tags;
  final SrsSourceRef? source;

  /// 首选牌组：按需生成的卡片的初始 deckId（第六轮审查第 14 条）。
  final String? deckId;
  final int? deletedAt;
  final SrsEntityEdits edits;

  /// 内容类待裁决（字段值并发冲突，或删除与并发修改）。
  bool get hasPendingDecision {
    if (edits.conflicted.isNotEmpty) return true;
    final SrsRegister? del = edits[SrsFieldKeys.deleted];
    if (del == null || deletedAt == null) return false;
    final List<SrsFieldEdit> content = <SrsFieldEdit>[
      for (final SrsRegister r in edits.registers)
        if (r.key != SrsFieldKeys.deleted) ...r.live,
    ];
    return srsEditsConcurrentWithDelete(del, content).isNotEmpty;
  }

  String field(String fieldId) => fields[fieldId] ?? '';

  static SrsNoteView materialize(SrsEntityRecord record, SrsEntityEdits edits) {
    final Map<String, String> fields = <String, String>{};
    for (final String key in edits.keys) {
      if (key.startsWith('f/')) {
        final Object? v = edits.value(key);
        fields[key.substring(2)] = v is String ? v : '';
      }
    }
    final Object? tags = edits.value(SrsFieldKeys.noteTags);
    return SrsNoteView(
      id: record.id,
      noteTypeId:
          (edits.value(SrsFieldKeys.noteType) as String?) ??
          record.payload['noteTypeId']! as String,
      guid: record.payload['guid']! as String,
      createdAt: record.createdAt,
      fields: fields,
      tags: tags is List ? tags.whereType<String>().toList() : <String>[],
      source: SrsSourceRef.fromJson(edits.value(SrsFieldKeys.noteSource)),
      deckId: edits.value(SrsFieldKeys.noteDeck) as String?,
      deletedAt: edits.deletedAt,
      edits: edits,
    );
  }
}

/// 卡片的可编辑字段（不含排程：排程只来自日志）。
class SrsCardFlags {
  const SrsCardFlags({
    required this.deckId,
    required this.suspended,
    required this.buriedUntilDay,
    required this.flag,
  });

  final String deckId;
  final bool suspended;
  final int? buriedUntilDay;
  final int flag;

  /// [noteDeckId] 是笔记的首选牌组；卡片没有自己的 deck 修改记录时用它，再没有就用 [fallbackDeckId]（默认牌组）。
  /// 卡片的生成本身不写任何记录：两台设备各自为新模板生成同一张卡，初始 deckId 确定性相同。
  static SrsCardFlags materialize(
    SrsEntityEdits edits, {
    required String? noteDeckId,
    required String fallbackDeckId,
  }) => SrsCardFlags(
    deckId:
        (edits.value(SrsFieldKeys.cardDeck) as String?) ??
        noteDeckId ??
        fallbackDeckId,
    suspended: edits.value(SrsFieldKeys.suspended) == true,
    buriedUntilDay: edits.value(SrsFieldKeys.buriedUntilDay) as int?,
    flag: (edits.value(SrsFieldKeys.flag) as int?) ?? 0,
  );
}
