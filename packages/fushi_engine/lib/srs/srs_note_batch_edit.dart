/// 批量改笔记字段：设卡型（Lapis / Fushi 卡片的正面开关）、给字段设值 / 清空、查找替换。
///
/// 浏览页的批量菜单与控制通道（`fushi/lib/src/ops/ctl_srs_routes.dart`，供 AI / `fushi_cli`）
/// 调同一组函数：先 `srsPlan*` 算出一份 [SrsNoteFieldPlan]（只读，可当预览 / dry-run），
/// 再 [srsApplyNoteFieldPlan] 一个批次落库（[SrsDbStore.editFieldsBatch]，走同步日志）。
///
/// 字段按**名字**指定、按每条笔记自己的笔记类型解析成 fieldId：同一批里可以混着 Lapis、
/// Fushi 卡片和导入的 Anki 类型；某条笔记的类型没有这个字段就记进 [SrsNoteFieldPlan.skipped]，
/// 不报错也不乱写。
///
/// 撤销：把改过的字段写回原值；写回前核对字段当前值仍是这批写下的值，之后又被改过的字段
/// 不动、计入「撤不掉」的条数（与 [SrsBatchRevert] 同一约定）。
library;

import 'package:fushi_srs/fushi_srs.dart';

import 'package:fushi_engine/srs/srs_browse_ops.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';

/// 卡型：Lapis 系模板的正面开关（四个 `Is*Card` 字段，非空即开）。全空 = 单词卡。
///
/// 与卡面的判定（`srsFushiFrontKind`，`fushi/lib/src/srs/srs_fushi_card_plan.dart`）同一语义与优先级：
/// 例句卡 > 单词 + 例句 > 点击卡 > 听音卡 > 单词卡。
enum SrsCardType {
  /// 正面只有单词（四个开关全空）。
  word(null),

  /// 正面只有例句。
  sentence('IsSentenceCard'),

  /// 正面单词 + 例句（Fushi 卡片新制卡的默认）。
  wordAndSentence('IsWordAndSentenceCard'),

  /// 正面单词，点一下展开例句。
  click('IsClickCard'),

  /// 正面播例句音频、例句里目标词遮住。
  audio('IsAudioCard');

  const SrsCardType(this.flagField);

  /// 打开的那个开关字段；[word] 没有。
  final String? flagField;

  /// wire 名（控制通道参数）：`word` / `sentence` / `word-and-sentence` / `click` / `audio`。
  String get wire => switch (this) {
    SrsCardType.wordAndSentence => 'word-and-sentence',
    _ => name,
  };

  static SrsCardType? tryParse(String? raw) {
    for (final SrsCardType t in values) {
      if (t.wire == raw || t.name == raw) return t;
    }
    return null;
  }
}

/// 四个卡型开关字段（顺序 = 卡面判定优先级）。
const List<String> kSrsCardTypeFlagFields = <String>[
  'IsSentenceCard',
  'IsWordAndSentenceCard',
  'IsClickCard',
  'IsAudioCard',
];

/// 卡型开关写入的值（与 Lapis / Fushi 卡片默认制卡映射一致）。
const String kSrsCardTypeFlagOn = 'x';

/// 一个字段的一处修改。
class SrsNoteFieldChange {
  const SrsNoteFieldChange({
    required this.noteId,
    required this.fieldId,
    required this.fieldName,
    required this.before,
    required this.after,
  });

  final String noteId;
  final String fieldId;
  final String fieldName;
  final String before;
  final String after;

  Map<String, Object?> toJson() => <String, Object?>{
    'note': noteId,
    'fieldId': fieldId,
    'field': fieldName,
    'before': before,
    'after': after,
  };

  static SrsNoteFieldChange? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? note = raw['note'], fieldId = raw['fieldId'];
    if (note is! String || fieldId is! String) return null;
    return SrsNoteFieldChange(
      noteId: note,
      fieldId: fieldId,
      fieldName: '${raw['field'] ?? ''}',
      before: '${raw['before'] ?? ''}',
      after: '${raw['after'] ?? ''}',
    );
  }
}

/// 一批字段修改的计划（还没写）。
class SrsNoteFieldPlan {
  const SrsNoteFieldPlan({
    required this.changes,
    required this.skipped,
    required this.unchanged,
    required this.missing,
  });

  /// 要写的修改（值没变的不在内）。
  final List<SrsNoteFieldChange> changes;

  /// 笔记类型没有所需字段、因而跳过的笔记。
  final List<String> skipped;

  /// 有所需字段但值已经是目标值（或没匹配到）的笔记数。
  final int unchanged;

  /// 不存在 / 已删除的笔记。
  final List<String> missing;

  /// 会被改到的笔记数。
  int get noteCount =>
      <String>{for (final SrsNoteFieldChange c in changes) c.noteId}.length;

  bool get isEmpty => changes.isEmpty;
}

/// 在 [type] 里按名字找字段：先精确，再忽略大小写（只认唯一命中）。
SrsFieldDef? srsFieldByName(SrsNoteTypeView type, String name) {
  for (final SrsFieldDef f in type.fields) {
    if (f.name == name) return f;
  }
  final String lower = name.toLowerCase();
  final List<SrsFieldDef> loose = <SrsFieldDef>[
    for (final SrsFieldDef f in type.fields)
      if (f.name.toLowerCase() == lower) f,
  ];
  return loose.length == 1 ? loose.single : null;
}

/// 逐条笔记（连同它的笔记类型）算出要写的字段值；[edit] 返回 null = 这条笔记的类型不适用
/// （记入 skipped），返回空 map = 适用但没有要改的。
Future<SrsNoteFieldPlan> _plan(
  SrsDbStore store,
  Iterable<String> noteIds,
  Map<String, String>? Function(SrsNoteView note, SrsNoteTypeView type) edit,
) async {
  final List<String> ids = noteIds.toSet().toList();
  final Map<String, SrsNoteView?> notes = await store.notes(ids);
  final Map<String, SrsNoteTypeView?> types = <String, SrsNoteTypeView?>{};
  final List<SrsNoteFieldChange> changes = <SrsNoteFieldChange>[];
  final List<String> skipped = <String>[];
  final List<String> missing = <String>[];
  int unchanged = 0;
  for (final String id in ids) {
    final SrsNoteView? note = notes[id];
    if (note == null || note.deletedAt != null) {
      missing.add(id);
      continue;
    }
    final SrsNoteTypeView? type = types.containsKey(note.noteTypeId)
        ? types[note.noteTypeId]
        : (types[note.noteTypeId] = await store.noteType(note.noteTypeId));
    if (type == null) {
      skipped.add(id);
      continue;
    }
    final Map<String, String>? next = edit(note, type);
    if (next == null) {
      skipped.add(id);
      continue;
    }
    bool any = false;
    for (final MapEntry<String, String> e in next.entries) {
      final String before = note.field(e.key);
      if (before == e.value) continue;
      any = true;
      changes.add(
        SrsNoteFieldChange(
          noteId: id,
          fieldId: e.key,
          fieldName:
              <String>[
                for (final SrsFieldDef f in type.fields)
                  if (f.id == e.key) f.name,
              ].firstOrNull ??
              e.key,
          before: before,
          after: e.value,
        ),
      );
    }
    if (!any) unchanged++;
  }
  return SrsNoteFieldPlan(
    changes: changes,
    skipped: skipped,
    unchanged: unchanged,
    missing: missing,
  );
}

/// 设卡型：打开 [type] 对应的开关（写 [kSrsCardTypeFlagOn]），关掉其余三个。笔记类型一个开关
/// 字段都没有（不是 Lapis 系模板）的笔记跳过。
Future<SrsNoteFieldPlan> srsPlanCardType(
  SrsDbStore store,
  Iterable<String> noteIds,
  SrsCardType type,
) => _plan(store, noteIds, (SrsNoteView note, SrsNoteTypeView nt) {
  final Map<String, String> next = <String, String>{};
  for (final String flag in kSrsCardTypeFlagFields) {
    final SrsFieldDef? f = srsFieldByName(nt, flag);
    if (f == null) continue;
    next[f.id] = flag == type.flagField ? kSrsCardTypeFlagOn : '';
  }
  // 要打开的开关在这个类型里不存在：设不成，跳过（不能只清空其余开关、把卡变成单词卡）。
  if (next.isEmpty) return null;
  final String? on = type.flagField;
  if (on != null && srsFieldByName(nt, on) == null) return null;
  return next;
});

/// 把字段 [fieldName] 设成 [value]（空串 = 清空）。
Future<SrsNoteFieldPlan> srsPlanSetField(
  SrsDbStore store,
  Iterable<String> noteIds,
  String fieldName,
  String value,
) => _plan(store, noteIds, (SrsNoteView note, SrsNoteTypeView nt) {
  final SrsFieldDef? f = srsFieldByName(nt, fieldName);
  return f == null ? null : <String, String>{f.id: value};
});

/// 查找替换（Anki「查找并替换」）：[fieldName] 为 null = 所有字段。[regex] 时 [find] 是正则、
/// [replace] 里 `$1` / `${name}` 引用分组；否则按字面替换。不合法的正则抛 [FormatException]。
Future<SrsNoteFieldPlan> srsPlanFindReplace(
  SrsDbStore store,
  Iterable<String> noteIds, {
  String? fieldName,
  required String find,
  required String replace,
  bool regex = false,
  bool caseSensitive = true,
}) {
  if (find.isEmpty) throw const FormatException('find must not be empty');
  final RegExp pattern = RegExp(
    regex ? find : RegExp.escape(find),
    caseSensitive: caseSensitive,
    unicode: true,
  );
  String apply(String text) => regex
      ? text.replaceAllMapped(pattern, (Match m) => _expand(replace, m))
      : text.replaceAll(pattern, replace);
  return _plan(store, noteIds, (SrsNoteView note, SrsNoteTypeView nt) {
    final List<SrsFieldDef> fields;
    if (fieldName == null) {
      fields = nt.fields;
    } else {
      final SrsFieldDef? f = srsFieldByName(nt, fieldName);
      if (f == null) return null;
      fields = <SrsFieldDef>[f];
    }
    return <String, String>{
      for (final SrsFieldDef f in fields) f.id: apply(note.field(f.id)),
    };
  });
}

final RegExp _groupRef = RegExp(r'\$(?:\{(\w+)\}|(\d+))');

/// 替换串里的 `$1` / `${name}` 展开成分组内容（不存在的分组 = 空串）；`$$` 是字面 `$`。
String _expand(String replace, Match m) {
  final StringBuffer out = StringBuffer();
  int i = 0;
  while (i < replace.length) {
    if (replace.startsWith(r'$$', i)) {
      out.write(r'$');
      i += 2;
      continue;
    }
    final Match? g = _groupRef.matchAsPrefix(replace, i);
    if (g == null) {
      out.write(replace[i]);
      i++;
      continue;
    }
    String? value;
    final String? named = g.group(1);
    if (named != null) {
      if (m is RegExpMatch && m.groupNames.contains(named)) {
        value = m.namedGroup(named);
      } else {
        final int? n = int.tryParse(named);
        if (n != null && n <= m.groupCount) value = m.group(n);
      }
    } else {
      final int n = int.parse(g.group(2)!);
      if (n <= m.groupCount) value = m.group(n);
    }
    out.write(value ?? '');
    i = g.end;
  }
  return out.toString();
}

/// 一个批次写下 [plan]；结果里的撤销按 [srsRevertNoteFieldChanges] 写回原值。
Future<SrsBatchOutcome> srsApplyNoteFieldPlan(
  SrsDbStore store,
  SrsNoteFieldPlan plan,
) async {
  if (plan.isEmpty) return const SrsBatchOutcome(changed: 0);
  final List<SrsNoteFieldChange> changes = plan.changes;
  await store.editFieldsBatch(<SrsFieldChange>[
    for (final SrsNoteFieldChange c in changes)
      SrsFieldChange(
        SrsEntityKind.note,
        c.noteId,
        SrsFieldKeys.noteField(c.fieldId),
        c.after,
      ),
  ]);
  return SrsBatchOutcome(
    changed: plan.noteCount,
    revert: (SrsDbStore s) => srsRevertNoteFieldChanges(s, changes),
  );
}

/// 把 [changes] 写回原值。字段当前值已不是 `after`（之后又被改过 / 笔记被删）的不动；
/// 返回撤不掉的笔记数。
Future<int> srsRevertNoteFieldChanges(
  SrsDbStore store,
  List<SrsNoteFieldChange> changes,
) async {
  final Map<String, SrsNoteView?> notes = await store.notes(<String>{
    for (final SrsNoteFieldChange c in changes) c.noteId,
  });
  final Set<String> blocked = <String>{};
  final List<SrsFieldChange> writes = <SrsFieldChange>[];
  for (final SrsNoteFieldChange c in changes) {
    final SrsNoteView? note = notes[c.noteId];
    if (note == null || note.deletedAt != null) {
      blocked.add(c.noteId);
      continue;
    }
    if (note.field(c.fieldId) != c.after) {
      blocked.add(c.noteId);
      continue;
    }
    writes.add(
      SrsFieldChange(
        SrsEntityKind.note,
        c.noteId,
        SrsFieldKeys.noteField(c.fieldId),
        c.before,
      ),
    );
  }
  if (writes.isNotEmpty) await store.editFieldsBatch(writes);
  return blocked.length;
}
