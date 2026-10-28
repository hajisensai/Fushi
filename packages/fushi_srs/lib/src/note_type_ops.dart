/// 笔记类型的结构编辑与「更改笔记类型」（Anki 的 Change Note Type）的纯函数。
///
/// 只算「要写哪些值」，不读本机状态、不写库；落库由宿主（fushi_engine 的 SrsDbStore）
/// 按铁律 H 写成修改记录。
///
/// - 结构编辑（铁律 D）：加 / 删字段、改名、调序、加 / 删模板、改模板 / CSS 都只改笔记类型这一行，
///   每个字段定义 / 模板定义各自是一个字段键，按项合并；笔记与卡片一行都不动。
/// - 新建项的 ID（铁律 C）：ankiNum 随机，fieldId / templateId 由 noteTypeId + ankiNum 派生，
///   导出时 ankiNum 写进 Anki 的 config.id，回导回到同一个 ID。
/// - 更改笔记类型：笔记身份记录不可变，换类型写笔记的 `noteType` 键；字段值按映射写到新字段；
///   卡片 ID 由 (noteId, templateId, clozeOrd) 派生、换类型后必然是新卡，所以旧卡 → 新卡用新卡上的
///   「前身」键（`historyFrom/<旧卡>`）连起来，新卡的复习历史 = 自己 + 全部前身的日志，标志沿前身继承。
///   复习日志一条不改（创建即不可变），别的设备并发复习旧卡的日志也会自然流到新卡上。
library;

import 'entities.dart';
import 'field_edit.dart' show SrsEntityKind;
import 'ids.dart';

/// Anki 不许笔记字段用的名字（会被模板的特殊字段遮住）。与 fushi_anki 的
/// `kAnkiSpecialFieldNames` 同一份清单（fushi_srs 零依赖，这里另写一次）。
const Set<String> kSrsReservedFieldNames = <String>{
  'FrontSide',
  'Tags',
  'Type',
  'Deck',
  'Subdeck',
  'CardFlag',
  'Card',
  'CardID',
};

/// 名字校验不过的原因。
enum SrsNameProblem {
  /// 去掉首尾空白后为空。
  empty,

  /// 与同一笔记类型里的其它项重名（不区分大小写，与 Anki 一致）。
  duplicate,

  /// 字段名含 Anki 模板语法字符（`:` `{` `}` `"`）或以 `#` `/` `^` 开头。
  invalidChars,

  /// 字段名是特殊字段（FrontSide / Tags / …）。
  reserved,
}

bool _sameName(String a, String b) =>
    a.trim().toLowerCase() == b.trim().toLowerCase();

/// 字段名校验（rslib notetype/fields.rs 的同一组约束；Anki 会静默改名，这里改为提示）。
SrsNameProblem? srsValidateFieldName(String name, Iterable<String> others) {
  final String n = name.trim();
  if (n.isEmpty) return SrsNameProblem.empty;
  if (RegExp(r'[:{}"]').hasMatch(n) || RegExp(r'^[#/^]').hasMatch(n)) {
    return SrsNameProblem.invalidChars;
  }
  if (kSrsReservedFieldNames.any((String r) => _sameName(r, n))) {
    return SrsNameProblem.reserved;
  }
  if (others.any((String o) => _sameName(o, n))) {
    return SrsNameProblem.duplicate;
  }
  return null;
}

/// 模板名 / 笔记类型名校验：非空、不重名。
SrsNameProblem? srsValidatePlainName(String name, Iterable<String> others) {
  final String n = name.trim();
  if (n.isEmpty) return SrsNameProblem.empty;
  if (others.any((String o) => _sameName(o, n))) {
    return SrsNameProblem.duplicate;
  }
  return null;
}

final RegExp _handlebar = RegExp(r'\{\{[^{}]*\}\}');

/// 删字段时把模板里对它的引用一起去掉（rslib `rename_and_remove_fields`：替换直接删，
/// 条件段 `{{#字段}}…{{/字段}}` 去掉段标记、保留段内内容）。
String srsRemoveFieldRefs(String template, String fieldId) {
  final String key = 'fld:$fieldId';
  return template.replaceAllMapped(_handlebar, (Match m) {
    final String tag = m[0]!;
    final String inner = tag.substring(2, tag.length - 2).trim();
    final String bare = inner.startsWith(RegExp(r'[#^/]'))
        ? inner.substring(1).trim()
        : inner;
    // 带过滤器的替换：`{{text:fld:<id>}}` 的 key 是最后的 `fld:<id>`。
    return bare == key || bare.endsWith(':$key') ? '' : tag;
  });
}

/// 模板里按 fieldId 的引用整体换 ID（克隆笔记类型：新类型的字段是新 ID）。
String srsRewriteFieldRefs(String template, Map<String, String> oldToNew) {
  if (oldToNew.isEmpty) return template;
  return template.replaceAllMapped(_handlebar, (Match m) {
    String tag = m[0]!;
    for (final MapEntry<String, String> e in oldToNew.entries) {
      tag = tag.replaceAll('fld:${e.key}', 'fld:${e.value}');
    }
    return tag;
  });
}

/// 新建笔记类型时的一个模板（正文已经是 fieldId 引用形式）。
class SrsTemplateSpec {
  const SrsTemplateSpec({
    required this.name,
    required this.front,
    required this.back,
  });

  final String name;
  final String front;
  final String back;
}

/// 一个新建的笔记类型：身份记录 + 它的全部定义（都由宿主写成修改记录）。
class SrsNewNoteType {
  const SrsNewNoteType({
    required this.record,
    required this.name,
    required this.fields,
    required this.templates,
    required this.css,
    required this.termFieldId,
    this.freqFieldId,
  });

  final SrsEntityRecord record;
  final String name;
  final List<SrsFieldDef> fields;
  final List<SrsTemplateDef> templates;
  final String css;
  final String? termFieldId;

  /// 显式的词频序字段（[SrsFieldKeys.freqField]）；null = 不写，按字段名认。
  final String? freqFieldId;

  String get id => record.id;
}

/// Fushi 新建笔记类型的 ID 与定义（铁律 C：ankiNum 随机，其余全部由它派生）。
///
/// [templates] 的正文按**字段名**写（`{{Front}}`），由 [namesToIds] 换成 fieldId 引用；
/// [namesToIds] 由宿主传入（模板解析器在 fushi_anki 里，fushi_srs 不依赖它）。
SrsNewNoteType srsBuildNoteType({
  required String profileUid,
  required String name,
  required String kind,
  required List<String> fieldNames,
  required List<SrsTemplateSpec> templates,
  required String css,
  required String Function(String template, Map<String, String> nameToId)
  namesToIds,
  required int createdAt,
  String? termFieldName,
  int Function()? nextAnkiNum,
}) {
  final int Function() num = nextAnkiNum ?? randomAnkiNum;
  final int typeNum = num();
  final String typeId = SrsIds.noteType(profileUid, typeNum);
  final List<SrsFieldDef> fields = <SrsFieldDef>[];
  final Map<String, String> nameToId = <String, String>{};
  for (int i = 0; i < fieldNames.length; i++) {
    final int n = num();
    final SrsFieldDef f = SrsFieldDef(
      id: SrsIds.field(typeId, n),
      name: fieldNames[i].trim(),
      ord: i,
      ankiNum: n,
    );
    fields.add(f);
    nameToId[f.name] = f.id;
  }
  final List<SrsTemplateDef> tpls = <SrsTemplateDef>[
    for (int i = 0; i < templates.length; i++)
      () {
        final int n = num();
        return SrsTemplateDef(
          id: SrsIds.template(typeId, n),
          name: templates[i].name.trim(),
          ord: i,
          front: namesToIds(templates[i].front, nameToId),
          back: namesToIds(templates[i].back, nameToId),
          ankiNum: n,
        );
      }(),
  ];
  return SrsNewNoteType(
    record: SrsEntityRecord(
      id: typeId,
      profileUid: profileUid,
      kind: SrsEntityKind.noteType,
      payload: <String, Object?>{
        'ankiNum': typeNum,
        'ntKind': kind,
        'createdAt': createdAt,
      },
    ),
    name: name.trim(),
    fields: fields,
    templates: tpls,
    css: css,
    termFieldId: termFieldName == null ? null : nameToId[termFieldName],
  );
}

/// 克隆一个笔记类型（Anki「添加：克隆」）：字段 / 模板一律新 ID，模板正文里的引用跟着换；
/// 词条字段指向克隆出的对应字段。
SrsNewNoteType srsCloneNoteType({
  required String profileUid,
  required SrsNoteTypeView source,
  required String name,
  required int createdAt,
  int Function()? nextAnkiNum,
}) {
  final int Function() num = nextAnkiNum ?? randomAnkiNum;
  final int typeNum = num();
  final String typeId = SrsIds.noteType(profileUid, typeNum);
  final Map<String, String> oldToNew = <String, String>{};
  final List<SrsFieldDef> fields = <SrsFieldDef>[];
  for (int i = 0; i < source.fields.length; i++) {
    final int n = num();
    final SrsFieldDef f = SrsFieldDef(
      id: SrsIds.field(typeId, n),
      name: source.fields[i].name,
      ord: i,
      ankiNum: n,
      description: source.fields[i].description,
    );
    oldToNew[source.fields[i].id] = f.id;
    fields.add(f);
  }
  final List<SrsTemplateDef> tpls = <SrsTemplateDef>[
    for (int i = 0; i < source.templates.length; i++)
      () {
        final int n = num();
        final SrsTemplateDef s = source.templates[i];
        return SrsTemplateDef(
          id: SrsIds.template(typeId, n),
          name: s.name,
          ord: i,
          front: srsRewriteFieldRefs(s.front, oldToNew),
          back: srsRewriteFieldRefs(s.back, oldToNew),
          ankiNum: n,
        );
      }(),
  ];
  return SrsNewNoteType(
    record: SrsEntityRecord(
      id: typeId,
      profileUid: profileUid,
      kind: SrsEntityKind.noteType,
      payload: <String, Object?>{
        'ankiNum': typeNum,
        'ntKind': source.kind,
        'createdAt': createdAt,
      },
    ),
    name: name.trim(),
    fields: fields,
    templates: tpls,
    css: source.css,
    termFieldId: source.termFieldId == null
        ? null
        : oldToNew[source.termFieldId],
    freqFieldId: source.freqFieldId == null
        ? null
        : oldToNew[source.freqFieldId],
  );
}

/// 新增一个字段 / 模板的 ID（ankiNum 随机，ID 由笔记类型 + ankiNum 派生）。
({String id, int ankiNum}) srsNewFieldId(
  String noteTypeId, {
  int Function()? nextAnkiNum,
}) {
  final int n = (nextAnkiNum ?? randomAnkiNum)();
  return (id: SrsIds.field(noteTypeId, n), ankiNum: n);
}

/// 同 [srsNewFieldId]，模板。
({String id, int ankiNum}) srsNewTemplateId(
  String noteTypeId, {
  int Function()? nextAnkiNum,
}) {
  final int n = (nextAnkiNum ?? randomAnkiNum)();
  return (id: SrsIds.template(noteTypeId, n), ankiNum: n);
}

/// 调序：按 [orderedIds] 给出新的 ord，只返回 ord 真变了的项（其余不写修改记录——
/// 内置 Lapis 没动过的项继续跟随代码默认值，第六轮审查第 8 条）。
List<SrsFieldDef> srsReorderFields(
  List<SrsFieldDef> current,
  List<String> orderedIds,
) {
  final List<SrsFieldDef> out = <SrsFieldDef>[];
  for (int i = 0; i < orderedIds.length; i++) {
    final SrsFieldDef? f = current
        .where((SrsFieldDef x) => x.id == orderedIds[i])
        .firstOrNull;
    if (f == null || f.ord == i) continue;
    out.add(f.copyWith(ord: i));
  }
  return out;
}

/// 同 [srsReorderFields]，模板。
List<SrsTemplateDef> srsReorderTemplates(
  List<SrsTemplateDef> current,
  List<String> orderedIds,
) {
  final List<SrsTemplateDef> out = <SrsTemplateDef>[];
  for (int i = 0; i < orderedIds.length; i++) {
    final SrsTemplateDef? t = current
        .where((SrsTemplateDef x) => x.id == orderedIds[i])
        .firstOrNull;
    if (t == null || t.ord == i) continue;
    out.add(t.copyWith(ord: i));
  }
  return out;
}

// ---------------------------------------------------------------------------
// 更改笔记类型
// ---------------------------------------------------------------------------

/// 一张已有卡（旧类型下）。
class SrsExistingCard {
  const SrsExistingCard({
    required this.cardId,
    required this.templateId,
    required this.clozeOrd,
    required this.hidden,
  });

  final String cardId;
  final String templateId;
  final int clozeOrd;

  /// 本来就不可见（空卡 / 模板已删）：映射不到时不算「会被删的卡」。
  final bool hidden;
}

/// 默认字段映射（rslib `default_field_map`）：新字段先按名字找旧字段（不区分大小写），
/// 剩下的新字段按顺序领剩下的旧字段。返回 新 fieldId → 旧 fieldId（null = 留空）。
Map<String, String?> srsDefaultFieldMap(
  SrsNoteTypeView from,
  SrsNoteTypeView to,
) => _defaultMap(
  <(String, String)>[for (final SrsFieldDef f in from.fields) (f.id, f.name)],
  <(String, String)>[for (final SrsFieldDef f in to.fields) (f.id, f.name)],
);

/// 默认模板映射（同上）。只对普通 → 普通有意义；涉及填空类型时卡片按序号对应，见
/// [srsPlanNoteTypeChange]。
Map<String, String?> srsDefaultTemplateMap(
  SrsNoteTypeView from,
  SrsNoteTypeView to,
) => _defaultMap(
  <(String, String)>[
    for (final SrsTemplateDef t in from.templates) (t.id, t.name),
  ],
  <(String, String)>[
    for (final SrsTemplateDef t in to.templates) (t.id, t.name),
  ],
);

Map<String, String?> _defaultMap(
  List<(String, String)> from,
  List<(String, String)> to,
) {
  final Map<String, String?> out = <String, String?>{};
  final List<(String, String)> unused = List<(String, String)>.of(from);
  final List<String> unmatched = <String>[];
  for (final (String id, String name) in to) {
    final int i = unused.indexWhere(
      ((String, String) o) => _sameName(o.$2, name),
    );
    if (i >= 0) {
      out[id] = unused.removeAt(i).$1;
    } else {
      unmatched.add(id);
    }
  }
  for (final String id in unmatched) {
    out[id] = unused.isEmpty ? null : unused.removeAt(0).$1;
  }
  return out;
}

/// 一条笔记换类型要写的东西。
class SrsNoteTypeChangePlan {
  const SrsNoteTypeChangePlan({
    required this.noteId,
    required this.fieldValues,
    required this.cardLinks,
    required this.droppedCards,
  });

  final String noteId;

  /// 新 fieldId → 要写的值（只含与笔记当前存的值不同的；未映射的新字段写空）。
  final Map<String, String> fieldValues;

  /// 新 cardId → 旧 cardId（新卡继承旧卡的复习历史与标志）。
  final Map<String, String> cardLinks;

  /// 没有去处的旧卡（原本可见的）：换类型后不再出现（复习历史留在日志里，类型换回来时随卡复活）。
  final List<String> droppedCards;
}

/// 算一条笔记从 [from] 换到 [to] 要写的东西。
///
/// [fieldMap]：新 fieldId → 旧 fieldId（null = 留空；一个旧字段可以给多个新字段）。
/// [templateMap]：新 templateId → 旧 templateId（null = 新卡从头学；一个旧模板最多给一个新模板），
/// 只在普通 → 普通时使用。涉及填空类型时按 Anki 的口径「卡片序号不变」：
/// 普通 → 填空：第 i 个旧模板的卡 → c(i+1)；填空 → 填空：cN → cN；填空 → 普通：cN → 第 N 个新模板。
SrsNoteTypeChangePlan srsPlanNoteTypeChange({
  required SrsNoteView note,
  required SrsNoteTypeView from,
  required SrsNoteTypeView to,
  required Map<String, String?> fieldMap,
  required Map<String, String?> templateMap,
  required List<SrsExistingCard> existingCards,
}) {
  final Map<String, String> values = <String, String>{};
  for (final SrsFieldDef f in to.fields) {
    final String? src = fieldMap[f.id];
    final String want = src == null ? '' : note.field(src);
    if (want != note.field(f.id)) values[f.id] = want;
  }

  final Map<String, String> links = <String, String>{};
  final Set<String> linkedOld = <String>{};
  void link(String newTemplateId, int newClozeOrd, SrsExistingCard old) {
    final String newCard = SrsIds.card(note.id, newTemplateId, newClozeOrd);
    if (newCard == old.cardId || linkedOld.contains(old.cardId)) return;
    links[newCard] = old.cardId;
    linkedOld.add(old.cardId);
  }

  final List<SrsExistingCard> cards = <SrsExistingCard>[
    for (final SrsExistingCard c in existingCards)
      if (from.templates.any((SrsTemplateDef t) => t.id == c.templateId)) c,
  ];
  if (!from.isCloze && !to.isCloze) {
    for (final SrsTemplateDef t in to.templates) {
      final String? oldTpl = templateMap[t.id];
      if (oldTpl == null) continue;
      final SrsExistingCard? old = cards
          .where((SrsExistingCard c) => c.templateId == oldTpl)
          .firstOrNull;
      if (old != null) link(t.id, 0, old);
    }
  } else if (!from.isCloze && to.isCloze) {
    final SrsTemplateDef? cloze = to.templates.firstOrNull;
    if (cloze != null) {
      for (final SrsExistingCard c in cards) {
        final int pos = from.templates.indexWhere(
          (SrsTemplateDef t) => t.id == c.templateId,
        );
        link(cloze.id, pos + 1, c);
      }
    }
  } else if (from.isCloze && to.isCloze) {
    final SrsTemplateDef? cloze = to.templates.firstOrNull;
    if (cloze != null) {
      for (final SrsExistingCard c in cards) {
        link(cloze.id, c.clozeOrd, c);
      }
    }
  } else {
    for (final SrsExistingCard c in cards) {
      final int pos = c.clozeOrd - 1;
      if (pos >= 0 && pos < to.templates.length) {
        link(to.templates[pos].id, 0, c);
      }
    }
  }
  return SrsNoteTypeChangePlan(
    noteId: note.id,
    fieldValues: values,
    cardLinks: links,
    droppedCards: <String>[
      for (final SrsExistingCard c in cards)
        if (!c.hidden && !linkedOld.contains(c.cardId)) c.cardId,
    ],
  );
}
