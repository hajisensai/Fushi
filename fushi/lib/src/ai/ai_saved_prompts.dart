/// 「已保存的提示词」库（反馈 _LLhOKwmI3）：各 AI 功能的提示词输入框共用一套
/// 可保存、命名、删除、复用的提示词，外加每个场景几条内置预设。
///
/// 边界：
/// - 只是**输入框的文本来源**：选中一条 = 把文字填进原来的输入框，用户照常点生成；
///   本库不发任何 AI 请求，也不改各功能的提示词拼装。
/// - 持久化走偏好键 [kAiSavedPromptsPrefKey]（一份 JSON 列表），不建表。
/// - 用户条目按场景归属（[AiSavedPrompt.sceneWire]），`null` = 所有 AI 功能通用。
///   认不出的场景（新版本写的）原样保留，只是在本版本里不显示，重存不丢。
/// - 内置预设不落盘：文案走 i18n，每次现取，不能删改。
library;

import 'dart:convert';
import 'dart:math';

import 'package:fushi/utils.dart';

/// 偏好键：用户保存的提示词（JSON 列表）。
const String kAiSavedPromptsPrefKey = 'ai_saved_prompts';

/// 内置预设 id 的前缀（用户条目的 id 不会以它开头）。
const String kAiBuiltinPromptIdPrefix = 'builtin:';

/// 名称长度上限（字符）。
const int kAiSavedPromptNameMax = 60;

/// 可接提示词库的 AI 入口（场景）。`wire` 是落盘值，**冻结**，别改。
enum AiPromptScene {
  /// 复习笔记编辑页的单字段 AI 改写 / 补全（`srs_field_ai_sheet.dart`）。
  srsField('srs_field'),

  /// 复习卡片模板编辑器的 AI 排版（`srs_template_editor_page.dart`）。
  srsTemplate('srs_template'),

  /// 自定义主题页的 AI 生成主题（`custom_theme_page.dart`）。
  theme('theme'),

  /// 词典样式对话框的 AI 样式（`dictionary_settings_dialog_page.dart`）。
  dictStyle('dict_style'),

  /// Lapis 卡片样式编辑器的 AI 样式（`lapis_style_editor_page.dart`）。
  lapisStyle('lapis_style'),

  /// galgame 文本处理管线编辑器的 AI 生成步骤（`gal_text_process_editor_page.dart`）。
  galTextProcess('gal_text_process');

  const AiPromptScene(this.wire);

  /// 落盘值。
  final String wire;

  /// 按落盘值找场景；认不出返回 null。
  static AiPromptScene? fromWire(String? wire) {
    if (wire == null) return null;
    for (final AiPromptScene scene in AiPromptScene.values) {
      if (scene.wire == wire) return scene;
    }
    return null;
  }
}

/// 一条提示词（用户保存的或内置预设）。
class AiSavedPrompt {
  const AiSavedPrompt({
    required this.id,
    required this.name,
    required this.text,
    this.sceneWire,
  });

  /// 稳定 id；内置预设以 [kAiBuiltinPromptIdPrefix] 开头。
  final String id;

  /// 显示名。
  final String name;

  /// 填进输入框的提示词正文。
  final String text;

  /// 归属场景的落盘值；null = 所有 AI 功能通用。
  final String? sceneWire;

  /// 归属场景；通用或认不出时为 null。
  AiPromptScene? get scene => AiPromptScene.fromWire(sceneWire);

  /// 所有 AI 功能通用。
  bool get isGeneral => sceneWire == null;

  /// 内置预设（不能删改）。
  bool get isBuiltin => id.startsWith(kAiBuiltinPromptIdPrefix);

  /// 在 [target] 场景的列表里是否显示。
  bool visibleIn(AiPromptScene target) =>
      sceneWire == null || sceneWire == target.wire;

  /// 改名。
  AiSavedPrompt renamed(String newName) =>
      AiSavedPrompt(id: id, name: newName, text: text, sceneWire: sceneWire);

  /// 改归属：[general] 为 true 变通用，否则只属于 [scene]。
  AiSavedPrompt withScope({
    required bool general,
    required AiPromptScene scene,
  }) => AiSavedPrompt(
    id: id,
    name: name,
    text: text,
    sceneWire: general ? null : scene.wire,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'text': text,
    if (sceneWire != null) 'scene': sceneWire,
  };

  /// 逐条容错：字段缺失 / 类型不对 / 正文为空返回 null（只丢这一条）。
  static AiSavedPrompt? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? id = raw['id'];
    final Object? name = raw['name'];
    final Object? text = raw['text'];
    final Object? scene = raw['scene'];
    if (id is! String ||
        id.isEmpty ||
        id.startsWith(kAiBuiltinPromptIdPrefix)) {
      return null;
    }
    if (text is! String || text.trim().isEmpty) return null;
    if (scene != null && scene is! String) return null;
    return AiSavedPrompt(
      id: id,
      name: name is String && name.trim().isNotEmpty
          ? name
          : aiSavedPromptDefaultName(text),
      text: text,
      sceneWire: scene as String?,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AiSavedPrompt &&
      other.id == id &&
      other.name == name &&
      other.text == text &&
      other.sceneWire == sceneWire;

  @override
  int get hashCode => Object.hash(id, name, text, sceneWire);

  @override
  String toString() => 'AiSavedPrompt($id, $name, scene: $sceneWire)';
}

/// 编码成偏好值。
String encodeAiSavedPrompts(Iterable<AiSavedPrompt> prompts) =>
    jsonEncode(<Map<String, Object?>>[
      for (final AiSavedPrompt p in prompts)
        if (!p.isBuiltin) p.toJson(),
    ]);

/// 解码偏好值：空串 = 空列表；整串不是 JSON 列表抛 [FormatException]（调用方记日志）；
/// 单条坏掉只丢那一条；重复 id 只留第一条。
List<AiSavedPrompt> decodeAiSavedPrompts(String raw) {
  if (raw.trim().isEmpty) return const <AiSavedPrompt>[];
  final Object? decoded = jsonDecode(raw);
  if (decoded is! List) {
    throw const FormatException('ai_saved_prompts is not a JSON list');
  }
  final Set<String> seen = <String>{};
  final List<AiSavedPrompt> out = <AiSavedPrompt>[];
  for (final Object? item in decoded) {
    final AiSavedPrompt? prompt = AiSavedPrompt.fromJson(item);
    if (prompt == null || !seen.add(prompt.id)) continue;
    out.add(prompt);
  }
  return List<AiSavedPrompt>.unmodifiable(out);
}

/// [scene] 下要显示的用户条目（该场景专属 + 通用），保持保存顺序。
List<AiSavedPrompt> aiSavedPromptsFor(
  Iterable<AiSavedPrompt> all,
  AiPromptScene scene,
) => <AiSavedPrompt>[
  for (final AiSavedPrompt p in all)
    if (p.visibleIn(scene)) p,
];

/// 由正文生成默认名：首行、折叠空白、截断到 24 字符。
String aiSavedPromptDefaultName(String text) {
  final String firstLine = text.trim().split('\n').first.trim();
  final String collapsed = firstLine.replaceAll(RegExp(r'\s+'), ' ');
  if (collapsed.length <= 24) return collapsed;
  return '${collapsed.substring(0, 24)}…';
}

final Random _idRandom = Random();

/// 把一条新提示词并进列表：同场景（含通用）里正文完全相同的已有条目只改名并挪到
/// 末尾，不重复存；否则追加。名称为空用 [aiSavedPromptDefaultName]。
List<AiSavedPrompt> addAiSavedPrompt(
  Iterable<AiSavedPrompt> existing, {
  required String name,
  required String text,
  required AiPromptScene scene,
  String? id,
}) {
  final String body = text.trim();
  if (body.isEmpty) return List<AiSavedPrompt>.of(existing);
  final String trimmedName = name.trim();
  final String finalName = trimmedName.isEmpty
      ? aiSavedPromptDefaultName(body)
      : (trimmedName.length > kAiSavedPromptNameMax
            ? trimmedName.substring(0, kAiSavedPromptNameMax)
            : trimmedName);
  final List<AiSavedPrompt> out = <AiSavedPrompt>[];
  AiSavedPrompt? same;
  for (final AiSavedPrompt p in existing) {
    if (same == null && p.visibleIn(scene) && p.text.trim() == body) {
      same = p;
      continue;
    }
    out.add(p);
  }
  out.add(
    same?.renamed(finalName) ??
        AiSavedPrompt(
          id: id ?? _newPromptId(),
          name: finalName,
          text: body,
          sceneWire: scene.wire,
        ),
  );
  return out;
}

String _newPromptId() {
  final String time = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  final String salt = _idRandom.nextInt(1 << 30).toRadixString(36);
  return 'p_${time}_$salt';
}

/// 存取接口（[PreferencesRepository] 实现；测试可注入内存实现）。
abstract interface class AiSavedPromptStore {
  /// 用户保存的全部提示词（所有场景）。
  List<AiSavedPrompt> get aiSavedPrompts;

  /// 整份覆盖写回。
  Future<void> setAiSavedPrompts(Iterable<AiSavedPrompt> prompts);
}

AiSavedPrompt _builtin(
  AiPromptScene scene,
  String slug,
  String name,
  String text,
) => AiSavedPrompt(
  id: '$kAiBuiltinPromptIdPrefix${scene.wire}:$slug',
  name: name,
  text: text,
  sceneWire: scene.wire,
);

/// [scene] 的内置预设（当前语言）。不含任何自动注音类预设（功能黑名单）。
List<AiSavedPrompt> aiBuiltinPrompts(AiPromptScene scene) => switch (scene) {
  AiPromptScene.srsField => <AiSavedPrompt>[
    _builtin(
      scene,
      'concise',
      t.ai_prompt_preset_srs_field_concise_name,
      t.ai_prompt_preset_srs_field_concise_text,
    ),
    _builtin(
      scene,
      'example',
      t.ai_prompt_preset_srs_field_example_name,
      t.ai_prompt_preset_srs_field_example_text,
    ),
    _builtin(
      scene,
      'list',
      t.ai_prompt_preset_srs_field_list_name,
      t.ai_prompt_preset_srs_field_list_text,
    ),
  ],
  AiPromptScene.srsTemplate => <AiSavedPrompt>[
    _builtin(
      scene,
      'word',
      t.ai_prompt_preset_srs_template_word_name,
      t.ai_prompt_preset_srs_template_word_text,
    ),
    _builtin(
      scene,
      'sentence',
      t.ai_prompt_preset_srs_template_sentence_name,
      t.ai_prompt_preset_srs_template_sentence_text,
    ),
  ],
  AiPromptScene.theme => <AiSavedPrompt>[
    _builtin(
      scene,
      'paper',
      t.ai_prompt_preset_theme_paper_name,
      t.ai_prompt_preset_theme_paper_text,
    ),
    _builtin(
      scene,
      'night',
      t.ai_prompt_preset_theme_night_name,
      t.ai_prompt_preset_theme_night_text,
    ),
    _builtin(
      scene,
      'contrast',
      t.ai_prompt_preset_theme_contrast_name,
      t.ai_prompt_preset_theme_contrast_text,
    ),
  ],
  AiPromptScene.dictStyle => <AiSavedPrompt>[
    _builtin(
      scene,
      'compact',
      t.ai_prompt_preset_dict_style_compact_name,
      t.ai_prompt_preset_dict_style_compact_text,
    ),
    _builtin(
      scene,
      'headword',
      t.ai_prompt_preset_dict_style_headword_name,
      t.ai_prompt_preset_dict_style_headword_text,
    ),
  ],
  AiPromptScene.lapisStyle => <AiSavedPrompt>[
    _builtin(
      scene,
      'sentence',
      t.ai_prompt_preset_lapis_style_sentence_name,
      t.ai_prompt_preset_lapis_style_sentence_text,
    ),
    _builtin(
      scene,
      'minimal',
      t.ai_prompt_preset_lapis_style_minimal_name,
      t.ai_prompt_preset_lapis_style_minimal_text,
    ),
  ],
  AiPromptScene.galTextProcess => <AiSavedPrompt>[
    _builtin(
      scene,
      'speaker',
      t.ai_prompt_preset_gal_text_speaker_name,
      t.ai_prompt_preset_gal_text_speaker_text,
    ),
    _builtin(
      scene,
      'repeat',
      t.ai_prompt_preset_gal_text_repeat_name,
      t.ai_prompt_preset_gal_text_repeat_text,
    ),
    _builtin(
      scene,
      'codes',
      t.ai_prompt_preset_gal_text_codes_name,
      t.ai_prompt_preset_gal_text_codes_text,
    ),
  ],
};
