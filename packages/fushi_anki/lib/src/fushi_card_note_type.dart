/// 内置笔记类型「Fushi 卡片」的定义（Fushi 自己的卡面模板，GPL-3.0）。
///
/// 字段 = Lapis 字段加一个扩展字段 `SentenceTranslation`（例句翻译，Lapis 没有；为空时卡面
/// 整块不出现）。其中 9 个字段改了名（见 [FushiCardFields]，旧名作别名保留），Lapis 笔记换成
/// 本类型时按「旧名 → 新名」映射，其余同名直映。
///
/// 模板正文与 CSS 的唯一真相是 `packages/fushi_anki/templates/fushi_card/` 下的三个源文件，
/// 经 `tool/gen_fushi_card_template.dart` 生成为 [kFushiCardFrontTemplate] 等常量（生成文件
/// 是否最新由 `test/fushi_card_template_sync_test.dart` 守着）。
///
/// 模板里凡是读宿主注入的东西（`--fushi-srs-*` CSS 变量、`fushi-srs-*` 宿主类名）都带默认值：
/// 导出 .apkg 后在 Anki / AnkiDroid 里没有宿主注入，卡面照常按默认外观显示。
library;

import 'fushi_card_fields.dart';
import 'fushi_card_template_data.dart';
import 'lapis_note_type.dart';

export 'fushi_card_template_data.dart';

class FushiCardNoteType {
  const FushiCardNoteType._();

  /// 笔记类型名（导出到 Anki 也用它）。
  static const String modelName = 'Fushi Card';

  /// 唯一的卡片模板名：与 Lapis 同名，Lapis → Fushi 卡片 迁移时模板按名字直映。
  static const String cardName = 'Card 1';

  /// 扩展字段：例句翻译。
  static const String sentenceTranslationField = 'SentenceTranslation';

  /// 字段：Lapis 的全部字段（同序，其中 9 个按 [FushiCardFields] 改了名）+ 扩展字段。
  /// 写成字面量是因为 [template] 是 const；与 Lapis 的对应关系由测试
  /// `fushi_card_fields_test.dart` 钉死。
  static const List<String> fields = <String>[
    'Term',
    'TermFurigana',
    'TermReading',
    'TermAudio',
    'LookupSelection',
    'MainDefinition',
    'DefinitionMedia',
    'Sentence',
    'SentenceFurigana',
    'SentenceAudio',
    'Media',
    'Glossary',
    'Hint',
    'IsWordAndSentenceCard',
    'IsClickCard',
    'IsSentenceCard',
    'IsAudioCard',
    'PitchPosition',
    'PitchCategories',
    'Frequency',
    'FrequencyRank',
    'Source',
    sentenceTranslationField,
  ];

  /// 字段 → 制卡占位符默认映射：与 Lapis 相同（键按 [FushiCardFields] 改名；扩展字段没有对应的
  /// 制卡内容，留空）。
  static const Map<String, String> defaultFieldMappings = <String, String>{
    'Term': '{expression}',
    'TermFurigana': '{furigana-plain}',
    'TermReading': '{reading}',
    'TermAudio': '{audio}',
    'LookupSelection': '{popup-selection-text}',
    'MainDefinition': '{glossary-first}',
    'Sentence': '{sentence}',
    'SentenceAudio': '{sentence-audio}',
    'Media': '{card-image}',
    'Glossary': '{glossary}',
    'PitchPosition': '{pitch-accent-positions}',
    'PitchCategories': '{pitch-accent-categories}',
    'Frequency': '{frequencies}',
    'FrequencyRank': '{frequency-harmonic-rank}',
    'Source': '{source-link} {clip-timestamp}',
    'IsWordAndSentenceCard': 'x',
  };

  static const AnkiNoteTypeTemplate template = AnkiNoteTypeTemplate(
    name: modelName,
    fields: fields,
    cardName: cardName,
    front: kFushiCardFrontTemplate,
    back: kFushiCardBackTemplate,
    css: kFushiCardStylingCss,
  );
}
