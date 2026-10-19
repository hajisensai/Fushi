/// 让 AI 按一句话生成 / 修改复习卡片的可视化布局，或给字段写说明。
///
/// 与其它样式助手同一条边界：AI 只产出**配置**——两面的块列表（[SrsVisualBlock]）与字段
/// 说明文字；产物只进模板编辑器草稿，用户看过预览、点保存才落库。
///
/// 本地校验（模型说什么都不直接信）：
/// - 字段块只能引用这个笔记类型**已有**的字段（按 id，或容忍按字段名）；引用不到的块丢弃。
/// - 种类 / 字号 / 对齐 / 颜色 / 显示方式只认固定枚举，认不出的取默认值。
/// - 「正面内容」块只允许出现在背面；填空显示方式只给填空类型。
/// - 文字、小标题、说明去掉 HTML 标签并截断（编译时还会再转义一次）。
/// - 某一面校验后一个块都不剩 → 这一面不改（返回 null），不让 AI 把一面清空。
library;

import 'dart:convert';

import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/ai/ai_reply_json.dart';
import 'package:fushi_srs/fushi_srs.dart';

import 'package:fushi/src/srs/srs_field_catalog.dart';
import 'package:fushi/src/srs/srs_visual_template.dart';

/// 文字块 / 小标题 / 字段说明的长度上限（字符）。
const int kAiSrsTextMax = 200;
const int kAiSrsLabelMax = 40;

/// AI 给出的一组修改。
class AiSrsTemplateSuggestion {
  const AiSrsTemplateSuggestion({
    this.front,
    this.back,
    this.fieldDescriptions = const <String, String>{},
    this.explanation = '',
  });

  /// 正面的新块；null = 正面不改。
  final List<SrsVisualBlock>? front;

  /// 背面的新块；null = 背面不改。
  final List<SrsVisualBlock>? back;

  /// fieldId → 新说明（只含已有字段）。
  final Map<String, String> fieldDescriptions;

  /// AI 的一句话说明，直接显示给用户。
  final String explanation;

  bool get isEmpty =>
      front == null && back == null && fieldDescriptions.isEmpty;
}

/// 提示词里的一个字段。
class AiSrsFieldBrief {
  const AiSrsFieldBrief({
    required this.id,
    required this.name,
    this.meaning = '',
    this.sample = '',
  });

  factory AiSrsFieldBrief.of(SrsFieldDef field, {String sample = ''}) =>
      AiSrsFieldBrief(
        id: field.id,
        name: field.name,
        meaning: srsFieldDisplayDescription(field),
        sample: sample,
      );

  final String id;
  final String name;

  /// 字段说明（用户写的或内置说明）。
  final String meaning;

  /// 一条示例内容（已去标签、截断）。
  final String sample;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    if (meaning.isNotEmpty) 'meaning': meaning,
    if (sample.isNotEmpty) 'sample': sample,
  };
}

/// 去掉 HTML 标签、折叠空白、截断。
String aiSrsPlainText(String raw, int max) {
  final String s = raw
      .replaceAll(RegExp(r'<[^>]*>'), ' ')
      .replaceAll(RegExp(r'[{}]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return s.length <= max ? s : s.substring(0, max);
}

String _enumList(List<Enum> values) =>
    values.map((Enum e) => '"${e.name}"').join(', ');

/// 系统提示（布局 + 说明）。枚举清单从代码推导，与解析器认的值同源。
String buildAiSrsTemplateSystemPrompt({required bool isCloze}) =>
    '''
You design flashcard layouts for the Fushi review app (Anki-compatible note
types). You never write HTML or CSS: you emit a list of layout blocks for the
front side and the back side, and the app compiles them.

Block object keys:
- "kind": one of ${_enumList(SrsVisualBlockKind.values)}
  - "field": shows one note field (requires "field": the field id from the list)
  - "text": a fixed short text (requires "text", plain text only)
  - "divider": a horizontal line
  - "frontSide": repeats the whole front side; BACK SIDE ONLY
- "size": ${_enumList(SrsVisualSize.values)} (display = huge headword, small = notes)
- "align": ${_enumList(SrsVisualAlign.values)}
- "bold": true/false
- "tone": ${_enumList(SrsVisualTone.values)} (accent = theme colour)
- "filter" (field blocks): ${_enumList(SrsVisualFilter.values)}
  - furigana: field holds 漢字[かな] markup, show readings above kanji
  - kanji / kana: show only kanji / only the reading of such markup
  - hint: collapsed until tapped
  - cloze: ${isCloze ? 'use for the cloze text field' : 'NOT available for this note type'}
- "label": optional small caption above a field block (max $kAiSrsLabelMax chars)
- "boxed": true/false, puts the block on a subtle tinted box
- "hideWhenEmpty": true/false (default true)

Rules:
- The front must test recall: do not put the answer (meaning, reading) on the
  front unless the user asks for it.
- Fields that are switches or raw data (meaning says so) are usually not shown.
- Only reference field ids that exist in the field list.

Answer with a single JSON object and nothing else:
{"explanation": "...", "front": [blocks], "back": [blocks], "fieldDescriptions": {"<field id>": "..."}}
- Omit "front" or "back" to keep that side unchanged.
- "fieldDescriptions" is optional: short, plain explanations of what a field
  holds and where it appears (max $kAiSrsTextMax chars each), only when asked
  or when a field has no meaning yet.
- "explanation" and all descriptions/labels/texts must be written in the same
  language the user wrote in.
''';

/// 用户侧提示：请求 + 字段清单 + 当前布局（让模型做相对修改）。
String buildAiSrsTemplateUserPrompt({
  required String request,
  required String noteTypeName,
  required List<AiSrsFieldBrief> fields,
  required List<SrsVisualBlock>? currentFront,
  required List<SrsVisualBlock>? currentBack,
}) {
  final StringBuffer b = StringBuffer()
    ..writeln('Request: $request')
    ..writeln('Note type: $noteTypeName')
    ..writeln(
      'Fields: ${jsonEncode(<Map<String, Object?>>[for (final AiSrsFieldBrief f in fields) f.toJson()])}',
    );
  if (currentFront != null) {
    b.writeln('Current front: ${jsonEncode(_blocksForAi(currentFront))}');
  }
  if (currentBack != null) {
    b.writeln('Current back: ${jsonEncode(_blocksForAi(currentBack))}');
  }
  return b.toString();
}

/// 当前布局喂给模型时用与回复相同的可读键名（不是持久化的短键）。
List<Map<String, Object?>> _blocksForAi(List<SrsVisualBlock> blocks) =>
    <Map<String, Object?>>[
      for (final SrsVisualBlock x in blocks)
        <String, Object?>{
          'kind': x.kind.name,
          if (x.fieldId != null) 'field': x.fieldId,
          if (x.text.isNotEmpty) 'text': x.text,
          if (x.label.isNotEmpty) 'label': x.label,
          'size': x.size.name,
          'align': x.align.name,
          if (x.bold) 'bold': true,
          if (x.tone != SrsVisualTone.normal) 'tone': x.tone.name,
          if (x.filter != SrsVisualFilter.plain) 'filter': x.filter.name,
          if (x.boxed) 'boxed': true,
          if (!x.hideWhenEmpty) 'hideWhenEmpty': false,
        },
    ];

T? _enumFrom<T extends Enum>(List<T> values, Object? raw) {
  if (raw is! String) return null;
  final String folded = raw.trim().toLowerCase().replaceAll(
    RegExp(r'[-_\s]'),
    '',
  );
  for (final T v in values) {
    if (v.name.toLowerCase() == folded) return v;
  }
  return null;
}

bool? _bool(Object? raw) => raw is bool
    ? raw
    : raw is String
    ? raw.trim().toLowerCase() == 'true'
    : null;

/// 校验一面。[back] 决定「正面内容」块是否合法；全部丢光返回 null。
List<SrsVisualBlock>? _parseSide(
  Object? raw, {
  required bool back,
  required bool isCloze,
  required List<SrsFieldDef> fields,
}) {
  if (raw is! List) return null;
  final Map<String, String> idByLowerName = <String, String>{
    for (final SrsFieldDef f in fields) f.name.toLowerCase(): f.id,
  };
  final Set<String> ids = <String>{for (final SrsFieldDef f in fields) f.id};
  final List<SrsVisualBlock> out = <SrsVisualBlock>[];
  for (final Object? item in raw) {
    if (item is! Map) continue;
    final SrsVisualBlockKind? kind = _enumFrom(
      SrsVisualBlockKind.values,
      item['kind'],
    );
    if (kind == null) continue;
    if (kind == SrsVisualBlockKind.frontSide && !back) continue;
    String? fieldId;
    if (kind == SrsVisualBlockKind.field) {
      final Object? f = item['field'];
      if (f is! String) continue;
      fieldId = ids.contains(f) ? f : idByLowerName[f.trim().toLowerCase()];
      if (fieldId == null) continue;
    }
    final String text = item['text'] is String
        ? aiSrsPlainText(item['text'] as String, kAiSrsTextMax)
        : '';
    if (kind == SrsVisualBlockKind.text && text.isEmpty) continue;
    SrsVisualFilter filter =
        _enumFrom(SrsVisualFilter.values, item['filter']) ??
        SrsVisualFilter.plain;
    if (filter == SrsVisualFilter.cloze && !isCloze) {
      filter = SrsVisualFilter.plain;
    }
    out.add(
      SrsVisualBlock(
        id: '',
        kind: kind,
        fieldId: fieldId,
        text: text,
        label: item['label'] is String
            ? aiSrsPlainText(item['label'] as String, kAiSrsLabelMax)
            : '',
        size:
            _enumFrom(SrsVisualSize.values, item['size']) ?? SrsVisualSize.body,
        align:
            _enumFrom(SrsVisualAlign.values, item['align']) ??
            SrsVisualAlign.center,
        bold: _bool(item['bold']) ?? false,
        tone:
            _enumFrom(SrsVisualTone.values, item['tone']) ??
            SrsVisualTone.normal,
        filter: filter,
        boxed: _bool(item['boxed']) ?? false,
        hideWhenEmpty: _bool(item['hideWhenEmpty']) ?? true,
      ),
    );
  }
  // 正面至少要有一个字段块：只剩文字 / 分隔线的正面每张卡都一样，等于没法复习。
  if (!back &&
      !out.any((SrsVisualBlock x) => x.kind == SrsVisualBlockKind.field)) {
    return null;
  }
  return out.isEmpty ? null : srsRenumberVisualBlocks(out);
}

/// 解析模型回复。解析不出结构返回空建议。
AiSrsTemplateSuggestion parseAiSrsTemplateSuggestion(
  String reply, {
  required List<SrsFieldDef> fields,
  required bool isCloze,
}) {
  final Map<String, Object?>? decoded = decodeAiJsonObject(reply);
  if (decoded == null) return const AiSrsTemplateSuggestion();
  final Set<String> ids = <String>{for (final SrsFieldDef f in fields) f.id};
  final Map<String, String> descriptions = <String, String>{};
  final Object? rawDesc = decoded['fieldDescriptions'];
  if (rawDesc is Map) {
    for (final MapEntry<Object?, Object?> e in rawDesc.entries) {
      String? id = e.key is String ? e.key as String : null;
      if (id != null && !ids.contains(id)) {
        id = fields
            .where((SrsFieldDef f) => f.name.toLowerCase() == id!.toLowerCase())
            .firstOrNull
            ?.id;
      }
      final Object? v = e.value;
      if (id == null || v is! String) continue;
      final String text = aiSrsPlainText(v, kAiSrsTextMax);
      if (text.isNotEmpty) descriptions[id] = text;
    }
  }
  final Object? explanation = decoded['explanation'];
  return AiSrsTemplateSuggestion(
    front: _parseSide(
      decoded['front'],
      back: false,
      isCloze: isCloze,
      fields: fields,
    ),
    back: _parseSide(
      decoded['back'],
      back: true,
      isCloze: isCloze,
      fields: fields,
    ),
    fieldDescriptions: Map<String, String>.unmodifiable(descriptions),
    explanation: explanation is String ? aiSrsPlainText(explanation, 400) : '',
  );
}

/// 跑一次。失败原样抛 [AiChatFailure]（文案已脱敏），由 UI 转成提示。
Future<AiSrsTemplateSuggestion> requestAiSrsTemplate({
  required AiChatClient client,
  required AiProviderConfig provider,
  required String request,
  required SrsNoteTypeView noteType,
  Map<String, String> sampleByFieldId = const <String, String>{},
  List<SrsVisualBlock>? currentFront,
  List<SrsVisualBlock>? currentBack,
}) async {
  final String reply = await client.complete(
    provider: provider,
    messages: <AiChatMessage>[
      AiChatMessage.system(
        buildAiSrsTemplateSystemPrompt(isCloze: noteType.isCloze),
      ),
      AiChatMessage.user(
        buildAiSrsTemplateUserPrompt(
          request: request,
          noteTypeName: noteType.name,
          fields: <AiSrsFieldBrief>[
            for (final SrsFieldDef f in noteType.fields)
              AiSrsFieldBrief.of(
                f,
                sample: aiSrsPlainText(sampleByFieldId[f.id] ?? '', 80),
              ),
          ],
          currentFront: currentFront,
          currentBack: currentBack,
        ),
      ),
    ],
  );
  return parseAiSrsTemplateSuggestion(
    reply,
    fields: noteType.fields,
    isCloze: noteType.isCloze,
  );
}
