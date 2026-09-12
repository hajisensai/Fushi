import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';

/// 走**真实落卡渲染路径**（`renderMediaPayload` → `buildMinedFields`）的最小 repo，
/// 抄 `handlebar_clip_timestamp_test.dart` 的 harness。`renderMediaPayload` 经
/// [AnkiMiningContext.withMediaRefs] 重建 context——新字段漏抄一次整条落卡路径就恒
/// 空串，纯渲染器测试照不到，故必须走这一跳。
class _RenderPathRepo extends BaseAnkiRepository {
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

/// 副字幕例句占位符 `{secondary-cue-sentence}`：对齐 asbplayer 的「字幕轨道 2 字段」。
/// 值由视频页按副轨时间窗算好塞进 [AnkiMiningContext.secondaryCueSentence]，这里锁定
/// 渲染语义：原样输出、匹配词加粗、无值空串、**不**退回主轨文本。
void main() {
  const AnkiMiningPayload payload = AnkiMiningPayload(
    expression: '時代',
    matched: '時代',
  );

  AnkiMiningContext ctx({String? secondary}) => AnkiMiningContext(
        sentence: '勝つことが全ての時代さーね。',
        cueSentence: '勝つことが 全ての時代さーね。',
        secondaryCueSentence: secondary,
      );

  String render(String template, AnkiMiningContext c) =>
      AnkiHandlebarRenderer.render(template, payload, c);

  group('AnkiHandlebarRenderer {secondary-cue-sentence}', () {
    test('渲染副字幕轨文本', () {
      expect(
        render('{secondary-cue-sentence}', ctx(secondary: '那是赢球代表一切的时代啊')),
        '那是赢球代表一切的时代啊',
      );
    });

    test('副轨含匹配词时加粗（与 {cue-sentence} 同规则）', () {
      expect(
        render('{secondary-cue-sentence}', ctx(secondary: 'この時代は')),
        'この<b>時代</b>は',
      );
    });

    test('无副字幕 → 空串，不退回主轨句子', () {
      expect(render('{secondary-cue-sentence}', ctx()), '');
      // 对照：{cue-sentence} 才是退回 sentence 的那个。
      expect(render('{cue-sentence}', ctx()), isNotEmpty);
    });

    test('多行翻译（多条副 cue 换行拼接）原样保留', () {
      expect(
        render('{secondary-cue-sentence}', ctx(secondary: '第一行\n第二行')),
        '第一行\n第二行',
      );
    });
  });

  group('AnkiHandlebarOptions.coreOptions', () {
    test('含 {secondary-cue-sentence}，用户能在字段映射选择器里选到它', () {
      expect(
        AnkiHandlebarOptions.coreOptions,
        contains('{secondary-cue-sentence}'),
      );
    });

    test('不是弃用别名', () {
      expect(
        AnkiHandlebarOptions.deprecatedAliases,
        isNot(contains('{secondary-cue-sentence}')),
      );
    });
  });

  group('真实落卡路径（renderMediaPayload → withMediaRefs）', () {
    test('副字幕例句真的写进字段（withMediaRefs 没漏抄）', () {
      final RenderedMinedFields out = _RenderPathRepo().renderFor(
        settings: AnkiSettings(
          fieldMappings: <String, String>{
            'Expression': '{expression}',
            'Sentence': '{cue-sentence}',
            'TranslateSubtitle': '{secondary-cue-sentence}',
          },
        ),
        payload: payload,
        context: ctx(secondary: '那是赢球代表一切的时代啊'),
      );
      expect(
        out.fields['TranslateSubtitle'],
        '那是赢球代表一切的时代啊',
        reason: 'withMediaRefs 重建 context 时漏带 secondaryCueSentence，'
            '整条落卡路径就恒空串——这正是纯渲染器测试照不到的那一跳',
      );
      expect(out.fields['Sentence'], '勝つことが 全ての<b>時代</b>さーね。');
    });
  });
}
