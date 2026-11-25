/// 卡片字段 AI 的「可编辑动作」：四个内置动作（写释义 / 翻译 / 改写 / 自定义）各有一份
/// 模板（= 用户消息）、AI 说明（= 系统消息里用户可改的部分）与回复格式，可原地改、可恢复默认；
/// 任何动作都可复制成具名变体（只属于一个任务，可改名 / 改三部分 / 删除）。
///
/// 边界：
/// - 「写的就是发的」：模板就是用户消息，代码只代入占位符（`buildAiSrsFieldRequest`）；系统
///   消息末尾的应用规则固定（`aiSrsFieldAppRules`），用户改不到。没有全局「总体说明」。
/// - 持久化走偏好键 [kAiFieldActionsPrefKey]（一份 JSON，`"v": 2`）：没有条目 = 用内置；
///   **不把默认值抄进存储**（改回与内置相同 = 删掉这条覆盖）。逐条容错，坏条目只丢它自己。
///   旧形状（P1：没有 `v`，覆盖 / 变体只有一段任务正文，另有全局 `system` 说明）按
///   [decodeAiSrsFieldActions] 的规则确定性迁移。
/// - 覆盖记下它基于的内置版本（[AiSrsFieldPromptOverride.baseVersion]）：内置版本更新后编辑页
///   提示「内置提示词更新过」。不用哈希——以后内置文案可能本地化，哈希会误报。
library;

import 'dart:convert';
import 'dart:math';

import 'package:fushi/src/ai/ai_saved_prompts.dart'
    show AiPromptScene, AiSavedPrompt, kAiBuiltinPromptIdPrefix;
import 'package:fushi/src/ai/ai_srs_field_assistant.dart';
import 'package:fushi/src/ai/ai_srs_field_reply.dart';

/// 偏好键：卡片字段 AI 的动作覆盖与变体（JSON 对象）。
const String kAiFieldActionsPrefKey = 'ai_field_actions';

/// 存储形状的版本（`"v"`）。没有 `v` = P1 形状。
const int kAiFieldActionsStorageVersion = 2;

/// 模板 / AI 说明各自的长度上限（字符）。
const int kAiSrsFieldPromptMax = 4000;

/// 变体名称长度上限（字符）。
const int kAiSrsFieldVariantNameMax = 60;

/// 内置的 AI 说明（四个内置动作共用的默认值；每个动作各存各的）。只放各模板都要的四件事：
/// 角色（只写一个字段）、`<b>` 的含义、语言规则、以笔记为准；具体任务的规则在模板里。
const String kAiSrsFieldGuidance = '''
You edit ONE field of a language learner's flashcard note. Write only that field's new content.

In the note, <b>…</b> marks the target word.

Definitions, translations and explanations are written in {{output_language}}. A new example sentence, or any other text in the language being learned, is written in the language of the note's sentence, unless the instruction says otherwise.

Ground your answer in the note: prefer its dictionary fields over your own knowledge, and never invent senses, readings or facts it doesn't support.''';

/// 内置模板末尾「用户补充要求」一段（自定义除外）。
const String _kInstructionTail = '''
Extra instruction (may be "(none)"):
{{instruction}}''';

/// 内置「写释义」模板。四个内置模板同一形状：一行任务 → 笔记 → 要写的字段 → 规则 → 补充要求
/// （自定义的要求就是任务，放最前）。
const String kAiSrsFieldDefineTemplate = '''
Write the definition of this note's headword in {{output_language}}.

Note:
{{note}}

Field to write: {{target_field}}

Rules:
- Take the senses from the note's dictionary fields when it has them.
- Put the sense used in the sentence first, in <b>…</b>. Number the senses if there are several.
- "value": the definition only.
- "explanation": one short sentence on which sense the sentence uses.

$_kInstructionTail''';

/// 内置「翻译例句」模板。规则按两类真实难句定：省略主语 / 宾语的整句
/// （`それに気づいた時 完全に嫌いになった`）与带句末语气词的残句（`うっかりかあ`）。
const String kAiSrsFieldTranslateTemplate = '''
Translate the example sentence of this note into {{output_language}}.

Note:
{{note}}

Field to write: {{target_field}}

Rules:
- Translate only the sentence; use the other fields only to understand it.
- Faithful first, natural second. Keep tone and register; don't add, drop, soften or explain.
- Keep fragments and trailing lines as fragments ("うっかりかあ" → "Careless of me, huh…", not "I accidentally did it.").
- Add a missing subject/object only if the sentence needs one; if the note doesn't settle it, use a neutral one and name the guess in "explanation".
- Translate sentence-final particles ("huh", "right", "…") instead of dropping them.
- Bold the words that translate the <b> part. No <b> in the sentence: find the headword (or an inflected form); if unsure, bold nothing and say so in "explanation". Never bold the whole sentence.
- "value": the translation only, one line.
- "explanation": one short sentence naming any guess or ambiguity, or saying the translation is direct.

$_kInstructionTail''';

/// 内置「改写」模板（任务行已点名字段，不再单列「要写的字段」）。
const String kAiSrsFieldRewriteTemplate = '''
Improve the field "{{target_field}}" of this note: clearer and shorter, same meaning.

Note:
{{note}}

Rules:
- Never change the meaning. Keep tone and register unless the instruction says otherwise.
- Don't add anything the note doesn't support; don't drop important details.
- Keep quotes of the note's sentence or headword word for word.
- "explanation": one short sentence on what you changed.

$_kInstructionTail''';

/// 内置「自定义」模板（纯文本回复）：用户的一句话就是任务，放最前；后面附上要写的字段与笔记
/// （不要可以删）。
const String kAiSrsFieldCustomTemplate = '''
{{instruction}}

Field to write: {{target_field}}

Note:
{{note}}''';

/// 一个内置动作。[id] 与 [version] 都**冻结**：id 是落盘键；改了模板 / 说明 / 回复格式中任何
/// 一样就把 [version] 加一，基于旧版本改过的用户才会看到「内置提示词更新过」。
class AiSrsFieldTemplate {
  const AiSrsFieldTemplate({
    required this.id,
    required this.version,
    required this.task,
    required this.prompt,
  });

  final String id;
  final int version;
  final AiSrsFieldTask task;
  final AiSrsFieldActionPrompt prompt;
}

/// 四个内置动作（按 [AiSrsFieldTask] 的顺序）。
///
/// v3（「写的就是发的」）：模板写成完整可见的用户消息（笔记经 `{{note}}` 代入），AI 说明按动作
/// 存，自定义改成纯文本回复。P1 的覆盖（版本 ≤ 2）迁移后都会看到更新提示。
/// v4：四个模板统一形状、规则收紧，AI 说明只留角色 / `<b>` / 语言 / 以笔记为准。
const List<AiSrsFieldTemplate> kAiSrsFieldTemplates = <AiSrsFieldTemplate>[
  AiSrsFieldTemplate(
    id: 'task.define',
    version: 4,
    task: AiSrsFieldTask.define,
    prompt: AiSrsFieldActionPrompt(
      template: kAiSrsFieldDefineTemplate,
      guidance: kAiSrsFieldGuidance,
      mode: AiSrsFieldResponseMode.structured,
    ),
  ),
  AiSrsFieldTemplate(
    id: 'task.translate',
    version: 4,
    task: AiSrsFieldTask.translate,
    prompt: AiSrsFieldActionPrompt(
      template: kAiSrsFieldTranslateTemplate,
      guidance: kAiSrsFieldGuidance,
      mode: AiSrsFieldResponseMode.structured,
    ),
  ),
  AiSrsFieldTemplate(
    id: 'task.rewrite',
    version: 4,
    task: AiSrsFieldTask.rewrite,
    prompt: AiSrsFieldActionPrompt(
      template: kAiSrsFieldRewriteTemplate,
      guidance: kAiSrsFieldGuidance,
      mode: AiSrsFieldResponseMode.structured,
    ),
  ),
  AiSrsFieldTemplate(
    id: 'task.custom',
    version: 4,
    task: AiSrsFieldTask.custom,
    prompt: AiSrsFieldActionPrompt(
      template: kAiSrsFieldCustomTemplate,
      guidance: kAiSrsFieldGuidance,
      mode: AiSrsFieldResponseMode.plain,
    ),
  ),
];

/// 按 id 找内置动作；认不出返回 null。
AiSrsFieldTemplate? aiSrsFieldTemplateById(String id) {
  for (final AiSrsFieldTemplate template in kAiSrsFieldTemplates) {
    if (template.id == id) return template;
  }
  return null;
}

/// [task] 的内置动作。
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

AiSrsFieldActionPrompt _capPrompt(AiSrsFieldActionPrompt p) =>
    AiSrsFieldActionPrompt(
      template: _capText(p.template),
      guidance: _capText(p.guidance),
      mode: p.mode,
    );

Map<String, Object?> _promptJson(AiSrsFieldActionPrompt p) => <String, Object?>{
  'template': p.template,
  'guidance': p.guidance,
  'mode': aiSrsFieldResponseModeWire(p.mode),
};

/// v2 条目里的三部分：模板必须是字符串；说明缺失当空；回复格式认不出 / 缺失当 structured。
AiSrsFieldActionPrompt? _promptFromJson(Map<Object?, Object?> raw) {
  final Object? template = raw['template'];
  final Object? guidance = raw['guidance'];
  final Object? mode = raw['mode'];
  if (template is! String) return null;
  return _capPrompt(
    AiSrsFieldActionPrompt(
      template: template,
      guidance: guidance is String ? guidance : '',
      mode:
          aiSrsFieldResponseModeFromWire(mode is String ? mode : null) ??
          AiSrsFieldResponseMode.structured,
    ),
  );
}

/// 用户对一个内置动作的改动（三部分整份存）。
class AiSrsFieldPromptOverride {
  const AiSrsFieldPromptOverride({
    required this.prompt,
    required this.baseVersion,
  });

  final AiSrsFieldActionPrompt prompt;

  /// 改动时内置动作的版本。
  final int baseVersion;

  Map<String, Object?> toJson() => <String, Object?>{
    ..._promptJson(prompt),
    'baseVersion': baseVersion,
  };

  /// 逐条容错：不是对象 / 模板不是字符串返回 null；版本缺失当 0（= 比任何内置都旧）。
  static AiSrsFieldPromptOverride? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final AiSrsFieldActionPrompt? prompt = _promptFromJson(raw);
    if (prompt == null) return null;
    final Object? version = raw['baseVersion'];
    return AiSrsFieldPromptOverride(
      prompt: prompt,
      baseVersion: version is int ? version : 0,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AiSrsFieldPromptOverride &&
      other.prompt == prompt &&
      other.baseVersion == baseVersion;

  @override
  int get hashCode => Object.hash(prompt, baseVersion);
}

/// 用户复制出来的具名变体，只属于一个任务。
class AiSrsFieldVariant {
  const AiSrsFieldVariant({
    required this.id,
    required this.taskWire,
    required this.name,
    required this.prompt,
  });

  final String id;

  /// 所属任务的落盘值；认不出（新版本写的）原样保留，只是本版本不显示。
  final String taskWire;
  final String name;
  final AiSrsFieldActionPrompt prompt;

  AiSrsFieldTask? get task => aiSrsFieldTaskFromWire(taskWire);

  AiSrsFieldVariant copyWith({String? name, AiSrsFieldActionPrompt? prompt}) =>
      AiSrsFieldVariant(
        id: id,
        taskWire: taskWire,
        name: name ?? this.name,
        prompt: prompt ?? this.prompt,
      );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'task': taskWire,
    ..._promptJson(prompt),
  };

  /// 逐条容错：字段缺失 / 类型不对 / id 为空返回 null（只丢这一条）。
  static AiSrsFieldVariant? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? id = raw['id'];
    final Object? task = raw['task'];
    final Object? name = raw['name'];
    if (id is! String || id.isEmpty) return null;
    if (task is! String || task.isEmpty) return null;
    if (name is! String) return null;
    final AiSrsFieldActionPrompt? prompt = _promptFromJson(raw);
    if (prompt == null) return null;
    return AiSrsFieldVariant(
      id: id,
      taskWire: task,
      name: _capName(name),
      prompt: prompt,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AiSrsFieldVariant &&
      other.id == id &&
      other.taskWire == taskWire &&
      other.name == name &&
      other.prompt == prompt;

  @override
  int get hashCode => Object.hash(id, taskWire, name, prompt);

  @override
  String toString() => 'AiSrsFieldVariant($id, $taskWire, $name)';
}

/// 抽屉里选中的动作：一个任务 + 可选的变体（null = 用该任务的内置动作，原样或改过的）。
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

  /// 内置动作 id → 覆盖。认不出的 id（新版本写的）原样保留。
  final Map<String, AiSrsFieldPromptOverride> overrides;
  final List<AiSrsFieldVariant> variants;

  bool get isEmpty => overrides.isEmpty && variants.isEmpty;

  /// 内置动作当前生效的三部分（覆盖优先，否则内置）；认不出的 id 返回 null。
  AiSrsFieldActionPrompt? promptOf(String templateId) =>
      overrides[templateId]?.prompt ??
      aiSrsFieldTemplateById(templateId)?.prompt;

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

  /// [action] 实际要用的三部分：变体存在且属于该任务就用变体，否则用该任务的内置动作。
  AiSrsFieldActionPrompt promptFor(AiSrsFieldAction action) {
    final String? variantId = action.variantId;
    final AiSrsFieldVariant? v = variantId == null ? null : variant(variantId);
    if (v != null && v.task == action.task) return v.prompt;
    return promptOf(aiSrsFieldTaskTemplate(action.task).id)!;
  }

  /// 改一个内置动作：与内置相同 = 删掉覆盖（不把默认值抄进存储）；超长截断；版本记成当前
  /// 内置版本（编辑页看着提示改的，就算看过新版）。认不出的 id 原样返回。
  AiSrsFieldActions withTemplatePrompt(
    String templateId,
    AiSrsFieldActionPrompt prompt,
  ) {
    final AiSrsFieldTemplate? template = aiSrsFieldTemplateById(templateId);
    if (template == null) return this;
    final AiSrsFieldActionPrompt capped = _capPrompt(prompt);
    final Map<String, AiSrsFieldPromptOverride> next =
        Map<String, AiSrsFieldPromptOverride>.of(overrides);
    if (capped == template.prompt) {
      next.remove(templateId);
    } else {
      next[templateId] = AiSrsFieldPromptOverride(
        prompt: capped,
        baseVersion: template.version,
      );
    }
    return AiSrsFieldActions(overrides: next, variants: variants);
  }

  /// 恢复默认：删掉覆盖（三部分一起回到内置）。
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
    required AiSrsFieldActionPrompt prompt,
    String? id,
  }) {
    final AiSrsFieldVariant created = AiSrsFieldVariant(
      id: id ?? _newVariantId(),
      taskWire: aiSrsFieldTaskWire(task),
      name: _capName(name),
      prompt: _capPrompt(prompt),
    );
    return (
      AiSrsFieldActions(
        overrides: overrides,
        variants: <AiSrsFieldVariant>[...variants, created],
      ),
      created,
    );
  }

  /// 改变体的名称 / 三部分（只改给出的）。
  AiSrsFieldActions updateVariant(
    String id, {
    String? name,
    AiSrsFieldActionPrompt? prompt,
  }) => AiSrsFieldActions(
    overrides: overrides,
    variants: <AiSrsFieldVariant>[
      for (final AiSrsFieldVariant v in variants)
        v.id == id
            ? v.copyWith(
                name: name == null ? null : _capName(name),
                prompt: prompt == null ? null : _capPrompt(prompt),
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
    'v': kAiFieldActionsStorageVersion,
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

/// P1 的一段任务正文 [text] 迁移成完整模板：P1 每次请求都在任务行前给笔记、要写的字段与输出
/// 语言，后面给用户的一句话——迁移后把这些写成看得见的占位符，行为不变、用户也看得到。
String aiSrsFieldMigrateP1TaskText(String text) =>
    'Note:\n{{note}}\nField to write: {{target_field}}\n'
    'Output language: {{output_language}}\n'
    '$text\nUser instruction: {{instruction}}';

/// 解码偏好值：空串 = 没有改动；整串不是 JSON 对象抛 [FormatException]（调用方记日志）；
/// 单条坏掉只丢那一条；变体 id 重复只留第一条。
///
/// 没有 `"v"` 的是 P1 形状，确定性迁移：
/// - 任务覆盖 / 变体的正文 `T` → 模板 [aiSrsFieldMigrateP1TaskText]、回复格式 structured，
///   覆盖保留原 `baseVersion`（比 v3 旧，编辑页会提示内置更新过）；
/// - 全局 `system` 说明 `G` → 作为 AI 说明写进每条迁移出的覆盖与变体；没有任务覆盖的内置
///   动作，只在 `G` 与默认说明不同时才新建一条覆盖（模板 / 回复格式取内置）；
/// - 认不出的覆盖 id 丢掉（那是 P1 形状，本版本读不懂）。
AiSrsFieldActions decodeAiSrsFieldActions(String raw) {
  if (raw.trim().isEmpty) return AiSrsFieldActions.empty;
  final Object? decoded = jsonDecode(raw);
  if (decoded is! Map) {
    throw const FormatException('ai_field_actions is not a JSON object');
  }
  return decoded.containsKey('v') ? _decodeV2(decoded) : _decodeP1(decoded);
}

AiSrsFieldActions _decodeV2(Map<Object?, Object?> decoded) {
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

/// P1 的条目：`{"text": "...", "baseVersion": n}`；不是对象 / 正文不是字符串返回 null。
(String, int)? _p1Entry(Object? raw) {
  if (raw is! Map) return null;
  final Object? text = raw['text'];
  final Object? version = raw['baseVersion'];
  if (text is! String) return null;
  return (text, version is int ? version : 0);
}

AiSrsFieldActions _decodeP1(Map<Object?, Object?> decoded) {
  final Object? rawOverrides = decoded['overrides'];
  final Map<Object?, Object?> p1Overrides = rawOverrides is Map
      ? rawOverrides
      : const <Object?, Object?>{};
  final (String, int)? system = _p1Entry(p1Overrides['system']);
  final String? p1Guidance = system?.$1;

  AiSrsFieldActionPrompt migrated(String text) => _capPrompt(
    AiSrsFieldActionPrompt(
      template: aiSrsFieldMigrateP1TaskText(text),
      guidance: p1Guidance ?? kAiSrsFieldGuidance,
      mode: AiSrsFieldResponseMode.structured,
    ),
  );

  final Map<String, AiSrsFieldPromptOverride> overrides =
      <String, AiSrsFieldPromptOverride>{};
  for (final AiSrsFieldTemplate template in kAiSrsFieldTemplates) {
    final (String, int)? entry = _p1Entry(p1Overrides[template.id]);
    if (entry != null) {
      overrides[template.id] = AiSrsFieldPromptOverride(
        prompt: migrated(entry.$1),
        baseVersion: entry.$2,
      );
    } else if (p1Guidance != null && p1Guidance != template.prompt.guidance) {
      overrides[template.id] = AiSrsFieldPromptOverride(
        prompt: _capPrompt(template.prompt.copyWith(guidance: p1Guidance)),
        baseVersion: system!.$2,
      );
    }
  }

  final List<AiSrsFieldVariant> variants = <AiSrsFieldVariant>[];
  final Set<String> seen = <String>{};
  final Object? rawVariants = decoded['variants'];
  if (rawVariants is List) {
    for (final Object? item in rawVariants) {
      if (item is! Map) continue;
      final Object? id = item['id'];
      final Object? task = item['task'];
      final Object? name = item['name'];
      final Object? text = item['text'];
      if (id is! String || id.isEmpty) continue;
      if (task is! String || task.isEmpty) continue;
      if (name is! String || text is! String) continue;
      if (!seen.add(id)) continue;
      variants.add(
        AiSrsFieldVariant(
          id: id,
          taskWire: task,
          name: _capName(name),
          prompt: migrated(text),
        ),
      );
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

/// 按 [actions] 里 [action] 的三部分给 [note] 拼一次请求（抽屉的生成与编辑页预览同一份）。
AiSrsFieldRequest buildAiSrsFieldActionRequest({
  required AiSrsFieldNoteContext note,
  required AiSrsFieldActions actions,
  required AiSrsFieldAction action,
  required String instruction,
}) => buildAiSrsFieldRequest(
  note: note,
  prompt: actions.promptFor(action),
  instruction: instruction,
);

/// 字段 AI 抽屉里内置的「已保存的提示词」预设按任务筛选（只管
/// [AiPromptScene.srsField] 的内置；用户保存的不筛）。预设都是填进 `{{instruction}}` 的短修饰语：
/// `simpler` → 全部任务；`shorter` → 除翻译外（译文求忠实，不该为了短而删内容）；
/// `casual` / `formal` / `target_nuance` → 翻译；`one_sense` / `add_example` → 释义；
/// `format_only` → 改写。认不出的 slug 照常显示。
bool aiSrsFieldBuiltinPresetVisible(AiSavedPrompt prompt, AiSrsFieldTask task) {
  final String prefix =
      '$kAiBuiltinPromptIdPrefix${AiPromptScene.srsField.wire}:';
  if (!prompt.isBuiltin || !prompt.id.startsWith(prefix)) return true;
  final String slug = prompt.id.substring(prefix.length);
  return switch (slug) {
    'simpler' => true,
    'shorter' => task != AiSrsFieldTask.translate,
    'casual' || 'formal' || 'target_nuance' => task == AiSrsFieldTask.translate,
    'one_sense' || 'add_example' => task == AiSrsFieldTask.define,
    'format_only' => task == AiSrsFieldTask.rewrite,
    _ => true,
  };
}
