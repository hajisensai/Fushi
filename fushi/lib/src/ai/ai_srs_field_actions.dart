/// 卡片字段 AI 的「可编辑提示词」：内置模板（总体说明 + 四个任务）可原地改、可恢复默认；
/// 任务模板可复制成具名变体（只属于一个任务，可改名 / 改正文 / 删除）。
///
/// 边界：
/// - 只改**引导文字**：回复格式、JSON 结构、说明语言这份「契约」（[kAiSrsFieldContract]）由代码
///   永远追加在总体说明之后，用户改不到；回复照旧经 `parseAiSrsFieldSuggestion` /
///   `aiSrsSanitizeFieldHtml` 本地校验。
/// - 没有任何改动时，发出去的系统消息与任务行与改造前逐字节一致（测试咬住）。
/// - 持久化走偏好键 [kAiFieldActionsPrefKey]（一份 JSON）：没有条目 = 用内置；**不把默认值抄进
///   存储**（改回与内置相同的正文 = 删掉这条覆盖）。逐条容错，坏条目只丢它自己。
/// - 覆盖记下它基于的内置版本（[AiSrsFieldPromptOverride.baseVersion]）：内置版本更新后编辑页
///   提示「内置提示词更新过」。不用哈希——以后内置文案可能本地化，哈希会误报。
library;

import 'dart:convert';
import 'dart:math';

import 'package:fushi_srs/fushi_srs.dart' show SrsFieldDef;

import 'package:fushi/src/ai/ai_saved_prompts.dart'
    show AiPromptScene, AiSavedPrompt, kAiBuiltinPromptIdPrefix;
import 'package:fushi/src/ai/ai_srs_field_assistant.dart';
import 'package:fushi/src/ai/ai_srs_template_assistant.dart'
    show AiSrsFieldBrief;
import 'package:fushi/src/srs/srs_field_catalog.dart' show srsFieldDisplayName;

/// 偏好键：卡片字段 AI 的提示词覆盖与变体（JSON 对象）。
const String kAiFieldActionsPrefKey = 'ai_field_actions';

/// 每份模板 / 变体正文的长度上限（字符）。
const int kAiSrsFieldPromptMax = 4000;

/// 变体名称长度上限（字符）。
const int kAiSrsFieldVariantNameMax = 60;

/// 总体说明模板的 id（**冻结**）。
const String kAiSrsFieldSystemTemplateId = 'system';

/// 占位符：AI 输出语言的语言名。
const String kAiSrsFieldOutputLanguagePlaceholder = 'output_language';

/// 占位符：正在写的字段的显示名。
const String kAiSrsFieldTargetFieldPlaceholder = 'target_field';

/// 引用的字段为空时代入的文字。
const String kAiSrsFieldEmptyFieldValue = '(empty)';

/// 一份内置模板。[id] 与 [version] 都**冻结**：id 是落盘键；改了内置正文就把 [version] 加一，
/// 基于旧版本改过的用户才会看到「内置提示词更新过」。
class AiSrsFieldTemplate {
  const AiSrsFieldTemplate({
    required this.id,
    required this.version,
    required this.text,
    this.task,
  });

  final String id;
  final int version;
  final String text;

  /// 任务模板所属的任务；总体说明为 null。
  final AiSrsFieldTask? task;

  bool get isSystem => task == null;
}

/// 内置「写释义」任务正文。
const String kAiSrsFieldDefineTask = '''
Task: write the definition of the headword for this field, in
{{output_language}}.
- Base it on the note's dictionary fields (definition, glossary) when they are
  present; do not invent senses.
- Put the sense used in the note's sentence first and wrap it in <b>…</b>.
  Number the senses if there are several.''';

/// 内置「翻译例句」任务正文。规则按两类真实难句定：省略主语 / 宾语的整句
/// （`それに気づいた時 完全に嫌いになった`）与带句末语气词的残句（`うっかりかあ`）。
const String kAiSrsFieldTranslateTask = '''
Task: translate the note's example sentence into {{output_language}}.
- Translate only the sentence. Use the other fields (target word, its
  definition, source) only to work out what it means.
- Be faithful first, natural second: keep the meaning, tone and register
  (casual, polite, rough). Do not add or drop information, do not soften or
  intensify, do not explain.
- Keep fragments, interjections and lines that trail off as they are: do not
  turn them into full sentences or add a subject or verb the original does not
  imply.
- Add a missing subject or object only when the sentence needs one. Pick the
  most likely reading from the other fields; if they do not settle it, use a
  neutral choice ("I", "it", "them") and name the guess in "explanation".
- Translate sentence-final particles and drawn-out endings with a natural
  equivalent ("huh", "right", "…") instead of dropping them.
- Wrap the words that translate the target word (the <b> part of the
  sentence, or the headword) in <b>…</b>, once.
- "value" holds only the translation: one line, no quotes, no romanization,
  no alternatives, no notes.
- "explanation": one short sentence naming any guess or ambiguity; if there
  was none, say the translation is direct.''';

/// 内置「改写」任务正文。
const String kAiSrsFieldRewriteTask = '''
Task: improve this field using the other fields of the note: keep the
meaning, make it clearer and shorter. Never change the meaning, and do not
rewrite the note's sentence or headword text itself.''';

/// 全部内置模板（总体说明在前，任务按 [AiSrsFieldTask] 的顺序）。
const List<AiSrsFieldTemplate> kAiSrsFieldTemplates = <AiSrsFieldTemplate>[
  // v2：加「以笔记的词典字段为准、不编造」一段。
  AiSrsFieldTemplate(
    id: kAiSrsFieldSystemTemplateId,
    version: 2,
    text: kAiSrsFieldGuidance,
  ),
  // v2：以笔记的词典字段为准；句中用到的义项放第一、加粗。
  AiSrsFieldTemplate(
    id: 'task.define',
    version: 2,
    task: AiSrsFieldTask.define,
    text: kAiSrsFieldDefineTask,
  ),
  // v2：只译例句；忠实优先、保留语气；残句 / 句末语气词 / 省略的主语宾语怎么处理；
  // 目标词译文加粗；value 只放译文；猜测写进 explanation。
  AiSrsFieldTemplate(
    id: 'task.translate',
    version: 2,
    task: AiSrsFieldTask.translate,
    text: kAiSrsFieldTranslateTask,
  ),
  // v2：不许改意思，不改写例句 / 词头本身。
  AiSrsFieldTemplate(
    id: 'task.rewrite',
    version: 2,
    task: AiSrsFieldTask.rewrite,
    text: kAiSrsFieldRewriteTask,
  ),
  AiSrsFieldTemplate(
    id: 'task.custom',
    version: 1,
    task: AiSrsFieldTask.custom,
    text: 'Task: follow the user instruction below.',
  ),
];

/// 按 id 找内置模板；认不出返回 null。
AiSrsFieldTemplate? aiSrsFieldTemplateById(String id) {
  for (final AiSrsFieldTemplate template in kAiSrsFieldTemplates) {
    if (template.id == id) return template;
  }
  return null;
}

/// [task] 的内置任务模板。
AiSrsFieldTemplate aiSrsFieldTaskTemplate(AiSrsFieldTask task) =>
    kAiSrsFieldTemplates.firstWhere(
      (AiSrsFieldTemplate template) => template.task == task,
    );

/// 任务的落盘值（变体的 `task`，**冻结**）。
String aiSrsFieldTaskWire(AiSrsFieldTask task) => switch (task) {
  AiSrsFieldTask.define => 'define',
  AiSrsFieldTask.translate => 'translate',
  AiSrsFieldTask.rewrite => 'rewrite',
  AiSrsFieldTask.custom => 'custom',
};

/// 按落盘值找任务；认不出返回 null。
AiSrsFieldTask? aiSrsFieldTaskFromWire(String? wire) {
  for (final AiSrsFieldTask task in AiSrsFieldTask.values) {
    if (aiSrsFieldTaskWire(task) == wire) return task;
  }
  return null;
}

String _capText(String text) => text.length <= kAiSrsFieldPromptMax
    ? text
    : text.substring(0, kAiSrsFieldPromptMax);

String _capName(String name) {
  final String trimmed = name.trim();
  return trimmed.length <= kAiSrsFieldVariantNameMax
      ? trimmed
      : trimmed.substring(0, kAiSrsFieldVariantNameMax);
}

/// 用户对一份内置模板的改动。
class AiSrsFieldPromptOverride {
  const AiSrsFieldPromptOverride({
    required this.text,
    required this.baseVersion,
  });

  final String text;

  /// 改动时内置模板的版本。
  final int baseVersion;

  Map<String, Object?> toJson() => <String, Object?>{
    'text': text,
    'baseVersion': baseVersion,
  };

  /// 逐条容错：不是对象 / 正文不是字符串返回 null；版本缺失当 0（= 比任何内置都旧）。
  static AiSrsFieldPromptOverride? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? text = raw['text'];
    final Object? version = raw['baseVersion'];
    if (text is! String) return null;
    return AiSrsFieldPromptOverride(
      text: _capText(text),
      baseVersion: version is int ? version : 0,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AiSrsFieldPromptOverride &&
      other.text == text &&
      other.baseVersion == baseVersion;

  @override
  int get hashCode => Object.hash(text, baseVersion);
}

/// 用户复制出来的具名变体，只属于一个任务。
class AiSrsFieldVariant {
  const AiSrsFieldVariant({
    required this.id,
    required this.taskWire,
    required this.name,
    required this.text,
  });

  final String id;

  /// 所属任务的落盘值；认不出（新版本写的）原样保留，只是本版本不显示。
  final String taskWire;
  final String name;
  final String text;

  AiSrsFieldTask? get task => aiSrsFieldTaskFromWire(taskWire);

  AiSrsFieldVariant copyWith({String? name, String? text}) => AiSrsFieldVariant(
    id: id,
    taskWire: taskWire,
    name: name ?? this.name,
    text: text ?? this.text,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'task': taskWire,
    'name': name,
    'text': text,
  };

  /// 逐条容错：字段缺失 / 类型不对 / id 为空返回 null（只丢这一条）。
  static AiSrsFieldVariant? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? id = raw['id'];
    final Object? task = raw['task'];
    final Object? name = raw['name'];
    final Object? text = raw['text'];
    if (id is! String || id.isEmpty) return null;
    if (task is! String || task.isEmpty) return null;
    if (name is! String || text is! String) return null;
    return AiSrsFieldVariant(
      id: id,
      taskWire: task,
      name: _capName(name),
      text: _capText(text),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AiSrsFieldVariant &&
      other.id == id &&
      other.taskWire == taskWire &&
      other.name == name &&
      other.text == text;

  @override
  int get hashCode => Object.hash(id, taskWire, name, text);

  @override
  String toString() => 'AiSrsFieldVariant($id, $taskWire, $name)';
}

/// 抽屉里选中的动作：一个任务 + 可选的变体（null = 用该任务的模板，内置或改过的）。
class AiSrsFieldAction {
  const AiSrsFieldAction(this.task, {this.variantId});

  final AiSrsFieldTask task;
  final String? variantId;

  @override
  bool operator ==(Object other) =>
      other is AiSrsFieldAction &&
      other.task == task &&
      other.variantId == variantId;

  @override
  int get hashCode => Object.hash(task, variantId);

  @override
  String toString() => 'AiSrsFieldAction(${task.name}, $variantId)';
}

final Random _idRandom = Random();

String _newVariantId() {
  final String time = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  final String salt = _idRandom.nextInt(1 << 30).toRadixString(36);
  return 'v_${time}_$salt';
}

/// 用户的全部改动（不可变；每个修改方法返回新值）。
class AiSrsFieldActions {
  const AiSrsFieldActions({
    this.overrides = const <String, AiSrsFieldPromptOverride>{},
    this.variants = const <AiSrsFieldVariant>[],
  });

  static const AiSrsFieldActions empty = AiSrsFieldActions();

  /// 模板 id → 覆盖。认不出的 id（新版本写的）原样保留。
  final Map<String, AiSrsFieldPromptOverride> overrides;
  final List<AiSrsFieldVariant> variants;

  bool get isEmpty => overrides.isEmpty && variants.isEmpty;

  /// 模板当前生效的正文（覆盖优先，否则内置）。
  String textOf(String templateId) =>
      overrides[templateId]?.text ??
      aiSrsFieldTemplateById(templateId)?.text ??
      '';

  bool isOverridden(String templateId) => overrides.containsKey(templateId);

  /// 覆盖基于的内置版本比现在的内置旧。
  bool isOutdated(String templateId) {
    final AiSrsFieldPromptOverride? override = overrides[templateId];
    final AiSrsFieldTemplate? template = aiSrsFieldTemplateById(templateId);
    if (override == null || template == null) return false;
    return override.baseVersion < template.version;
  }

  /// [task] 的变体（保持保存顺序）。
  List<AiSrsFieldVariant> variantsFor(AiSrsFieldTask task) =>
      <AiSrsFieldVariant>[
        for (final AiSrsFieldVariant v in variants)
          if (v.task == task) v,
      ];

  /// 本版本认得的全部变体（任务认得出）。
  List<AiSrsFieldVariant> get knownVariants => <AiSrsFieldVariant>[
    for (final AiSrsFieldVariant v in variants)
      if (v.task != null) v,
  ];

  AiSrsFieldVariant? variant(String id) {
    for (final AiSrsFieldVariant v in variants) {
      if (v.id == id) return v;
    }
    return null;
  }

  /// [action] 实际要用的任务模板正文：变体存在且属于该任务就用变体，否则用任务模板。
  String taskTextOf(AiSrsFieldAction action) {
    final String? variantId = action.variantId;
    final AiSrsFieldVariant? v = variantId == null ? null : variant(variantId);
    if (v != null && v.task == action.task) return v.text;
    return textOf(aiSrsFieldTaskTemplate(action.task).id);
  }

  /// 改一份内置模板的正文：与内置相同 = 删掉覆盖（不把默认值抄进存储）；超长截断；
  /// 版本记成当前内置版本（编辑页看着提示改的，就算看过新版）。认不出的 id 原样返回。
  AiSrsFieldActions withTemplateText(String templateId, String text) {
    final AiSrsFieldTemplate? template = aiSrsFieldTemplateById(templateId);
    if (template == null) return this;
    final String capped = _capText(text);
    final Map<String, AiSrsFieldPromptOverride> next =
        Map<String, AiSrsFieldPromptOverride>.of(overrides);
    if (capped == template.text) {
      next.remove(templateId);
    } else {
      next[templateId] = AiSrsFieldPromptOverride(
        text: capped,
        baseVersion: template.version,
      );
    }
    return AiSrsFieldActions(overrides: next, variants: variants);
  }

  /// 恢复默认：删掉覆盖。
  AiSrsFieldActions resetTemplate(String templateId) {
    if (!overrides.containsKey(templateId)) return this;
    return AiSrsFieldActions(
      overrides: Map<String, AiSrsFieldPromptOverride>.of(overrides)
        ..remove(templateId),
      variants: variants,
    );
  }

  /// 新增一个变体（追加在末尾）；返回新值与新变体。
  (AiSrsFieldActions, AiSrsFieldVariant) addVariant({
    required AiSrsFieldTask task,
    required String name,
    required String text,
    String? id,
  }) {
    final AiSrsFieldVariant created = AiSrsFieldVariant(
      id: id ?? _newVariantId(),
      taskWire: aiSrsFieldTaskWire(task),
      name: _capName(name),
      text: _capText(text),
    );
    return (
      AiSrsFieldActions(
        overrides: overrides,
        variants: <AiSrsFieldVariant>[...variants, created],
      ),
      created,
    );
  }

  /// 改变体的名称 / 正文（只改给出的）。
  AiSrsFieldActions updateVariant(String id, {String? name, String? text}) =>
      AiSrsFieldActions(
        overrides: overrides,
        variants: <AiSrsFieldVariant>[
          for (final AiSrsFieldVariant v in variants)
            v.id == id
                ? v.copyWith(
                    name: name == null ? null : _capName(name),
                    text: text == null ? null : _capText(text),
                  )
                : v,
        ],
      );

  AiSrsFieldActions removeVariant(String id) => AiSrsFieldActions(
    overrides: overrides,
    variants: <AiSrsFieldVariant>[
      for (final AiSrsFieldVariant v in variants)
        if (v.id != id) v,
    ],
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'overrides': <String, Object?>{
      for (final MapEntry<String, AiSrsFieldPromptOverride> e
          in overrides.entries)
        e.key: e.value.toJson(),
    },
    'variants': <Map<String, Object?>>[
      for (final AiSrsFieldVariant v in variants) v.toJson(),
    ],
  };

  @override
  bool operator ==(Object other) {
    if (other is! AiSrsFieldActions) return false;
    if (other.overrides.length != overrides.length) return false;
    for (final MapEntry<String, AiSrsFieldPromptOverride> e
        in overrides.entries) {
      if (other.overrides[e.key] != e.value) return false;
    }
    if (other.variants.length != variants.length) return false;
    for (int i = 0; i < variants.length; i++) {
      if (other.variants[i] != variants[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
    Object.hashAllUnordered(
      overrides.entries.map(
        (MapEntry<String, AiSrsFieldPromptOverride> e) =>
            Object.hash(e.key, e.value),
      ),
    ),
    Object.hashAll(variants),
  );
}

/// 编码成偏好值；没有任何改动编码成空串（偏好里不留默认值）。
String encodeAiSrsFieldActions(AiSrsFieldActions actions) =>
    actions.isEmpty ? '' : jsonEncode(actions.toJson());

/// 解码偏好值：空串 = 没有改动；整串不是 JSON 对象抛 [FormatException]（调用方记日志）；
/// 单条坏掉只丢那一条；变体 id 重复只留第一条。
AiSrsFieldActions decodeAiSrsFieldActions(String raw) {
  if (raw.trim().isEmpty) return AiSrsFieldActions.empty;
  final Object? decoded = jsonDecode(raw);
  if (decoded is! Map) {
    throw const FormatException('ai_field_actions is not a JSON object');
  }
  final Map<String, AiSrsFieldPromptOverride> overrides =
      <String, AiSrsFieldPromptOverride>{};
  final Object? rawOverrides = decoded['overrides'];
  if (rawOverrides is Map) {
    for (final MapEntry<Object?, Object?> e in rawOverrides.entries) {
      final Object? key = e.key;
      if (key is! String || key.isEmpty) continue;
      final AiSrsFieldPromptOverride? override =
          AiSrsFieldPromptOverride.fromJson(e.value);
      if (override != null) overrides[key] = override;
    }
  }
  final List<AiSrsFieldVariant> variants = <AiSrsFieldVariant>[];
  final Set<String> seen = <String>{};
  final Object? rawVariants = decoded['variants'];
  if (rawVariants is List) {
    for (final Object? item in rawVariants) {
      final AiSrsFieldVariant? v = AiSrsFieldVariant.fromJson(item);
      if (v == null || !seen.add(v.id)) continue;
      variants.add(v);
    }
  }
  return AiSrsFieldActions(
    overrides: Map<String, AiSrsFieldPromptOverride>.unmodifiable(overrides),
    variants: List<AiSrsFieldVariant>.unmodifiable(variants),
  );
}

/// 存取接口（[PreferencesRepository] 实现；测试可注入内存实现）。
abstract interface class AiSrsFieldActionStore {
  AiSrsFieldActions get aiFieldActions;

  /// 整份覆盖写回。
  Future<void> setAiFieldActions(AiSrsFieldActions actions);
}

/// `{{名字}}` 占位符（名字两侧空白忽略）。
final RegExp kAiSrsFieldPlaceholderPattern = RegExp(r'\{\{\s*([^{}]+?)\s*\}\}');

/// 代入占位符（一趟替换，代入的字段内容里再出现 `{{…}}` 不会被二次展开）：
/// - `{{output_language}}` → [outputLanguage]（语言名）；
/// - `{{target_field}}` → [targetField]（正在写的字段的显示名）；
/// - `{{字段名}}` → 该字段的内容，经 [aiSrsFieldSample] 整理（保留目标词 `<b>`），上限
///   [kAiSrsFieldMax]；字段为空代入 [kAiSrsFieldEmptyFieldValue]；
/// - 认不出的原样保留。
String aiSrsFieldResolvePlaceholders(
  String text, {
  required String outputLanguage,
  required String targetField,
  required Map<String, String> fieldValuesByName,
}) => text.replaceAllMapped(kAiSrsFieldPlaceholderPattern, (Match m) {
  final String name = m.group(1)!;
  if (name == kAiSrsFieldOutputLanguagePlaceholder) return outputLanguage;
  if (name == kAiSrsFieldTargetFieldPlaceholder) return targetField;
  final String? value = fieldValuesByName[name];
  if (value == null) return m.group(0)!;
  final String sample = aiSrsFieldSample(value, max: kAiSrsFieldMax);
  return sample.isEmpty ? kAiSrsFieldEmptyFieldValue : sample;
});

/// [text] 里认不出的占位符名（去重，按出现顺序）：既不是保留名，也不是 [fieldNames] 里的字段。
List<String> aiSrsFieldUnknownPlaceholders(
  String text,
  Iterable<String> fieldNames,
) {
  final Set<String> known = <String>{
    kAiSrsFieldOutputLanguagePlaceholder,
    kAiSrsFieldTargetFieldPlaceholder,
    ...fieldNames,
  };
  final Set<String> out = <String>{};
  for (final RegExpMatch m in kAiSrsFieldPlaceholderPattern.allMatches(text)) {
    final String name = m.group(1)!;
    if (!known.contains(name)) out.add(name);
  }
  return out.toList();
}

/// 拼一次请求的系统消息与用户消息（生产与编辑页预览同一份）。
///
/// [outputLanguage] 是语言**名**（不是标签）。[fields] 的样例照旧截到
/// [kAiSrsFieldSampleMax]；模板里引用的字段按 [kAiSrsFieldMax] 代入。
AiSrsFieldPrompt buildAiSrsFieldPrompt({
  required String noteTypeName,
  required List<SrsFieldDef> fields,
  required Map<String, String> valuesById,
  required String targetFieldId,
  required AiSrsFieldAction action,
  required AiSrsFieldActions actions,
  required String instruction,
  required String outputLanguage,
}) {
  final SrsFieldDef? target = fields
      .where((SrsFieldDef f) => f.id == targetFieldId)
      .firstOrNull;
  final Map<String, String> byName = <String, String>{
    for (final SrsFieldDef f in fields) f.name: valuesById[f.id] ?? '',
  };
  String resolve(String text) => aiSrsFieldResolvePlaceholders(
    text,
    outputLanguage: outputLanguage,
    targetField: target == null ? targetFieldId : srsFieldDisplayName(target),
    fieldValuesByName: byName,
  );
  return AiSrsFieldPrompt(
    system: aiSrsFieldSystemMessage(
      resolve(actions.textOf(kAiSrsFieldSystemTemplateId)),
    ),
    user: buildAiSrsFieldUserPrompt(
      noteTypeName: noteTypeName,
      fields: <AiSrsFieldBrief>[
        for (final SrsFieldDef f in fields)
          AiSrsFieldBrief.of(
            f,
            sample: aiSrsFieldSample(valuesById[f.id] ?? ''),
          ),
      ],
      targetFieldId: targetFieldId,
      taskText: resolve(actions.taskTextOf(action)),
      instruction: instruction,
      outputLanguage: outputLanguage,
    ),
  );
}

/// 字段 AI 抽屉里内置的「已保存的提示词」预设按任务筛选（只管
/// [AiPromptScene.srsField] 的内置；用户保存的不筛）：`concise` → 释义 / 改写，
/// `list` / `sense` / `monolingual` → 释义，`example` → 自定义 / 改写，
/// `literal` / `nuance` → 翻译。
bool aiSrsFieldBuiltinPresetVisible(AiSavedPrompt prompt, AiSrsFieldTask task) {
  final String prefix =
      '$kAiBuiltinPromptIdPrefix${AiPromptScene.srsField.wire}:';
  if (!prompt.isBuiltin || !prompt.id.startsWith(prefix)) return true;
  final String slug = prompt.id.substring(prefix.length);
  return switch (slug) {
    'concise' =>
      task == AiSrsFieldTask.define || task == AiSrsFieldTask.rewrite,
    'list' || 'sense' || 'monolingual' => task == AiSrsFieldTask.define,
    'literal' || 'nuance' => task == AiSrsFieldTask.translate,
    'example' =>
      task == AiSrsFieldTask.custom || task == AiSrsFieldTask.rewrite,
    _ => true,
  };
}
