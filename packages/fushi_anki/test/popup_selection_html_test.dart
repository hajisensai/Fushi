import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';

/// `{popup-selection-html}`（反馈 aBgKMjhfut / BUG-4049 方案 B）：同一次选区的
/// 带样式 HTML。`{popup-selection-text}` 保持 Yomitan 兼容的纯文本，一字不变。
///
/// HTML 的产出与净化在 popup.js（`fushi/test/anki/popup_selection_html_test.js`）；
/// 这里守 Dart 侧：wire 键解析、占位符渲染、媒体二次渲染不丢字段、让位判据与纯文本
/// 版一致、picker 里能选到。
void main() {
  const String kText = '物事の大事な点';
  const String kHtml =
      '<div style="text-align: left;" class="yomitan-glossary '
      'fushi-popup-selection"><div data-dictionary="大辞林">'
      '<span class="dict-note">物事の<b>大事</b>な点</span></div></div>';

  Map<String, String> render({
    required Map<String, String> fieldMappings,
    String? noteTypeName,
    bool highlighted = false,
  }) => _TestRepo()
      .renderFor(
        settings: AnkiSettings(
          selectedNoteTypeName: noteTypeName,
          fieldMappings: fieldMappings,
        ),
        payload: AnkiMiningPayload.fromJson(<String, dynamic>{
          'expression': '点',
          'glossary': '<div>釈義</div>',
          'popupSelectionText': kText,
          'popupSelectionHtml': kHtml,
          'glossarySelectionHighlighted': highlighted ? 'true' : 'false',
        }),
        context: const AnkiMiningContext(sentence: ''),
      )
      .fields;

  test('wire 键 popupSelectionHtml 解析得出来；旧 payload 没有这个键 → 空串', () {
    expect(
      AnkiMiningPayload.fromJson(
        jsonDecode(
              jsonEncode(<String, String>{
                'expression': '点',
                'popupSelectionHtml': kHtml,
              }),
            )
            as Map<String, dynamic>,
      ).popupSelectionHtml,
      kHtml,
    );
    expect(
      AnkiMiningPayload.fromJson(<String, dynamic>{
        'expression': '点',
        'popupSelectionText': kText,
      }).popupSelectionHtml,
      isEmpty,
    );
  });

  test('{popup-selection-html} 渲染 HTML，{popup-selection-text} 仍是纯文本', () {
    final Map<String, String> fields = render(
      fieldMappings: const <String, String>{
        'Styled': '{popup-selection-html}',
        'Plain': '{popup-selection-text}',
      },
    );
    // 走的是 renderMediaPayload（带媒体制卡的二次重建）：漏抄字段会在这里变空。
    expect(fields['Styled'], kHtml);
    expect(fields['Plain'], kText);
  });

  test('让位判据与纯文本版相同：Lapis + 高亮落地 + 映了 glossary → 两者都让位', () {
    const Map<String, String> mappings = <String, String>{
      'SelectionText': '{popup-selection-html}',
      'Glossary': '{glossary}',
    };
    expect(
      render(
        fieldMappings: mappings,
        noteTypeName: LapisNoteType.modelName,
        highlighted: true,
      ).containsKey('SelectionText'),
      isFalse,
    );
    expect(
      render(
        fieldMappings: mappings,
        noteTypeName: 'Kaishi 1.5k',
        highlighted: true,
      )['SelectionText'],
      kHtml,
    );
  });

  test('picker 能选到，且出厂预设的映射不被改动', () {
    expect(
      AnkiHandlebarOptions.coreOptions,
      contains('{popup-selection-html}'),
    );
    expect(
      LapisNoteType.defaultFieldMappings['SelectionText'],
      '{popup-selection-text}',
    );
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
