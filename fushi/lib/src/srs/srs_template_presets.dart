/// 「添加卡片模板」的起点预设：一条笔记的几张卡应当是**从不同角度考同一个词**，所以新模板不再照抄
/// 第一个模板（照抄 = 同一道题考两遍、两张卡各自排期，复习量白白翻倍，用户还很难发现），而是从这几种里选：
///
/// - 反向（产出）：正面是意思，背面是单词——考「想表达时写不写得出」；
/// - 听力：正面只放音频，背面是单词——考「听到能不能认出来」；没有音频的笔记正面为空、不出这张卡；
/// - 空白：正面先空着（不引用任何字段 = 对任何笔记都是空卡、不出卡），在模板编辑器里放上要考的内容才出卡。
///
/// 预设按这个笔记类型的字段自动映射（词条 / 释义 / 音频字段），映射不上的预设标为不可用并说明缺什么；
/// 正面与已有模板相同的预设同样不可用（[SrsTemplatePreset.duplicateOf]）。
///
/// 普通笔记类型用可视化模板的块编译（模板编辑器的可视化页能接着调）；内置 Fushi 卡片的反向 / 空白用区块
/// 布局（复习时走原生卡面、模板编辑器的区块布局里能接着调），听力正面用一段只放单词音频的 HTML（原生卡面的
/// 正面不画字段里的音频，这一面走网页卡面）；背面沿用第一个模板认得出的背面布局，认不出用默认背面。
library;

import 'package:fushi_anki/fushi_anki_core.dart'
    show
        FushiCardFieldItem,
        FushiCardFields,
        FushiCardSide,
        fushiCardBackLayoutOf,
        fushiCardTemplateFor,
        kFushiCardBackTemplate,
        templateIdsToNames,
        templateNamesToIds;
import 'package:fushi_engine/srs/srs_builtin.dart' show kSrsBuiltinFushiCardKey;
import 'package:fushi_engine/srs/srs_template_duplicates.dart'
    show srsTemplatesWithSameFront;
import 'package:fushi_srs/fushi_srs.dart';

import 'package:fushi/src/srs/srs_field_catalog.dart';
import 'package:fushi/src/srs/srs_visual_template.dart';

/// 预设的种类。
enum SrsTemplatePresetKind { reverse, listening, blank }

/// 一个预设：可用时 [front] / [back] 是存储形态（`{{fld:<id>}}` 引用）的模板正文。
class SrsTemplatePreset {
  const SrsTemplatePreset({
    required this.kind,
    this.front = '',
    this.back = '',
    this.term,
    this.meaning,
    this.audio,
    this.duplicateOf,
  });

  final SrsTemplatePresetKind kind;
  final String front;
  final String back;

  /// 映射到的词条 / 释义 / 音频字段（说明文字用；预设用不到的为 null）。
  final SrsFieldDef? term;
  final SrsFieldDef? meaning;
  final SrsFieldDef? audio;

  /// 正面与这个已有模板相同（加了也只是重复卡）；null = 不重复。
  final SrsTemplateDef? duplicateOf;

  /// 缺了必需的字段（反向缺释义 / 词条，听力缺音频 / 词条）。
  bool get missingField => switch (kind) {
    SrsTemplatePresetKind.reverse => term == null || meaning == null,
    SrsTemplatePresetKind.listening => term == null || audio == null,
    SrsTemplatePresetKind.blank => false,
  };

  bool get available => !missingField && duplicateOf == null;

  /// 加了以后会不会给已有笔记出卡（空白预设正面不引用字段，不出卡）。
  bool get makesCards => kind != SrsTemplatePresetKind.blank;
}

/// 按字段名认释义字段：先认 Lapis / Fushi 卡片的字段名，再认常见的英文 / 中日文名字（Anki 基础类型的
/// `Back` 也算：问答卡的背面就是意思）。
const List<String> _kMeaningNames = <String>[
  'MainDefinition',
  'Glossary',
  'Meaning',
  'Definition',
  'Definitions',
  'SelectionText',
  'LookupSelection',
  'Back',
];

final RegExp _meaningPattern = RegExp(
  r'meaning|definition|gloss|translation|释义|釋義|意味|意思|词义|詞義|定義|訳',
  caseSensitive: false,
);

/// 单词音频的字段名（优先于别的音频字段：听力卡考的是单词）。
const List<String> _kTermAudioNames = <String>[
  FushiCardFields.termAudio,
  'ExpressionAudio',
  'WordAudio',
];

bool _isContent(SrsFieldDef f) => switch (srsFieldKind(f)) {
  SrsFieldKind.text || SrsFieldKind.rich => true,
  _ => false,
};

SrsFieldDef? _termField(SrsNoteTypeView type) =>
    type.fields
        .where((SrsFieldDef f) => f.id == type.termFieldId)
        .firstOrNull ??
    type.fields.where(_isContent).firstOrNull;

SrsFieldDef? _meaningField(SrsNoteTypeView type, SrsFieldDef? term) {
  final List<SrsFieldDef> candidates = <SrsFieldDef>[
    for (final SrsFieldDef f in type.fields)
      if (f.id != term?.id && _isContent(f)) f,
  ];
  for (final String name in _kMeaningNames) {
    final SrsFieldDef? hit = candidates
        .where((SrsFieldDef f) => f.name.toLowerCase() == name.toLowerCase())
        .firstOrNull;
    if (hit != null) return hit;
  }
  return candidates
      .where((SrsFieldDef f) => _meaningPattern.hasMatch(f.name))
      .firstOrNull;
}

SrsFieldDef? _audioField(SrsNoteTypeView type) {
  final List<SrsFieldDef> audio = <SrsFieldDef>[
    for (final SrsFieldDef f in type.fields)
      if (srsFieldKind(f) == SrsFieldKind.audio) f,
  ];
  for (final String name in _kTermAudioNames) {
    final SrsFieldDef? hit = audio
        .where((SrsFieldDef f) => f.name == name)
        .firstOrNull;
    if (hit != null) return hit;
  }
  return audio.firstOrNull;
}

/// [type] 可用的起点预设（反向、听力、空白，顺序固定）。填空类型只有一个模板，返回空表。
List<SrsTemplatePreset> srsTemplatePresets(SrsNoteTypeView type) {
  if (type.isCloze) return const <SrsTemplatePreset>[];
  final Map<String, String> nameToId = <String, String>{
    for (final SrsFieldDef f in type.fields) f.name: f.id,
  };
  String ids(String byName) => templateNamesToIds(byName, nameToId);
  final SrsFieldDef? term = _termField(type);

  /// 预设成品：缺字段时只带映射结果（不可用），否则带正文并查重。
  SrsTemplatePreset preset(
    SrsTemplatePresetKind kind, {
    SrsFieldDef? meaning,
    SrsFieldDef? audio,
    required ({String front, String back}) Function() body,
  }) {
    final SrsTemplatePreset bare = SrsTemplatePreset(
      kind: kind,
      term: term,
      meaning: meaning,
      audio: audio,
    );
    if (bare.missingField) return bare;
    final ({String front, String back}) b = body();
    return SrsTemplatePreset(
      kind: kind,
      front: b.front,
      back: b.back,
      term: term,
      meaning: meaning,
      audio: audio,
      duplicateOf: srsTemplatesWithSameFront(
        type,
        '',
        front: b.front,
      ).firstOrNull,
    );
  }

  if (type.builtinKey == kSrsBuiltinFushiCardKey) {
    final String back = _fushiBack(type);
    // 内置 Fushi 卡片的反向卡认主释义（MainDefinition）：制卡时写进的那条释义。
    final SrsFieldDef? main = type.fields
        .where((SrsFieldDef f) => f.name == 'MainDefinition')
        .firstOrNull;
    final SrsFieldDef? termAudio = type.fields
        .where((SrsFieldDef f) => _kTermAudioNames.contains(f.name))
        .firstOrNull;
    return <SrsTemplatePreset>[
      preset(
        SrsTemplatePresetKind.reverse,
        meaning: main,
        body: () => (
          front: ids(
            fushiCardTemplateFor(FushiCardSide.front, <FushiCardFieldItem>[
              FushiCardFieldItem(field: main!.name),
            ]),
          ),
          back: back,
        ),
      ),
      preset(
        SrsTemplatePresetKind.listening,
        audio: termAudio,
        body: () =>
            (front: ids(_fushiListeningFront(termAudio!.name)), back: back),
      ),
      SrsTemplatePreset(
        kind: SrsTemplatePresetKind.blank,
        front: ids(
          fushiCardTemplateFor(
            FushiCardSide.front,
            const <FushiCardFieldItem>[],
          ),
        ),
        back: back,
      ),
    ];
  }

  final SrsVisualCompileContext ctx = SrsVisualCompileContext.of(type);
  final ({List<SrsVisualBlock> front, List<SrsVisualBlock> back}) suggested =
      srsSuggestVisualLayout(type);
  // 背面：先重复正面、一条分隔线、词条，再按自动布局的惯例摆其余字段（去掉已经在正面的那个）。
  String backWith(SrsFieldDef onFront) => ids(
    srsCompileVisualSide(
      srsRenumberVisualBlocks(<SrsVisualBlock>[
        const SrsVisualBlock(id: '', kind: SrsVisualBlockKind.frontSide),
        const SrsVisualBlock(id: '', kind: SrsVisualBlockKind.divider),
        SrsVisualBlock(
          id: '',
          kind: SrsVisualBlockKind.field,
          fieldId: term!.id,
          size: SrsVisualSize.display,
        ),
        for (final SrsVisualBlock b in suggested.back)
          if (b.kind == SrsVisualBlockKind.field &&
              b.fieldId != onFront.id &&
              b.fieldId != term.id)
            b,
      ]),
      ctx,
    ),
  );
  String frontWith(SrsFieldDef f, SrsVisualSize size) => ids(
    srsCompileVisualSide(<SrsVisualBlock>[
      SrsVisualBlock(
        id: 'b1',
        kind: SrsVisualBlockKind.field,
        fieldId: f.id,
        size: size,
      ),
    ], ctx),
  );
  final SrsFieldDef? meaning = _meaningField(type, term);
  final SrsFieldDef? audio = _audioField(type);
  return <SrsTemplatePreset>[
    preset(
      SrsTemplatePresetKind.reverse,
      meaning: meaning,
      body: () => (
        front: frontWith(meaning!, SrsVisualSize.title),
        back: backWith(meaning),
      ),
    ),
    preset(
      SrsTemplatePresetKind.listening,
      audio: audio,
      body: () =>
          (front: frontWith(audio!, SrsVisualSize.body), back: backWith(audio)),
    ),
    const SrsTemplatePreset(
      kind: SrsTemplatePresetKind.blank,
      back: '{{FrontSide}}\n\n<hr id=answer>\n\n',
    ),
  ];
}

/// 内置 Fushi 卡片新模板的背面：第一个模板的背面认得出区块布局就沿用（用户调过的背面外观带过来），
/// 否则用默认背面。
String _fushiBack(SrsNoteTypeView type) {
  final SrsTemplateDef? first = type.templates.firstOrNull;
  final Map<String, String> idToName = <String, String>{
    for (final SrsFieldDef f in type.fields) f.id: f.name,
  };
  if (first != null &&
      fushiCardBackLayoutOf(templateIdsToNames(first.back, idToName)) != null) {
    return first.back;
  }
  return templateNamesToIds(kFushiCardBackTemplate, <String, String>{
    for (final SrsFieldDef f in type.fields) f.name: f.id,
  });
}

/// 内置 Fushi 卡片的听力正面（名字形式）：只放单词音频，沿用 Fushi 卡片听力卡的类名（大号发音键）。
String _fushiListeningFront(String audioField) =>
    '<div class="fc fc-front" lang="ja">\n'
    '  <div class="fc-front-audio">\n'
    '    <div class="fc-audio fc-audio--large">{{$audioField}}</div>\n'
    '  </div>\n'
    '</div>\n';
