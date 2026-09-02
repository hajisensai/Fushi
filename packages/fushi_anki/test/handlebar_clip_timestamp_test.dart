import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';

/// 走**真实落卡渲染路径**（`renderMediaPayload` → `buildMinedFields`）的最小
/// repo，抄 `fushi/test/anki/phonetic_transcriptions_mining_test.dart` 的 harness。
///
/// 为什么必须有它：直调 `AnkiHandlebarRenderer.render` 的测试**结构上绕过**
/// `renderMediaPayload` 那一跳。而那一跳此前是逐字段手抄 context 重建一份新的，
/// 漏抄新字段就会让整条落卡路径恒空串——纯渲染器测试全绿也照不出来。
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
    String? coverRef,
    String? sentenceAudioRef,
  }) =>
      renderMediaPayload(
        settings: settings,
        payload: payload,
        context: context,
        coverRef: coverRef,
        sentenceAudioRef: sentenceAudioRef,
        processedAudio: '',
        dictionaryMediaTags: const <String, String>{},
      );
}

/// 片段时间窗占位符 `{clip-timestamp}`：卡片底部「Misc. info → === Details ===」
/// 栏此前只有媒体名，卡片攒多了回溯不到原片位置。时间窗本就躺在
/// `ImmersionMiningRequest.clipStartMs|clipEndMs` 里（与音频裁剪同源），这里锁定
/// 它渲染成人类可读区间、以及「没有时间窗就不渲染」这条负向语义。
void main() {
  const AnkiMiningPayload payload = AnkiMiningPayload(expression: '言葉');

  AnkiMiningContext contextWithClip(int? startMs, int? endMs) =>
      AnkiMiningContext(
        sentence: 'これは言葉です。',
        documentTitle: 'Initial.D.Third.Stage',
        clipStartMs: startMs,
        clipEndMs: endMs,
      );

  String render(String template, AnkiMiningContext ctx) =>
      AnkiHandlebarRenderer.render(template, payload, ctx);

  group('AnkiHandlebarRenderer {clip-timestamp}', () {
    test('渲染成 HH:MM:SS - HH:MM:SS 区间', () {
      expect(
        render('{clip-timestamp}', contextWithClip(754000, 758000)),
        '00:12:34 - 00:12:38',
      );
    });

    test('小时/分/秒各自补零，跨小时不进位丢失', () {
      // 1h02m03s = 3723000ms，1h02m09s = 3729000ms
      expect(
        render('{clip-timestamp}', contextWithClip(3723000, 3729000)),
        '01:02:03 - 01:02:09',
      );
      // 超过 10 小时也照常（不做 12 小时制、不截断小时位）
      expect(
        render('{clip-timestamp}', contextWithClip(36000000, 36061000)),
        '10:00:00 - 10:01:01',
      );
    });

    test('毫秒截断到秒（不四舍五入，与片段起点语义一致）', () {
      expect(
        render('{clip-timestamp}', contextWithClip(1999, 2999)),
        '00:00:01 - 00:00:02',
      );
    });

    test('片段从 0 秒开头也照常渲染（start==0 不是「没有时间窗」）', () {
      expect(
        render('{clip-timestamp}', contextWithClip(0, 4000)),
        '00:00:00 - 00:00:04',
      );
    });

    test('无时间轴来源（书 / galgame，两端 null）→ 空串', () {
      expect(render('{clip-timestamp}', contextWithClip(null, null)), '');
      expect(render('{clip-timestamp}', contextWithClip(754000, null)), '');
      expect(render('{clip-timestamp}', contextWithClip(null, 758000)), '');
    });

    test('取不到 cue 的兜底 0/0 → 空串，不产出 00:00:00 - 00:00:00 伪信息', () {
      expect(
        render('{clip-timestamp}', contextWithClip(0, 0)),
        '',
        reason: '视频侧 _resolveVideoMiningRange 取不到 cue 时兜底成 0/0',
      );
    });

    test('end <= start 的无效窗 → 空串（唯一有效性判据，与 hasRange 同语义）', () {
      expect(render('{clip-timestamp}', contextWithClip(758000, 754000)), '');
      expect(render('{clip-timestamp}', contextWithClip(754000, 754000)), '');
    });

    test('formatClipTimestamp 是纯函数，可脱离 context 直接用', () {
      expect(
        AnkiHandlebarRenderer.formatClipTimestamp(754000, 758000),
        '00:12:34 - 00:12:38',
      );
      expect(AnkiHandlebarRenderer.formatClipTimestamp(null, 1), '');
    });
  });

  group('AnkiHandlebarOptions.coreOptions', () {
    test('含 {clip-timestamp}，用户能在字段映射选择器里选到它', () {
      expect(AnkiHandlebarOptions.coreOptions, contains('{clip-timestamp}'));
    });

    test('不是弃用别名（正常出现在候选里）', () {
      expect(
        AnkiHandlebarOptions.deprecatedAliases,
        isNot(contains('{clip-timestamp}')),
      );
    });
  });

  group('Lapis 出厂默认 MiscInfo', () {
    test('同时带媒体名与片段时间窗', () {
      final String mapping = LapisNoteType.defaultFieldMappings['MiscInfo']!;
      expect(mapping, contains('{document-title}'));
      expect(mapping, contains('{clip-timestamp}'));
    });

    test('整体渲染出「媒体名 时间窗」，一个字段里两个占位符照常展开', () {
      final String mapping = LapisNoteType.defaultFieldMappings['MiscInfo']!;
      expect(
        render(mapping, contextWithClip(754000, 758000)),
        'Initial.D.Third.Stage 00:12:34 - 00:12:38',
      );
    });

    test('无时间轴来源时只剩媒体名（不留 00:00:00 尾巴）', () {
      final String mapping = LapisNoteType.defaultFieldMappings['MiscInfo']!;
      final String value = render(mapping, contextWithClip(null, null));
      expect(value.trim(), 'Initial.D.Third.Stage');
      expect(value, isNot(contains(':')));
    });
  });

  group('真实落卡路径（renderMediaPayload → buildMinedFields）', () {
    final _RenderPathRepo repo = _RenderPathRepo();

    AnkiSettings settingsWithLapisMiscInfo() => AnkiSettings(
          fieldMappings: <String, String>{
            'Expression': '{expression}',
            'MiscInfo': LapisNoteType.defaultFieldMappings['MiscInfo']!,
          },
        );

    test('时间窗真的写进 MiscInfo 字段（不是只有渲染器认得）', () {
      final RenderedMinedFields out = repo.renderFor(
        settings: settingsWithLapisMiscInfo(),
        payload: payload,
        context: contextWithClip(754000, 758000),
      );
      expect(
        out.fields['MiscInfo'],
        'Initial.D.Third.Stage 00:12:34 - 00:12:38',
        reason: 'renderMediaPayload 重建 context 时漏带 clipStartMs/clipEndMs，'
            '整条落卡路径就恒空串——这正是纯渲染器测试照不到的那一跳',
      );
    });

    test('媒体引用替换的同时，非媒体字段一个都不丢', () {
      final RenderedMinedFields out = repo.renderFor(
        settings: AnkiSettings(
          fieldMappings: <String, String>{
            'MiscInfo': LapisNoteType.defaultFieldMappings['MiscInfo']!,
            'Picture': '{card-image}',
            'SentenceAudio': '{sentence-audio}',
          },
        ),
        payload: payload,
        context: AnkiMiningContext(
          sentence: 'これは言葉です。',
          documentTitle: 'Initial.D.Third.Stage',
          coverPath: r'C:\tmp\immersion_frame.jpg',
          sentenceAudioPath: r'C:\tmp\immersion_clip.mp3',
          clipStartMs: 754000,
          clipEndMs: 758000,
        ),
        coverRef: '<img src="fushi_cover_abc.jpg">',
        sentenceAudioRef: '[sound:fushi_audio_abc.mp3]',
      );
      expect(
        out.fields['MiscInfo'],
        'Initial.D.Third.Stage 00:12:34 - 00:12:38',
      );
      // 媒体路径被换成落盘后的引用，本地临时路径不会漏进卡片。
      expect(out.fields['Picture'], '<img src="fushi_cover_abc.jpg">');
      expect(out.fields['SentenceAudio'], '[sound:fushi_audio_abc.mp3]');
    });

    test('媒体没落地时清空路径，绝不退回本地临时文件路径', () {
      final RenderedMinedFields out = repo.renderFor(
        settings: AnkiSettings(
          fieldMappings: <String, String>{'Picture': '{card-image}'},
        ),
        payload: payload,
        context: AnkiMiningContext(
          sentence: 'これは言葉です。',
          coverPath: r'C:\tmp\immersion_frame.jpg',
        ),
        coverRef: null,
      );
      expect(
        out.fields.containsKey('Picture'),
        isFalse,
        reason: 'coverRef 为 null 时若退回 context.coverPath，'
            '会把 Anki 读不到的本地路径写进卡片',
      );
    });

    test('无时间轴来源：MiscInfo 只剩媒体名，不带空的时间尾巴', () {
      final RenderedMinedFields out = repo.renderFor(
        settings: settingsWithLapisMiscInfo(),
        payload: payload,
        context: contextWithClip(null, null),
      );
      expect(out.fields['MiscInfo'], 'Initial.D.Third.Stage');
    });
  });

  group('源码守卫：落卡路径不许再手抄 AnkiMiningContext', () {
    // 手抄逐字段重建 context 是本次 bug 的根：每给 AnkiMiningContext 加一个字段
    // 就漏一次，而直调渲染器的测试结构上照不到。落卡路径必须走 withMediaRefs。
    test('base_anki_repository 的渲染路径用 withMediaRefs 而非重建构造', () {
      final String src = File(
        'lib/src/base_anki_repository.dart',
      ).readAsStringSync();
      expect(
        src.contains('context.withMediaRefs('),
        isTrue,
        reason: 'renderMediaPayload 必须经 withMediaRefs 带全字段',
      );
      final int renderStart =
          src.indexOf('RenderedMinedFields renderMediaPayload(');
      expect(renderStart, greaterThan(-1), reason: '锚点漂移，守卫失效');
      final int renderEnd = src.indexOf('\n  }', renderStart);
      final String body = src.substring(renderStart, renderEnd);
      expect(
        body.contains('AnkiMiningContext('),
        isFalse,
        reason: '又在 renderMediaPayload 里手抄 context 了——新字段迟早再漏一次',
      );
    });
  });

  group('BaseAnkiRepository 载入期迁移：MiscInfo 补上片段时间', () {
    String settingsJson(Map<String, String> mappings) =>
        jsonEncode(<String, dynamic>{
          'selectedDeckName': 'Lapis',
          'fieldMappings': mappings,
          'tags': '',
        });

    Map<String, String>? mappingsOf(String? raw) {
      if (raw == null) return null;
      final Map<String, dynamic> decoded =
          jsonDecode(raw) as Map<String, dynamic>;
      return Map<String, String>.from(decoded['fieldMappings'] as Map);
    }

    test('恰好是旧出厂默认 → 补成新出厂默认', () {
      final String? upgraded = BaseAnkiRepository.upgradeMiscInfoMapping(
        settingsJson(<String, String>{
          'Expression': '{expression}',
          'MiscInfo': '{document-title}',
        }),
      );
      expect(upgraded, isNotNull);
      expect(
        mappingsOf(upgraded)!['MiscInfo'],
        LapisNoteType.defaultFieldMappings['MiscInfo'],
      );
      // 其余映射一个字都不动。
      expect(mappingsOf(upgraded)!['Expression'], '{expression}');
    });

    test('迁移幂等：改写过的串再进来不再改（返回 null = 无需回写）', () {
      final String once = BaseAnkiRepository.upgradeMiscInfoMapping(
        settingsJson(<String, String>{'MiscInfo': '{document-title}'}),
      )!;
      expect(BaseAnkiRepository.upgradeMiscInfoMapping(once), isNull);
    });

    test('用户改过的值一律不动（清空 / 换占位符 / 自拼组合）', () {
      for (final String userValue in <String>[
        '',
        '{expression}',
        '{document-title} 出自',
        '{clip-timestamp}',
      ]) {
        expect(
          BaseAnkiRepository.upgradeMiscInfoMapping(
            settingsJson(<String, String>{'MiscInfo': userValue}),
          ),
          isNull,
          reason: '用户自己设过的 "$userValue" 被覆盖 = 吞掉用户意图',
        );
      }
    });

    test('没有 MiscInfo 映射 / 没有 fieldMappings → 不改', () {
      expect(
        BaseAnkiRepository.upgradeMiscInfoMapping(
          settingsJson(<String, String>{'Expression': '{expression}'}),
        ),
        isNull,
      );
      expect(
        BaseAnkiRepository.upgradeMiscInfoMapping(
          jsonEncode(<String, dynamic>{'tags': ''}),
        ),
        isNull,
      );
    });

    test('串损坏 → 返回 null 而非抛（诊断留给 loadSettings 的既有 try-catch）', () {
      expect(BaseAnkiRepository.upgradeMiscInfoMapping('not json'), isNull);
      expect(BaseAnkiRepository.upgradeMiscInfoMapping('[1,2,3]'), isNull);
      expect(BaseAnkiRepository.upgradeMiscInfoMapping(''), isNull);
    });
  });
}
