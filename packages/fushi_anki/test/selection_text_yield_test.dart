import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';

/// `{popup-selection-text}` 让位给「已经带高亮的释义」这件事，判据必须落在**知道
/// 笔记类型和字段映射**的这一层。
///
/// 第一版把决定放在 popup.js：高亮一落地就无条件把 `popupSelectionText` 清成空串。
/// 可 `{popup-selection-text}` 是用户可映射的占位符（`AnkiHandlebarOptions.coreOptions`），
/// 而 popup.js 看得见 DOM、看不见 `fieldMappings`：
///
/// - 用户用**非 Lapis** 笔记类型（没有那个卡背轮播），把 marker 映到某字段——照旧
///   清空，选中的内容凭空消失；
/// - 用户映了 `{popup-selection-text}` 却**没**映任何 glossary 占位符——高亮根本没
///   进卡，清空之后这段文本一处都不剩。
///
/// 所以 popup.js 只如实上报 `glossarySelectionHighlighted`，让位与否由
/// `BaseAnkiRepository.shouldYieldSelectionText` 的三条判据一起定。
void main() {
  const String kGlossary = '<div>釈義本体</div>';
  const String kSelected = '選んだ一節';

  AnkiSettings settingsWith({
    required String? noteTypeName,
    required Map<String, String> fieldMappings,
  }) =>
      AnkiSettings(
        selectedNoteTypeName: noteTypeName,
        fieldMappings: fieldMappings,
      );

  const Map<String, String> lapisLike = <String, String>{
    'SelectionText': '{popup-selection-text}',
    'Glossary': '{glossary}',
  };

  Map<String, String> render({
    required String? noteTypeName,
    required bool highlighted,
    Map<String, String> fieldMappings = lapisLike,
  }) {
    return _TestRepo()
        .renderFor(
          settings: settingsWith(
            noteTypeName: noteTypeName,
            fieldMappings: fieldMappings,
          ),
          payload: AnkiMiningPayload(
            expression: '語',
            glossary: kGlossary,
            popupSelectionText: kSelected,
            glossarySelectionHighlighted: highlighted,
          ),
          context: const AnkiMiningContext(sentence: ''),
        )
        .fields;
  }

  group('SelectionText 让位：三条判据缺一不可', () {
    test('Lapis + 高亮落地 + 映了 glossary → 让位（释义字段照常带内容）', () {
      final Map<String, String> fields =
          render(noteTypeName: 'Lapis', highlighted: true);
      // 渲染成空的字段在「新建」语义下本就不进 map。
      expect(fields.containsKey('SelectionText'), isFalse);
      expect(fields['Glossary'], kGlossary);
    });

    test('非 Lapis 笔记类型 → 不让位（别的模板没有那个轮播，凭什么替用户丢内容）', () {
      expect(
        render(noteTypeName: 'Kaishi 1.5k', highlighted: true)['SelectionText'],
        kSelected,
      );
      // 一个笔记类型都没选（设置从未 fetch）时同样不让位。
      expect(
        render(noteTypeName: null, highlighted: true)['SelectionText'],
        kSelected,
      );
    });

    test('没映任何 glossary 占位符 → 不让位（高亮压根没进卡，清了就凭空消失）', () {
      expect(
        render(
          noteTypeName: 'Lapis',
          highlighted: true,
          fieldMappings: const <String, String>{
            'SelectionText': '{popup-selection-text}',
            'Sentence': '{sentence}',
          },
        )['SelectionText'],
        kSelected,
      );
    });

    test('高亮没落地（选中在例句/词头，或文本流校验没过）→ 不让位', () {
      expect(
        render(noteTypeName: 'Lapis', highlighted: false)['SelectionText'],
        kSelected,
      );
    });

    test('{single-glossary-<词典>} / {glossary-first} 也算「高亮进了卡」', () {
      for (final String marker in const <String>[
        '{glossary-first}',
        '{selected-glossary}',
        '{single-glossary-大辞泉}',
      ]) {
        final Map<String, String> fields = render(
          noteTypeName: 'Lapis',
          highlighted: true,
          fieldMappings: <String, String>{
            'SelectionText': '{popup-selection-text}',
            'MainDefinition': marker,
          },
        );
        expect(fields.containsKey('SelectionText'), isFalse,
            reason: '$marker 渲染出来的也是带高亮的释义 HTML');
      }
    });
  });

  group('payload 的新字段', () {
    test('旧 payload 没有这个键 → false → 行为逐字节不变', () {
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

    test('媒体二次渲染必须透传这个标志（16 字段漂移守卫）', () {
      // renderMediaPayload 手写重建整个 payload：漏抄一个字段，让位判据就在
      // 「带媒体的制卡」这条路径上静默失效，而不带媒体的路径照常——最难查的那种。
      final Map<String, String> fields =
          render(noteTypeName: 'Lapis', highlighted: true);
      expect(fields.containsKey('SelectionText'), isFalse);
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
  }) =>
      throw UnimplementedError();

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
  }) =>
      renderMediaPayload(
        settings: settings,
        payload: payload,
        context: context,
        coverRef: null,
        sentenceAudioRef: null,
        processedAudio: '',
        dictionaryMediaTags: const <String, String>{},
      );
}
