import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';

/// `{popup-selection-text}` / `{popup-selection-html}` 永远如实填入用户的选中内容
/// （BUG-4756，GitHub issue #3407，拍板台 dYWFMfCEF2）。
///
/// 旧实现（commit 0548868a04）在「Lapis + 高亮落进导出释义 + 映了 glossary 类占位符」
/// 三条同时成立时让 `{popup-selection-text}` 渲染成空，理由是 Lapis 卡背会用非空的
/// SelectionText 占住默认页。结果是用户在查词弹窗里选中释义后制卡，SelectionText
/// 字段空空如也——而这个字段存在的意义就是放选中文字（Lapis 模板本身就是
/// `{{#SelectionText}}…{{/SelectionText}}`，有值才显示，这正是它的设计用法）。
/// 维护者拍板：有选中就填，不再让位。释义字段里的 `<mark>` 高亮照旧保留，两者并存。
void main() {
  const String kGlossary = '<div>釈義本体</div>';
  const String kSelected = '選んだ一節';
  const String kSelectedHtml =
      '<div class="yomitan-glossary fushi-popup-selection">選んだ一節</div>';

  const Map<String, String> lapisLike = <String, String>{
    'SelectionText': '{popup-selection-text}',
    'MainDefinition': '{glossary}',
  };

  Map<String, String> render({
    required String? noteTypeName,
    required bool highlighted,
    Map<String, String> fieldMappings = lapisLike,
  }) {
    return _TestRepo()
        .renderFor(
          settings: AnkiSettings(
            selectedNoteTypeName: noteTypeName,
            fieldMappings: fieldMappings,
          ),
          payload: AnkiMiningPayload(
            expression: '語',
            glossary: kGlossary,
            popupSelectionText: kSelected,
            popupSelectionHtml: kSelectedHtml,
            glossarySelectionHighlighted: highlighted,
          ),
          context: const AnkiMiningContext(sentence: ''),
        )
        .fields;
  }

  group('SelectionText 不让位：选中内容总是进卡', () {
    test('Lapis + 高亮落进释义 + 映了 glossary → SelectionText 照样有选中文本', () {
      final Map<String, String> fields = render(
        noteTypeName: LapisNoteType.modelName,
        highlighted: true,
      );
      expect(fields['SelectionText'], kSelected);
      expect(fields['MainDefinition'], kGlossary);
    });

    test('glossary 类占位符的各种写法都不影响 SelectionText', () {
      for (final String marker in const <String>[
        '{glossary}',
        '{glossary-first}',
        '{selected-glossary}',
        '{single-glossary-大辞泉}',
      ]) {
        final Map<String, String> fields = render(
          noteTypeName: LapisNoteType.modelName,
          highlighted: true,
          fieldMappings: <String, String>{
            'SelectionText': '{popup-selection-text}',
            'MainDefinition': marker,
          },
        );
        expect(fields['SelectionText'], kSelected, reason: marker);
      }
    });

    test('{popup-selection-html} 同样不让位', () {
      final Map<String, String> fields = render(
        noteTypeName: LapisNoteType.modelName,
        highlighted: true,
        fieldMappings: const <String, String>{
          'SelectionText': '{popup-selection-html}',
          'MainDefinition': '{glossary}',
        },
      );
      expect(fields['SelectionText'], kSelectedHtml);
    });

    test('非 Lapis / 未选笔记类型 / 高亮没落地 → 一样填', () {
      expect(
        render(noteTypeName: 'Kaishi 1.5k', highlighted: true)['SelectionText'],
        kSelected,
      );
      expect(
        render(noteTypeName: null, highlighted: true)['SelectionText'],
        kSelected,
      );
      expect(
        render(
          noteTypeName: LapisNoteType.modelName,
          highlighted: false,
        )['SelectionText'],
        kSelected,
      );
    });
  });

  group('payload 的 glossarySelectionHighlighted 线上键', () {
    test('旧 payload 没有这个键 → false', () {
      final AnkiMiningPayload payload = AnkiMiningPayload.fromJson(
        jsonDecode('{"expression":"語","popupSelectionText":"$kSelected"}')
            as Map<String, dynamic>,
      );
      expect(payload.glossarySelectionHighlighted, isFalse);
      expect(payload.popupSelectionText, kSelected);
    });

    test('popup.js 传 true 时解析得出来', () {
      final AnkiMiningPayload payload = AnkiMiningPayload.fromJson(
        jsonDecode('{"expression":"語","glossarySelectionHighlighted":true}')
            as Map<String, dynamic>,
      );
      expect(payload.glossarySelectionHighlighted, isTrue);
    });
  });
}

class _TestRepo extends BaseAnkiRepository {
  @override
  Future<AnkiFetchResult> fetchConfiguration() => throw UnimplementedError();

  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) => throw UnimplementedError();

  @override
  Future<bool> isDuplicate(String expression, String reading) =>
      throw UnimplementedError();

  @override
  Future<bool> createNoteType(AnkiNoteTypeTemplate template) =>
      throw UnimplementedError();

  @override
  Future<bool> createDeck(String name) => throw UnimplementedError();

  RenderedMinedFields renderFor({
    required AnkiSettings settings,
    required AnkiMiningPayload payload,
    required AnkiMiningContext context,
  }) => renderMediaPayload(
    settings: settings,
    payload: payload,
    context: context,
    coverRef: null,
    sentenceAudioRef: null,
    processedAudio: '',
    dictionaryMediaTags: const <String, String>{},
  );
}
