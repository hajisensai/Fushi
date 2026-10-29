/// 字段说明目录：把 Lapis / Fushi 卡片沿用的那批英文字段名（`ExpressionFurigana`、
/// `IsWordAndSentenceCard`……）翻译成「这个字段装什么、在卡面哪里出现」。
///
/// 这些字段名是为了与 Anki 生态（Lapis 笔记类型、Yomitan 制卡）互通才保留的，不能改名；
/// 所以名字不动，只在界面上配一个人话名字 + 说明 + 示例。目录**按字段名**匹配，不限于内置
/// 笔记类型：从 Anki 导入的 Lapis 牌组字段名一模一样，同样受益。用户自己给字段写了说明
/// （[SrsFieldDef.description]）时以用户的为准。
///
/// [SrsFieldInfo.suggestedSize] 等是可视化模板编辑器「按字段自动生成布局」时的默认摆法。
library;

import 'package:fushi_anki/fushi_anki_core.dart' show FushiCardFields;
import 'package:fushi_srs/fushi_srs.dart';

import 'package:fushi/src/srs/srs_visual_template.dart';
import 'package:fushi/utils.dart';

/// 字段内容的大类（决定图标、示例怎么画、自动布局放不放）。
enum SrsFieldKind {
  /// 普通文字。
  text,

  /// 带格式的 HTML（释义、词典内容）。
  rich,

  /// 音频（`[sound:...]`）。
  audio,

  /// 图片（`<img>`）。
  image,

  /// 开关：填任意字符即开启，本身不显示。
  flag,

  /// 只给模板脚本用的数据（音调位置、排序用词频），一般不直接显示。
  data,
}

/// 一个已知字段的说明。
class SrsFieldInfo {
  const SrsFieldInfo({
    required this.kind,
    required this.example,
    this.suggestedSize = SrsVisualSize.body,
    this.suggestedFilter = SrsVisualFilter.plain,
    this.backOrder,
  });

  final SrsFieldKind kind;

  /// 示例值（纯文字示意；图片 / 音频给的是说明性的占位文字）。
  final String example;

  final SrsVisualSize suggestedSize;
  final SrsVisualFilter suggestedFilter;

  /// 自动布局时在背面的先后（小的在上）；null = 自动布局不放（开关 / 数据 / 与别的字段重复）。
  final int? backOrder;
}

/// 已知字段（按字段名精确匹配）。
const Map<String, SrsFieldInfo> kSrsKnownFields = <String, SrsFieldInfo>{
  'Expression': SrsFieldInfo(
    kind: SrsFieldKind.text,
    example: '食べる',
    suggestedSize: SrsVisualSize.display,
  ),
  'ExpressionFurigana': SrsFieldInfo(
    kind: SrsFieldKind.text,
    example: '食[た]べる',
    suggestedSize: SrsVisualSize.display,
    suggestedFilter: SrsVisualFilter.furigana,
    backOrder: 0,
  ),
  'ExpressionReading': SrsFieldInfo(
    kind: SrsFieldKind.text,
    example: 'たべる',
    suggestedSize: SrsVisualSize.small,
    backOrder: 1,
  ),
  'ExpressionAudio': SrsFieldInfo(
    kind: SrsFieldKind.audio,
    example: '[sound:taberu.mp3]',
    backOrder: 2,
  ),
  'SelectionText': SrsFieldInfo(
    kind: SrsFieldKind.rich,
    example: 'to eat',
    backOrder: 6,
  ),
  'MainDefinition': SrsFieldInfo(
    kind: SrsFieldKind.rich,
    example: '食物を口に入れ、かんで飲みこむ。',
    backOrder: 7,
  ),
  'DefinitionPicture': SrsFieldInfo(
    kind: SrsFieldKind.image,
    example: '<img>',
    backOrder: 8,
  ),
  'Sentence': SrsFieldInfo(
    kind: SrsFieldKind.rich,
    example: '毎朝パンを<b>食べる</b>。',
    suggestedSize: SrsVisualSize.title,
  ),
  'SentenceFurigana': SrsFieldInfo(
    kind: SrsFieldKind.rich,
    example: '毎朝[まいあさ]パンを 食[た]べる。',
    suggestedFilter: SrsVisualFilter.furigana,
  ),
  'SentenceTranslation': SrsFieldInfo(
    kind: SrsFieldKind.text,
    example: 'I eat bread every morning.',
    suggestedSize: SrsVisualSize.small,
    backOrder: 4,
  ),
  'SentenceAudio': SrsFieldInfo(
    kind: SrsFieldKind.audio,
    example: '[sound:sentence.mp3]',
    backOrder: 5,
  ),
  'Picture': SrsFieldInfo(
    kind: SrsFieldKind.image,
    example: '<img>',
    backOrder: 9,
  ),
  'Glossary': SrsFieldInfo(
    kind: SrsFieldKind.rich,
    example: '1. to eat  2. to live on',
    suggestedSize: SrsVisualSize.small,
    backOrder: 10,
  ),
  'Hint': SrsFieldInfo(
    kind: SrsFieldKind.text,
    example: '動詞',
    suggestedFilter: SrsVisualFilter.hint,
  ),
  'IsWordAndSentenceCard': SrsFieldInfo(kind: SrsFieldKind.flag, example: 'x'),
  'IsClickCard': SrsFieldInfo(kind: SrsFieldKind.flag, example: 'x'),
  'IsSentenceCard': SrsFieldInfo(kind: SrsFieldKind.flag, example: 'x'),
  'IsAudioCard': SrsFieldInfo(kind: SrsFieldKind.flag, example: 'x'),
  'PitchPosition': SrsFieldInfo(kind: SrsFieldKind.data, example: '2'),
  'PitchCategories': SrsFieldInfo(kind: SrsFieldKind.data, example: 'nakadaka'),
  'Frequency': SrsFieldInfo(
    kind: SrsFieldKind.rich,
    example: 'JPDB: 1234',
    suggestedSize: SrsVisualSize.small,
    backOrder: 11,
  ),
  'FreqSort': SrsFieldInfo(kind: SrsFieldKind.data, example: '1234'),
  'MiscInfo': SrsFieldInfo(
    kind: SrsFieldKind.rich,
    example: '『作品名』 00:12:34',
    suggestedSize: SrsVisualSize.small,
    backOrder: 12,
  ),
};

/// [fieldName] 的已知说明；不认识返回 null。
///
/// 表按 Lapis 字段名建；Fushi 卡片改了名的 9 个字段（[FushiCardFields]）经 `legacyNameOf` 落到同一条。
SrsFieldInfo? srsKnownField(String fieldName) =>
    kSrsKnownFields[FushiCardFields.legacyNameOf(fieldName)];

/// 已知字段的人话名字（按界面语言）；不认识返回 null。
String? srsKnownFieldLabel(String fieldName) =>
    switch (FushiCardFields.legacyNameOf(fieldName)) {
      'Expression' => t.srs_field_info_expression_name,
      'ExpressionFurigana' => t.srs_field_info_expression_furigana_name,
      'ExpressionReading' => t.srs_field_info_expression_reading_name,
      'ExpressionAudio' => t.srs_field_info_expression_audio_name,
      'SelectionText' => t.srs_field_info_selection_text_name,
      'MainDefinition' => t.srs_field_info_main_definition_name,
      'DefinitionPicture' => t.srs_field_info_definition_picture_name,
      'Sentence' => t.srs_field_info_sentence_name,
      'SentenceFurigana' => t.srs_field_info_sentence_furigana_name,
      'SentenceTranslation' => t.srs_field_info_sentence_translation_name,
      'SentenceAudio' => t.srs_field_info_sentence_audio_name,
      'Picture' => t.srs_field_info_picture_name,
      'Glossary' => t.srs_field_info_glossary_name,
      'Hint' => t.srs_field_info_hint_name,
      'IsWordAndSentenceCard' =>
        t.srs_field_info_is_word_and_sentence_card_name,
      'IsClickCard' => t.srs_field_info_is_click_card_name,
      'IsSentenceCard' => t.srs_field_info_is_sentence_card_name,
      'IsAudioCard' => t.srs_field_info_is_audio_card_name,
      'PitchPosition' => t.srs_field_info_pitch_position_name,
      'PitchCategories' => t.srs_field_info_pitch_categories_name,
      'Frequency' => t.srs_field_info_frequency_name,
      'FreqSort' => t.srs_field_info_freq_sort_name,
      'MiscInfo' => t.srs_field_info_misc_info_name,
      _ => null,
    };

/// 已知字段的说明（按界面语言）；不认识返回 null。
String? srsKnownFieldDescription(String fieldName) =>
    switch (FushiCardFields.legacyNameOf(fieldName)) {
      'Expression' => t.srs_field_info_expression_desc,
      'ExpressionFurigana' => t.srs_field_info_expression_furigana_desc,
      'ExpressionReading' => t.srs_field_info_expression_reading_desc,
      'ExpressionAudio' => t.srs_field_info_expression_audio_desc,
      'SelectionText' => t.srs_field_info_selection_text_desc,
      'MainDefinition' => t.srs_field_info_main_definition_desc,
      'DefinitionPicture' => t.srs_field_info_definition_picture_desc,
      'Sentence' => t.srs_field_info_sentence_desc,
      'SentenceFurigana' => t.srs_field_info_sentence_furigana_desc,
      'SentenceTranslation' => t.srs_field_info_sentence_translation_desc,
      'SentenceAudio' => t.srs_field_info_sentence_audio_desc,
      'Picture' => t.srs_field_info_picture_desc,
      'Glossary' => t.srs_field_info_glossary_desc,
      'Hint' => t.srs_field_info_hint_desc,
      'IsWordAndSentenceCard' =>
        t.srs_field_info_is_word_and_sentence_card_desc,
      'IsClickCard' => t.srs_field_info_is_click_card_desc,
      'IsSentenceCard' => t.srs_field_info_is_sentence_card_desc,
      'IsAudioCard' => t.srs_field_info_is_audio_card_desc,
      'PitchPosition' => t.srs_field_info_pitch_position_desc,
      'PitchCategories' => t.srs_field_info_pitch_categories_desc,
      'Frequency' => t.srs_field_info_frequency_desc,
      'FreqSort' => t.srs_field_info_freq_sort_desc,
      'MiscInfo' => t.srs_field_info_misc_info_desc,
      _ => null,
    };

/// 字段在界面上显示的名字：已知字段给人话名字，其余原样用字段名。
String srsFieldDisplayName(SrsFieldDef field) =>
    srsKnownFieldLabel(field.name) ?? field.name;

/// 字段在界面上显示的说明：用户写的优先，其次已知字段的内置说明；都没有返回空串。
String srsFieldDisplayDescription(SrsFieldDef field) =>
    field.description.isNotEmpty
    ? field.description
    : (srsKnownFieldDescription(field.name) ?? '');

/// 字段大类：已知字段按目录；未知字段按名字猜（含 audio / image 字样），猜不到算文字。
SrsFieldKind srsFieldKind(SrsFieldDef field) {
  final SrsFieldInfo? known = srsKnownField(field.name);
  if (known != null) return known.kind;
  final String n = field.name.toLowerCase();
  if (RegExp(r'audio|sound|发音|音频|音声').hasMatch(n)) {
    return SrsFieldKind.audio;
  }
  if (RegExp(r'image|picture|screenshot|图|画像').hasMatch(n)) {
    return SrsFieldKind.image;
  }
  return SrsFieldKind.text;
}
