/// 内置笔记类型「Fushi 卡片」的定义（Fushi 自己的卡面模板，GPL-3.0）。
///
/// 字段沿用 Lapis 的字段名（[LapisNoteType.fields] 逐字一致），另加一个扩展字段
/// `SentenceTranslation`（例句翻译，Lapis 没有；为空时卡面整块不出现）。所以 Lapis 笔记
/// 换成本类型时字段按同名直映，零手工映射。
///
/// 模板正文与 CSS 的唯一真相是 `packages/fushi_anki/templates/fushi_card/` 下的三个源文件，
/// 经 `tool/gen_fushi_card_template.dart` 生成为 [kFushiCardFrontTemplate] 等常量（生成文件
/// 是否最新由 `test/fushi_card_template_sync_test.dart` 守着）。
///
/// 模板里凡是读宿主注入的东西（`--fushi-srs-*` CSS 变量、`fushi-srs-*` 宿主类名）都带默认值：
/// 导出 .apkg 后在 Anki / AnkiDroid 里没有宿主注入，卡面照常按默认外观显示。
library;

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

  /// 字段：Lapis 的全部字段（同名同序）+ 扩展字段。
  static const List<String> fields = <String>[
    ...LapisNoteType.fields,
    sentenceTranslationField,
  ];

  /// 字段 → 制卡占位符默认映射：与 Lapis 相同（扩展字段没有对应的制卡内容，留空）。
  static const Map<String, String> defaultFieldMappings =
      LapisNoteType.defaultFieldMappings;

  static const AnkiNoteTypeTemplate template = AnkiNoteTypeTemplate(
    name: modelName,
    fields: fields,
    cardName: cardName,
    front: kFushiCardFrontTemplate,
    back: kFushiCardBackTemplate,
    css: kFushiCardStylingCss,
  );
}
