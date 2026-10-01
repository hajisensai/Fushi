import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';

/// BUG-2825 守卫：制卡字段渲染不再往释义里追加 Fushi 自造的外字（gaiji）中和 `<style>`。
///
/// 那份样式（`_ankiGaijiImageStyle`）用 `!important` 把外字框压成 1em、`text-bottom`
/// 对齐，原本是为了对抗词典自带 CSS 里写给弹窗的 `.gloss-image-container{width:15em!important}`。
/// 根因在导出结构：popup.js 导出时保留了 `gloss-*` class，词典 CSS 才在卡片上生效。
/// 现在导出按 Yomitan（structured-content-style.json 内联 + 剥 class）规范化，词典里
/// 那类选择器在卡片上命中不到，中和样式没有对手，只剩它自己把外字压扁下沉——用户在
/// 明鏡真卡上对照 Yomitan 卡确认过。上游 Yomitan 没有这一层。
///
/// 同时锁定：图片外层 `<a href>` 里的媒体占位符与 `<img src>` 一起被换成真实文件名
/// （`replaceAll`），点开的是同一个媒体文件。
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

  Map<String, String> fieldsFor(String glossary, Map<String, String> tags) =>
      buildMinedFields(
        fieldMappings: const <String, String>{'Back': '{glossary}'},
        payload: AnkiMiningPayload(expression: '一', glossary: glossary),
        context: const AnkiMiningContext(sentence: ''),
        dictionaryMediaTags: tags,
      );
}

/// popup.js 修复后导出的外字形状（Yomitan 同形：`<a target rel href>`，无 class）。
const String _exportedGaiji =
    '<div class="yomitan-glossary"><ol><li data-dictionary="明鏡国語辞典 第三版">'
    '<span><span data-sc-img="" data-sc-class="gaiji">'
    '<a target="_blank" rel="noreferrer noopener" href="fushi_dict_0.svg" '
    'style="display:inline-block;">'
    '<span style="display:inline-block;font-size:1em;">'
    '<img alt="3分の2" src="fushi_dict_0.svg" style="display:inline-block;">'
    '</span></a></span></span></li></ol></div>';

void main() {
  test(
    'gaiji glossary is written as exported: no appended neutralizer style',
    () {
      final String back = _TestRepo().fieldsFor(
        _exportedGaiji,
        const <String, String>{'fushi_dict_0.svg': 'real_stored.svg'},
      )['Back']!;

      expect(
        back,
        isNot(contains('<style>')),
        reason: 'Fushi 自造的 gaiji 中和样式会把外字压成 1em 并下沉，上游没有这一层',
      );
      expect(back, isNot(contains('!important')));
      expect(
        back,
        _exportedGaiji.replaceAll('fushi_dict_0.svg', 'real_stored.svg'),
        reason: '字段内容就是 popup.js 导出的释义，只做媒体占位符替换',
      );
      expect(
        back,
        contains('href="real_stored.svg"'),
        reason: '图片外层 <a> 的 href 必须与 <img src> 指向同一个已存入 Anki 的媒体',
      );
    },
  );
}
