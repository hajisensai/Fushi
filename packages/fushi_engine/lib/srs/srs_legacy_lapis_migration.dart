/// 旧 Lapis 变体 → Fushi 卡片（当前新模板）的识别、按语义的字段映射与「遗漏字段补迁」。
///
/// **识别**（[srsDetectLapisVariant]）与 Anki 侧「这是不是 Lapis」的既有口径一致
/// （`packages/fushi_anki/lib/src/lapis_preset.dart` 的 `LapisPreset.matches`：名字含 lapis，
/// 或字段含 Expression + MainDefinition + Sentence），再加上内置 Lapis：
/// - 内置 Lapis（`builtinKey == lapis`，改过名、改过字段名也认，按内置 fieldId）；
/// - 名字含「lapis」的非内置类型（从 .apkg / AnkiConnect 导入的 Lapis、旧版 Hibiki / Fushi
///   在 Anki 里建的 Lapis、Lapis 的克隆）；
/// - 字段指纹命中的非内置类型（导入后被用户改了名的 Lapis、Lapis 的分支模板）。
/// 填空类型不算（卡片按 cN 编号，与 Fushi 卡片的单模板对不上）。
///
/// **字段按语义映射**（[srsLapisFieldSlot]）：每个源字段先归到一个「语义槽」= Fushi 卡片的
/// 字段键。判据强弱：内置 fieldId（[SrsLapisFieldMatch.builtinKey]）> 归一后与字段键同名
/// （[SrsLapisFieldMatch.exactName]）> 同义名表 [kSrsLapisFieldAliases]（[SrsLapisFieldMatch.alias]）。
/// 同一个槽有多个源字段时，最强的那个做主映射，其余的在主映射为空时按笔记逐条兜底
/// （[srsPlanLapisFieldFill]）。
///
/// **遗漏字段补迁**（[SrsLegacyLapisMigrationOps.applyLapisBackfill]）：「更改笔记类型」只给新
/// 字段写值，旧字段的修改记录原样留在笔记上（[SrsNoteView.fields] 里仍有旧 fieldId 的值）。
/// 所以对已经是 Fushi 卡片的笔记，凡是新字段为空、而它迁移前所属的 Lapis 变体里同一语义槽的
/// 字段有内容的，一律补上；已有内容绝不覆盖，重复执行不再写任何东西（幂等）。
library;

import 'package:drift/drift.dart';
import 'package:fushi_anki/fushi_anki_core.dart';
import 'package:fushi_srs/fushi_srs.dart';

import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_note_type_store.dart';

/// 旧 Lapis 变体的识别依据。
enum SrsLapisVariantKind {
  /// 内置 Lapis（`builtinKey == lapis`）。
  builtinLapis,

  /// 非内置、名字含「lapis」。
  namedLapis,

  /// 非内置、字段含 Expression + MainDefinition + Sentence（Lapis 字段指纹）。
  lapisFields,
}

/// 字段落进语义槽的依据（值越小越强）。
enum SrsLapisFieldMatch {
  /// 内置类型的内置字段（按 fieldId，不受改名影响）。
  builtinKey,

  /// 归一后与 Fushi 卡片的字段键同名。
  exactName,

  /// 同义名表。
  alias,
}

/// 一个字段的语义槽。
class SrsLapisFieldSlot {
  const SrsLapisFieldSlot(this.key, this.match);

  /// Fushi 卡片的字段键（[FushiCardNoteType.fields] 之一）。
  final String key;
  final SrsLapisFieldMatch match;
}

/// 字段名归一：小写、去掉空白与常见分隔符（`Misc Info` = `misc_info` = `MiscInfo`）。
String srsNormalizeLapisFieldName(String name) =>
    name.toLowerCase().replaceAll(RegExp(r'[\s_\-\.:/·・（）()\[\]【】「」]'), '');

/// 归一后的 Fushi 卡片字段键 → 字段键。
final Map<String, String> _fushiKeyByNormalized = <String, String>{
  for (final String k in FushiCardNoteType.fields)
    srsNormalizeLapisFieldName(k): k,
};

/// 同义名（已归一）→ Fushi 卡片字段键。
///
/// 只收语义明确的名字：Lapis 自身各版本 / 分支模板与常见挖词模板对同一内容的叫法，以及用户
/// 自己在 Lapis 上加的「来源 / 例句翻译」一类字段。拿不准的（裸 `notes` / `extra` /
/// `translation`——在带 MainDefinition 的类型里既可能是释义也可能是例句翻译）不收，宁可在
/// 预演里显示「没有对应字段」让用户走「调整映射」。
const Map<String, String> kSrsLapisFieldAliases = <String, String>{
  // Expression
  'word': 'Expression',
  'term': 'Expression',
  'vocab': 'Expression',
  'vocabulary': 'Expression',
  'targetword': 'Expression',
  '单词': 'Expression',
  '生词': 'Expression',
  '単語': 'Expression',
  '見出し語': 'Expression',
  // ExpressionFurigana
  'furigana': 'ExpressionFurigana',
  'wordfurigana': 'ExpressionFurigana',
  'vocabfurigana': 'ExpressionFurigana',
  '注音': 'ExpressionFurigana',
  'ふりがな': 'ExpressionFurigana',
  // ExpressionReading
  'reading': 'ExpressionReading',
  'wordreading': 'ExpressionReading',
  'vocabreading': 'ExpressionReading',
  'kana': 'ExpressionReading',
  '读音': 'ExpressionReading',
  '読み': 'ExpressionReading',
  // ExpressionAudio
  'audio': 'ExpressionAudio',
  'wordaudio': 'ExpressionAudio',
  'vocabaudio': 'ExpressionAudio',
  'expressionsound': 'ExpressionAudio',
  'pronunciation': 'ExpressionAudio',
  '发音': 'ExpressionAudio',
  '単語音声': 'ExpressionAudio',
  // SelectionText
  'selection': 'SelectionText',
  'selectedtext': 'SelectionText',
  'popupselectiontext': 'SelectionText',
  // MainDefinition
  'definition': 'MainDefinition',
  'meaning': 'MainDefinition',
  'primarydefinition': 'MainDefinition',
  'selecteddefinition': 'MainDefinition',
  '释义': 'MainDefinition',
  '词义': 'MainDefinition',
  '意味': 'MainDefinition',
  '定義': 'MainDefinition',
  // DefinitionPicture
  'definitionimage': 'DefinitionPicture',
  'primarydefinitionpicture': 'DefinitionPicture',
  // Sentence
  'example': 'Sentence',
  'examplesentence': 'Sentence',
  'context': 'Sentence',
  '例句': 'Sentence',
  '句子': 'Sentence',
  '例文': 'Sentence',
  // SentenceFurigana
  'sentencereading': 'SentenceFurigana',
  // SentenceAudio
  'sentencesound': 'SentenceAudio',
  '例句音频': 'SentenceAudio',
  '例文音声': 'SentenceAudio',
  // Picture
  'image': 'Picture',
  'screenshot': 'Picture',
  '图片': 'Picture',
  '截图': 'Picture',
  '画像': 'Picture',
  // Glossary
  'definitions': 'Glossary',
  'fullglossary': 'Glossary',
  'dictionary': 'Glossary',
  '词典': 'Glossary',
  '辞書': 'Glossary',
  // Hint
  '提示': 'Hint',
  'ヒント': 'Hint',
  // PitchPosition
  'pitch': 'PitchPosition',
  'pitchaccent': 'PitchPosition',
  'pitchaccentpositions': 'PitchPosition',
  'papositions': 'PitchPosition',
  '音调': 'PitchPosition',
  'アクセント': 'PitchPosition',
  // PitchCategories
  'pitchaccentcategories': 'PitchCategories',
  // Frequency
  'frequencies': 'Frequency',
  'frequenciesstylized': 'Frequency',
  '词频': 'Frequency',
  '頻度': 'Frequency',
  // FreqSort
  'frequencysort': 'FreqSort',
  'frequencyrank': 'FreqSort',
  'freqrank': 'FreqSort',
  // MiscInfo（来源）
  'misc': 'MiscInfo',
  'miscellaneous': 'MiscInfo',
  'source': 'MiscInfo',
  'sourceinfo': 'MiscInfo',
  'documenttitle': 'MiscInfo',
  '来源': 'MiscInfo',
  '出处': 'MiscInfo',
  '出典': 'MiscInfo',
  // SentenceTranslation
  'sentencemeaning': 'SentenceTranslation',
  'sentenceenglish': 'SentenceTranslation',
  'translatedsentence': 'SentenceTranslation',
  'sentencetrans': 'SentenceTranslation',
  '例句翻译': 'SentenceTranslation',
  '句子翻译': 'SentenceTranslation',
  '例句释义': 'SentenceTranslation',
  '例文訳': 'SentenceTranslation',
  '文訳': 'SentenceTranslation',
};

/// [t] 是不是受支持的旧 Lapis 变体（见文件头）；不是返回 null。
SrsLapisVariantKind? srsDetectLapisVariant(SrsNoteTypeView t) {
  if (t.isCloze) return null;
  if (t.builtinKey == kSrsBuiltinLapisKey) {
    return SrsLapisVariantKind.builtinLapis;
  }
  // 内置 Fushi 卡片（以及以后别的内置类型）本身就是新模板，不是迁移来源。
  if (t.builtinKey != null) return null;
  if (t.name.toLowerCase().contains('lapis')) {
    return SrsLapisVariantKind.namedLapis;
  }
  final Set<String> names = <String>{
    for (final SrsFieldDef f in t.fields) srsNormalizeLapisFieldName(f.name),
  };
  if (names.containsAll(const <String>[
    'expression',
    'maindefinition',
    'sentence',
  ])) {
    return SrsLapisVariantKind.lapisFields;
  }
  return null;
}

/// 字段 [f]（属于类型 [t]）的语义槽；落不进任何槽返回 null。
///
/// 内置类型的内置字段按 fieldId 认（用户改过名照样对上）；其余按名字。
SrsLapisFieldSlot? srsLapisFieldSlot(
  String profileUid,
  SrsNoteTypeView t,
  SrsFieldDef f,
) {
  final SrsBuiltinNoteType? builtin = srsBuiltinNoteTypeForKey(
    profileUid,
    t.builtinKey,
  );
  if (builtin != null) {
    for (final SrsFieldDef d in builtin.fields) {
      if (d.id == f.id) {
        return _fushiKeyByNormalized.containsKey(
              srsNormalizeLapisFieldName(d.name),
            )
            ? SrsLapisFieldSlot(d.name, SrsLapisFieldMatch.builtinKey)
            : null;
      }
    }
  }
  final String n = srsNormalizeLapisFieldName(f.name);
  if (n.isEmpty) return null;
  final String? exact = _fushiKeyByNormalized[n];
  if (exact != null) {
    return SrsLapisFieldSlot(exact, SrsLapisFieldMatch.exactName);
  }
  final String? alias = kSrsLapisFieldAliases[n];
  if (alias != null) return SrsLapisFieldSlot(alias, SrsLapisFieldMatch.alias);
  return null;
}

/// 目标（内置 Fushi 卡片）字段 [f] 的字段键：内置字段按 fieldId；用户自己加的字段返回 null
/// （它们只按同名接源字段，不参与语义槽，免得和内置字段抢同一个槽）。
String? _targetKey(String profileUid, SrsNoteTypeView to, SrsFieldDef f) {
  final SrsBuiltinNoteType? builtin = srsBuiltinNoteTypeForKey(
    profileUid,
    to.builtinKey,
  );
  if (builtin == null) return null;
  for (final SrsFieldDef d in builtin.fields) {
    if (d.id == f.id) return d.name;
  }
  return null;
}

bool _sameName(String a, String b) =>
    a.trim().toLowerCase() == b.trim().toLowerCase();

/// 一个源字段候选（某个类型里的某个字段）。
class SrsLapisFieldCandidate {
  const SrsLapisFieldCandidate({
    required this.type,
    required this.field,
    required this.slot,
  });

  final SrsNoteTypeView type;
  final SrsFieldDef field;

  /// null = 落不进语义槽（只能按同名接用户自加的目标字段）。
  final SrsLapisFieldSlot? slot;
}

int _compareCandidates(SrsLapisFieldCandidate a, SrsLapisFieldCandidate b) {
  final int s = (a.slot?.match.index ?? 99).compareTo(
    b.slot?.match.index ?? 99,
  );
  if (s != 0) return s;
  final int t = a.type.id.compareTo(b.type.id);
  if (t != 0) return t;
  return a.field.ord.compareTo(b.field.ord);
}

/// 映射表里的一行（预演显示用）。
class SrsLapisFieldMapping {
  const SrsLapisFieldMapping({
    required this.target,
    required this.source,
    required this.match,
  });

  final SrsFieldDef target;

  /// null = 留空。
  final SrsFieldDef? source;

  /// 源字段落进槽的依据；按同名接用户自加的目标字段时为 [SrsLapisFieldMatch.exactName]。
  final SrsLapisFieldMatch? match;
}

/// 一次「旧 Lapis 变体 → Fushi 卡片」的字段映射。
class SrsLapisFieldPlan {
  const SrsLapisFieldPlan({
    required this.fieldMap,
    required this.rows,
    required this.unmappedSources,
  });

  /// 新 fieldId → 旧 fieldId（null = 留空），直接喂给 [SrsNoteTypeStoreOps.changeNoteType]。
  final Map<String, String?> fieldMap;

  /// 按目标字段顺序的映射行。
  final List<SrsLapisFieldMapping> rows;

  /// 没有被任何目标字段当作主映射的源字段（可能经逐条兜底补进同槽的目标，见
  /// [srsPlanLapisFieldFill]；落不进任何槽的才真的不迁）。
  final List<SrsFieldDef> unmappedSources;
}

/// [from]（旧 Lapis 变体）→ [to]（内置 Fushi 卡片）的字段映射：内置字段按语义槽取最强的源
/// 字段；用户在 Fushi 卡片上自加的字段按名字（不区分大小写）接剩下的源字段。
SrsLapisFieldPlan srsLapisFieldPlan(
  String profileUid,
  SrsNoteTypeView from,
  SrsNoteTypeView to,
) {
  final List<SrsLapisFieldCandidate> sources = <SrsLapisFieldCandidate>[
    for (final SrsFieldDef f in from.fields)
      SrsLapisFieldCandidate(
        type: from,
        field: f,
        slot: srsLapisFieldSlot(profileUid, from, f),
      ),
  ]..sort(_compareCandidates);
  final Map<String, String?> map = <String, String?>{};
  final Map<String, SrsLapisFieldMapping> rowById =
      <String, SrsLapisFieldMapping>{};
  final Set<String> used = <String>{};
  // 第一轮：内置目标字段按语义槽。
  for (final SrsFieldDef target in to.fields) {
    final String? key = _targetKey(profileUid, to, target);
    if (key == null) continue;
    final SrsLapisFieldCandidate? best = sources
        .where(
          (SrsLapisFieldCandidate c) =>
              c.slot?.key == key && !used.contains(c.field.id),
        )
        .firstOrNull;
    map[target.id] = best?.field.id;
    if (best != null) used.add(best.field.id);
    rowById[target.id] = SrsLapisFieldMapping(
      target: target,
      source: best?.field,
      match: best?.slot?.match,
    );
  }
  // 第二轮：用户自加的目标字段按名字。
  for (final SrsFieldDef target in to.fields) {
    if (map.containsKey(target.id)) continue;
    final SrsFieldDef? same = from.fields
        .where(
          (SrsFieldDef f) =>
              !used.contains(f.id) && _sameName(f.name, target.name),
        )
        .firstOrNull;
    map[target.id] = same?.id;
    if (same != null) used.add(same.id);
    rowById[target.id] = SrsLapisFieldMapping(
      target: target,
      source: same,
      match: same == null ? null : SrsLapisFieldMatch.exactName,
    );
  }
  return SrsLapisFieldPlan(
    fieldMap: map,
    rows: <SrsLapisFieldMapping>[
      for (final SrsFieldDef f in to.fields) rowById[f.id]!,
    ],
    unmappedSources: <SrsFieldDef>[
      for (final SrsFieldDef f in from.fields)
        if (!used.contains(f.id)) f,
    ],
  );
}

/// 模板映射（新 templateId → 旧 templateId）：Fushi 卡片唯一的模板 ← 同名模板，没有就接源
/// 类型的第一个模板（复习历史比模板名重要；与 srs_builtin_migration.dart 的预设一致）。
Map<String, String?> srsLapisTemplateMap(
  SrsNoteTypeView from,
  SrsNoteTypeView to,
) {
  final Map<String, String?> out = <String, String?>{};
  final Set<String> used = <String>{};
  for (final SrsTemplateDef t in to.templates) {
    final SrsTemplateDef? same = from.templates
        .where(
          (SrsTemplateDef s) =>
              !used.contains(s.id) && _sameName(s.name, t.name),
        )
        .firstOrNull;
    out[t.id] = same?.id;
    if (same != null) used.add(same.id);
  }
  if (to.templates.length == 1 &&
      out.values.every((String? v) => v == null) &&
      from.templates.isNotEmpty) {
    out[to.templates.first.id] = from.templates.first.id;
  }
  return out;
}

/// 一条笔记里某个候选字段的值。
class SrsLapisFieldValue {
  const SrsLapisFieldValue(this.candidate, this.value);

  final SrsLapisFieldCandidate candidate;
  final String value;
}

/// 给目标类型 [target]（内置 Fushi 卡片）里**为空**的字段，从 [values]（同一条笔记里别的
/// 字段——迁移前所属类型的字段）按语义槽 / 同名补值。返回 fieldId → 要写的值；已有内容的
/// 字段一个都不碰，所以对补过的笔记再算一次结果为空（幂等）。
///
/// [current]：目标字段此刻（或迁移写入后）的值。
Map<String, String> srsPlanLapisFieldFill({
  required String profileUid,
  required SrsNoteTypeView target,
  required Map<String, String> current,
  required List<SrsLapisFieldValue> values,
}) {
  final List<SrsLapisFieldValue> usable =
      <SrsLapisFieldValue>[
        for (final SrsLapisFieldValue v in values)
          if (v.value.trim().isNotEmpty) v,
      ]..sort(
        (SrsLapisFieldValue a, SrsLapisFieldValue b) =>
            _compareCandidates(a.candidate, b.candidate),
      );
  final Map<String, String> out = <String, String>{};
  for (final SrsFieldDef f in target.fields) {
    if ((current[f.id] ?? '').trim().isNotEmpty) continue;
    final String? key = _targetKey(profileUid, target, f);
    final SrsLapisFieldValue? hit = usable
        .where(
          (SrsLapisFieldValue v) => key != null
              ? v.candidate.slot?.key == key
              : _sameName(v.candidate.field.name, f.name),
        )
        .firstOrNull;
    if (hit != null) out[f.id] = hit.value;
  }
  return out;
}

/// 一种可迁移的旧 Lapis 变体（有笔记的）。
class SrsLegacyLapisSource {
  const SrsLegacyLapisSource({
    required this.type,
    required this.kind,
    required this.noteIds,
  });

  final SrsNoteTypeView type;
  final SrsLapisVariantKind kind;
  final List<String> noteIds;
}

/// 一种变体迁移到 Fushi 卡片的预演。
class SrsLegacyLapisMigrationPreview {
  const SrsLegacyLapisMigrationPreview({
    required this.source,
    required this.fields,
    required this.change,
    required this.lostFieldNotes,
    required this.fallbackFills,
  });

  final SrsLegacyLapisSource source;
  final SrsLapisFieldPlan fields;

  /// 卡片继承 / 丢弃的预演（[SrsNoteTypeStoreOps.previewNoteTypeChange]）。
  final SrsNoteTypeChangePreview change;

  /// 落不进新模板的源字段 → 其中有内容的笔记数（内容留在笔记上，不迁）。
  final Map<SrsFieldDef, int> lostFieldNotes;

  /// 主映射为空、由同槽的其它源字段逐条补上的笔记数。
  final int fallbackFills;
}

/// 「遗漏字段补迁」的预演。
class SrsLapisBackfillPreview {
  const SrsLapisBackfillPreview({required this.fills});

  /// noteId → 要补的 fieldId → 值。
  final Map<String, Map<String, String>> fills;

  int get notes => fills.length;

  /// 目标 fieldId → 要补的笔记数。
  Map<String, int> get fieldCounts {
    final Map<String, int> out = <String, int>{};
    for (final Map<String, String> f in fills.values) {
      for (final String id in f.keys) {
        out[id] = (out[id] ?? 0) + 1;
      }
    }
    return out;
  }
}

extension SrsLegacyLapisMigrationOps on SrsDbStore {
  /// 全部笔记类型，**含已删除的**（补迁要认迁移前所属、后来被删掉的类型的字段）。
  Future<List<SrsNoteTypeView>> _allNoteTypesWithDeleted() async {
    final List<String> ids =
        (await (db.select(db.srsEntities)..where(
                  (t) =>
                      t.profileUid.equals(profileUid) &
                      t.kind.equals(SrsEntityKind.noteType.wire),
                ))
                .get())
            .map((r) => r.id)
            .toList();
    final List<SrsNoteTypeView> out = <SrsNoteTypeView>[];
    for (final String id in ids) {
      final SrsNoteTypeView? v = await noteType(id);
      if (v != null) out.add(v);
    }
    return out;
  }

  Future<SrsNoteTypeView> _fushiCardType() async {
    final SrsNoteTypeView? to = await noteType(fushiCardNoteTypeId);
    if (to == null || to.deletedAt != null) {
      throw StateError('built-in Fushi card note type is missing');
    }
    return to;
  }

  /// 现有的全部旧 Lapis 变体（有未删除笔记的），内置 Lapis 在前，其余按名字。
  Future<List<SrsLegacyLapisSource>> legacyLapisSources() async {
    final List<SrsLegacyLapisSource> out = <SrsLegacyLapisSource>[];
    for (final SrsNoteTypeView t in await noteTypes()) {
      final SrsLapisVariantKind? kind = srsDetectLapisVariant(t);
      if (kind == null) continue;
      final List<String> ids = await noteIdsOfType(t.id);
      if (ids.isEmpty) continue;
      out.add(SrsLegacyLapisSource(type: t, kind: kind, noteIds: ids));
    }
    out.sort((SrsLegacyLapisSource a, SrsLegacyLapisSource b) {
      final int k = a.kind.index.compareTo(b.kind.index);
      return k != 0 ? k : a.type.name.compareTo(b.type.name);
    });
    return out;
  }

  /// 笔记 [note] 里属于 [ownerByFieldId] 所列字段的值（迁移前所属类型的字段）。
  List<SrsLapisFieldValue> _historicalValues(
    SrsNoteView note,
    Map<String, SrsLapisFieldCandidate> ownerByFieldId,
  ) => <SrsLapisFieldValue>[
    for (final MapEntry<String, String> e in note.fields.entries)
      if (ownerByFieldId[e.key] case final SrsLapisFieldCandidate c)
        SrsLapisFieldValue(c, e.value),
  ];

  /// fieldId → 它所属的旧 Lapis 变体字段（含已删除的类型；不含 [exceptTypeId] 自己的字段）。
  Future<Map<String, SrsLapisFieldCandidate>> _lapisFieldOwners({
    required String exceptTypeId,
  }) async {
    final Map<String, SrsLapisFieldCandidate> out =
        <String, SrsLapisFieldCandidate>{};
    for (final SrsNoteTypeView t in await _allNoteTypesWithDeleted()) {
      if (t.id == exceptTypeId || srsDetectLapisVariant(t) == null) continue;
      for (final SrsFieldDef f in t.fields) {
        out[f.id] = SrsLapisFieldCandidate(
          type: t,
          field: f,
          slot: srsLapisFieldSlot(profileUid, t, f),
        );
      }
    }
    return out;
  }

  /// 预演把 [sourceTypeId] 的全部笔记迁到 Fushi 卡片（不写库）。
  Future<SrsLegacyLapisMigrationPreview> previewLegacyLapisMigration(
    String sourceTypeId,
  ) async {
    final SrsLegacyLapisSource source = (await legacyLapisSources()).firstWhere(
      (SrsLegacyLapisSource s) => s.type.id == sourceTypeId,
      orElse: () => throw ArgumentError.value(
        sourceTypeId,
        'sourceTypeId',
        'not a legacy Lapis note type with notes',
      ),
    );
    final SrsNoteTypeView to = await _fushiCardType();
    final SrsLapisFieldPlan plan = srsLapisFieldPlan(
      profileUid,
      source.type,
      to,
    );
    final SrsNoteTypeChangePreview change = await previewNoteTypeChange(
      noteIds: source.noteIds,
      targetTypeId: to.id,
      fieldMap: plan.fieldMap,
      templateMap: srsLapisTemplateMap(source.type, to),
    );
    final Map<String, SrsLapisFieldCandidate> owners =
        <String, SrsLapisFieldCandidate>{
          for (final SrsFieldDef f in source.type.fields)
            f.id: SrsLapisFieldCandidate(
              type: source.type,
              field: f,
              slot: srsLapisFieldSlot(profileUid, source.type, f),
            ),
        };
    final Set<String> targetSlots = <String>{
      for (final SrsLapisFieldMapping r in plan.rows)
        _targetKey(profileUid, to, r.target) ?? '',
    };
    final Set<String> targetNames = <String>{
      for (final SrsFieldDef f in to.fields) f.name.trim().toLowerCase(),
    };
    final Map<SrsFieldDef, int> lost = <SrsFieldDef, int>{};
    int fallback = 0;
    for (final String id in source.noteIds) {
      final SrsNoteView n = (await note(id))!;
      final Map<String, String> mapped = <String, String>{
        for (final MapEntry<String, String?> e in plan.fieldMap.entries)
          e.key: e.value == null ? '' : n.field(e.value!),
      };
      if (srsPlanLapisFieldFill(
        profileUid: profileUid,
        target: to,
        current: mapped,
        values: _historicalValues(n, owners),
      ).isNotEmpty) {
        fallback++;
      }
      for (final SrsFieldDef f in plan.unmappedSources) {
        final SrsLapisFieldSlot? slot = owners[f.id]!.slot;
        final bool hasHome =
            (slot != null && targetSlots.contains(slot.key)) ||
            targetNames.contains(f.name.trim().toLowerCase());
        if (!hasHome && n.field(f.id).trim().isNotEmpty) {
          lost[f] = (lost[f] ?? 0) + 1;
        }
      }
    }
    return SrsLegacyLapisMigrationPreview(
      source: source,
      fields: plan,
      change: change,
      lostFieldNotes: lost,
      fallbackFills: fallback,
    );
  }

  /// 把 [sourceTypeId] 的笔记（缺省全部；给了 [noteIds] 就只迁这些，它们必须都是这个类型）
  /// 迁到 Fushi 卡片：按语义映射换类型（复习历史经前身链接随迁），再对这些笔记跑一遍补迁
  /// （主映射为空、同槽的其它源字段有内容的逐条补上）。返回迁移的笔记数。
  Future<int> migrateLegacyLapis(
    String sourceTypeId, {
    List<String>? noteIds,
  }) async {
    final SrsNoteTypeView? from = await noteType(sourceTypeId);
    if (from == null || srsDetectLapisVariant(from) == null) {
      throw ArgumentError.value(
        sourceTypeId,
        'sourceTypeId',
        'not a legacy Lapis note type',
      );
    }
    final List<String> ids = noteIds ?? await noteIdsOfType(sourceTypeId);
    if (ids.isEmpty) return 0;
    final SrsNoteTypeView to = await _fushiCardType();
    final SrsLapisFieldPlan plan = srsLapisFieldPlan(profileUid, from, to);
    await changeNoteType(
      noteIds: ids,
      targetTypeId: to.id,
      fieldMap: plan.fieldMap,
      templateMap: srsLapisTemplateMap(from, to),
    );
    await applyLapisBackfill(noteIds: ids);
    return ids.length;
  }

  /// 预演「遗漏字段补迁」：当前是 Fushi 卡片的笔记（缺省全部，或只看 [noteIds]），新字段
  /// 为空、迁移前所属的旧 Lapis 变体里同语义的字段有内容的。不写库。
  Future<SrsLapisBackfillPreview> previewLapisBackfill({
    List<String>? noteIds,
  }) async {
    final SrsNoteTypeView? to = await noteType(fushiCardNoteTypeId);
    if (to == null || to.deletedAt != null) {
      return const SrsLapisBackfillPreview(
        fills: <String, Map<String, String>>{},
      );
    }
    final Map<String, SrsLapisFieldCandidate> owners = await _lapisFieldOwners(
      exceptTypeId: to.id,
    );
    final Map<String, Map<String, String>> fills =
        <String, Map<String, String>>{};
    if (owners.isEmpty) return SrsLapisBackfillPreview(fills: fills);
    for (final String id in noteIds ?? await noteIdsOfType(to.id)) {
      final SrsNoteView? n = await note(id);
      if (n == null || n.deletedAt != null || n.noteTypeId != to.id) continue;
      final Map<String, String> fill = srsPlanLapisFieldFill(
        profileUid: profileUid,
        target: to,
        current: n.fields,
        values: _historicalValues(n, owners),
      );
      if (fill.isNotEmpty) fills[id] = fill;
    }
    return SrsLapisBackfillPreview(fills: fills);
  }

  /// 执行「遗漏字段补迁」（只写空字段，幂等）。返回补过的笔记数。
  Future<int> applyLapisBackfill({List<String>? noteIds}) async {
    final SrsLapisBackfillPreview p = await previewLapisBackfill(
      noteIds: noteIds,
    );
    if (p.fills.isEmpty) return 0;
    await writeEdits(<SrsEditSpec>[
      for (final MapEntry<String, Map<String, String>> n in p.fills.entries)
        for (final MapEntry<String, String> f in n.value.entries)
          SrsEditSpec(
            SrsEntityKind.note,
            n.key,
            SrsFieldKeys.noteField(f.key),
            f.value,
          ),
    ]);
    return p.notes;
  }

  /// 迁移页入口的角标：可迁移的旧 Lapis 笔记数 + 需要补迁的笔记数。
  Future<({int migratable, int backfill})> legacyLapisPendingCounts() async {
    int migratable = 0;
    for (final SrsLegacyLapisSource s in await legacyLapisSources()) {
      migratable += s.noteIds.length;
    }
    return (
      migratable: migratable,
      backfill: (await previewLapisBackfill()).notes,
    );
  }
}
