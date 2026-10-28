/// 实体的不可变身份记录与物化视图。
///
/// 同步的数据只有三种事件：身份记录（牌组 / 笔记类型 / 笔记的不可变部分）、修改记录（全部可编辑字段）、
/// 复习日志。卡片行不同步：由笔记 + 模板 + clozeOrd 确定性派生（铁律 D），它的可编辑字段（暂停、埋卡、
/// 旗标、牌组）是以 cardId 为实体的修改记录。
library;

import 'field_edit.dart';
import 'register_kernel.dart';
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
    this.description = '',
    this.deleted = false,
  });

  final String id;
  final String name;
  final int ord;

  /// Anki 的 Field.Config.id。按名字回退生成的字段后来带上 ankiNum 时，只把它记在这里当别名，ID 不换。
  final int? ankiNum;

  /// 用户写的字段说明（这个字段装什么、在卡面哪里出现）；空串 = 没写。对应 Anki 的
  /// Field.Config.description。
  ///
  /// **不在字段定义的值里**（[toValue] 不写它）：说明是独立的修改记录键
  /// [SrsFieldKeys.fieldDescription]，物化时并进来。分开存是为了改名 / 调序与改说明互不
  /// 冲突，也让不认识说明的旧版本改名时不会把它抹掉。
  final String description;
  final bool deleted;

  SrsFieldDef copyWith({
    String? name,
    int? ord,
    String? description,
    bool? deleted,
  }) => SrsFieldDef(
    id: id,
    name: name ?? this.name,
    ord: ord ?? this.ord,
    ankiNum: ankiNum,
    description: description ?? this.description,
    deleted: deleted ?? this.deleted,
  );

  Map<String, Object?> toValue() => <String, Object?>{
    'name': name,
    'ord': ord,
    if (ankiNum != null) 'ankiNum': ankiNum,
    if (deleted) 'deleted': true,
  };
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
    this.freqFieldId,
  });

  final String key;
  final String name;
  final String kind;
  final List<SrsFieldDef> fields;
  final List<SrsTemplateDef> templates;
  final String css;
  final String? termFieldId;
  final String? freqFieldId;
}

/// 带冲突信息的字段值。
class SrsMergedValue<T> {
  const SrsMergedValue(this.value, this.register);

  final T value;

  /// 这个字段键的寄存器（无记录时为 null）。
  final SrsRegister? register;

  bool get conflicted => register?.conflicted ?? false;
}

/// 一组修改记录按字段键分好的寄存器（同一个实体；原生内核的结果视图，见 register_kernel.dart）。
class SrsEntityEdits {
  SrsEntityEdits(
    Map<String, SrsRegister> registers, {
    this.deletedAt,
    List<SrsFieldEdit> Function()? concurrentWithDelete,
  }) : _r = registers,
       _concurrent = concurrentWithDelete;

  /// 没有任何记录。
  factory SrsEntityEdits.empty() => SrsEntityEdits(<String, SrsRegister>{});

  final Map<String, SrsRegister> _r;
  final List<SrsFieldEdit> Function()? _concurrent;

  SrsRegister? operator [](String key) => _r[key];

  /// 字段键，按首次出现的顺序。
  Iterable<String> get keys => _r.keys;

  Iterable<SrsRegister> get registers => _r.values;

  Object? value(String key) => _r[key]?.value;

  /// 删除优先：删除寄存器里只要有一条没被支配的记录值是整数，行就是已删（取 sortKey 最大的那条）；
  /// 未删为 null。
  final int? deletedAt;

  /// 与删除记录并发（谁也没看见谁）的内容修改：删除优先，但这些修改留在行里，作为内容类待裁决项
  /// 「另一台设备删除了这条笔记，这里有未同步的修改：恢复 / 确认删除」。
  List<SrsFieldEdit> get concurrentWithDelete =>
      _concurrent?.call() ?? const <SrsFieldEdit>[];

  /// 有冲突的寄存器。
  Iterable<SrsRegister> get conflicted =>
      _r.values.where((SrsRegister r) => r.conflicted);

  /// 由一个实体的全部修改记录构造（一次 FFI 调用）。
  static SrsEntityEdits build(
    Iterable<SrsFieldEdit> edits, {
    int? Function(String eventId)? serverTimeOf,
  }) => buildMany(<List<SrsFieldEdit>>[
    edits.toList(),
  ], serverTimeOf: serverTimeOf).single;

  /// 一批实体各自的寄存器，与输入同序；整批一次 FFI 调用。
  static List<SrsEntityEdits> buildMany(
    List<List<SrsFieldEdit>> entities, {
    int? Function(String eventId)? serverTimeOf,
  }) => srsEntityEditsOf(<List<SrsEditItem>>[
    for (final List<SrsFieldEdit> edits in entities)
      <SrsEditItem>[
        for (final SrsFieldEdit e in edits)
          SrsEditItem.of(e, serverTimeOf?.call(e.id)),
      ],
  ]);
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
    this.freqFieldId,
    this.definedFields = const <SrsFieldDef>[],
    this.definedTemplates = const <SrsTemplateDef>[],
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

  /// 显式设的词频序字段（[SrsFieldKeys.freqField]，内置类型有代码默认）；null = 没设。
  /// 实际取哪个字段看 [frequencyField]。
  final String? freqFieldId;
  final int? deletedAt;
  final String? builtinKey;
  final SrsEntityEdits edits;

  /// 有定义的全部字段：未删除的物化结果，再按记录顺序用每条字段定义修改记录本身覆盖（含已删除的；
  /// 来自记录的项不带说明）。Anki 导入按它解析来源字段对应的本机 ID。
  final List<SrsFieldDef> definedFields;

  /// 同 [definedFields]，模板。
  final List<SrsTemplateDef> definedTemplates;

  bool get isCloze => kind == SrsNoteTypeKind.cloze;

  /// 新卡按词频出卡时读名次的字段：显式设的 [freqFieldId]（字段还在时），否则名为 `FreqSort` 的字段
  /// （不分大小写——Lapis 及其衍生类型、从 Anki 导入的同类笔记都用这个名字）；都没有 = null。
  SrsFieldDef? get frequencyField {
    final String? id = freqFieldId;
    if (id != null) {
      final SrsFieldDef? f = fieldById(id);
      if (f != null) return f;
    }
    for (final SrsFieldDef f in fields) {
      if (f.name.trim().toLowerCase() == 'freqsort') return f;
    }
    return null;
  }

  SrsFieldDef? fieldById(String id) {
    for (final SrsFieldDef f in fields) {
      if (f.id == id) return f;
    }
    return null;
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
    this.hasPendingDecision = false,
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
  final bool hasPendingDecision;

  String field(String fieldId) => fields[fieldId] ?? '';
}

/// 卡片的可编辑字段（不含排程：排程只来自日志）。
class SrsCardFlags {
  const SrsCardFlags({
    required this.deckId,
    required this.suspended,
    required this.buriedUntilDay,
    required this.flag,
    this.newPosition,
  });

  final String deckId;
  final bool suspended;
  final int? buriedUntilDay;
  final int flag;

  /// 新卡出卡位置（[SrsFieldKeys.cardNewPosition]）；null = 没排过。
  final int? newPosition;
}
