import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_anki/hibiki_anki.dart';

import '../helpers/source_guard.dart';

/// 英语制卡音标（IPA）契约：Yomitan `ipa`-mode 词典（典型：英语）在 pitch 组里
/// 带 `transcriptions` 而没有 `pitchPositions`，修复前制卡侧只消费 positions，
/// 英语卡的声调字段恒空（弹窗展示侧 TODO-688 早已渲染，唯独制卡断链）。
///
/// 契约（与 Yomitan 命名对齐）：
///  1. `{pitch-accent-positions}`（默认 Lapis PitchPosition 映射）在制卡侧同时
///     渲染 positions 与 transcriptions——英语卡零配置拿到音标；日语纯声调词典
///     的 transcriptions 恒为空数组，输出逐字节不变。
///  2. 新增 `{phonetic-transcriptions}`（Yomitan 同名 marker）只含 IPA，供用户
///     单独映射。
///
/// popup.js 三镜像的字节一致由 browser_extension_popup_parity_guard_test 锁定，
/// 本文件只扫 app 侧真身。
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
        sasayakiRef: null,
        processedAudio: '',
        dictionaryMediaTags: const <String, String>{},
      );
}

const String _ipaHtml = '<ol><li><span style="display:inline;">'
    '<span>[</span><span>ˈwɜːd</span><span>]</span></span></li></ol>';

void main() {
  group('{phonetic-transcriptions} marker (Yomitan 命名)', () {
    test('renderer maps the marker to payload.phoneticTranscriptions', () {
      const AnkiMiningPayload payload = AnkiMiningPayload(
        expression: 'word',
        phoneticTranscriptions: _ipaHtml,
      );
      final String out = AnkiHandlebarRenderer.render(
        '{phonetic-transcriptions}',
        payload,
        const AnkiMiningContext(sentence: ''),
      );
      expect(out, _ipaHtml);
    });

    test('fromJson reads the popup.js payload key phoneticTranscriptions', () {
      final AnkiMiningPayload payload = AnkiMiningPayload.fromJson(
        <String, dynamic>{
          'expression': 'word',
          'phoneticTranscriptions': _ipaHtml,
        },
      );
      expect(payload.phoneticTranscriptions, _ipaHtml);
      // 缺 key（旧草稿/旧桥）安全回退为空，不炸。
      expect(
        AnkiMiningPayload.fromJson(<String, dynamic>{'expression': 'a'})
            .phoneticTranscriptions,
        '',
      );
    });

    test('coreOptions offers {phonetic-transcriptions} in the mapping UI', () {
      expect(
        AnkiHandlebarOptions.coreOptions,
        contains('{phonetic-transcriptions}'),
      );
    });

    test(
        'renderMediaPayload passes phoneticTranscriptions through '
        '(媒体二次渲染透传，防 16 字段漂移)', () {
      final _TestRepo repo = _TestRepo();
      final RenderedMinedFields rendered = repo.renderFor(
        settings: const AnkiSettings(
          fieldMappings: <String, String>{'IPA': '{phonetic-transcriptions}'},
        ),
        payload: const AnkiMiningPayload(
          expression: 'word',
          phoneticTranscriptions: _ipaHtml,
        ),
        context: const AnkiMiningContext(sentence: ''),
      );
      expect(rendered.fields['IPA'], _ipaHtml);
    });
  });

  group('popup.js mining builders (source scan)', () {
    // flutter test cwd 是 hibiki 包根。
    final String src = File('assets/popup/popup.js').readAsStringSync();

    /// 取顶层函数体：从 `function <name>(` 到下一个列首 `}`。锚定函数体而不是
    /// 全文件，防止别处注释里出现同名字面量假绿；再用共享 [maskComments] 把注释
    /// 换成**等长空白**，防「把代码注释掉但字面量还在」的假绿（变异实测过：
    /// 注释掉 forEach 本守卫必红）。
    ///
    /// 旧写法是「丢掉整行以 `//` 开头的行」，只堵住了行注释一种形态：
    /// `/* items += ... */` 这样的块注释、以及 `foo(); // pitchGroup.transcriptions`
    /// 这样的行尾注释都一概放行。[maskComments] 是词法扫描，三种形态一并吃掉，
    /// 且模板串 / 引号串内容原样保留（本文件断言里的 `` `<ol>${items}</ol>` `` 不受影响）。
    String functionBody(String name) {
      final int start = src.indexOf('function $name(');
      expect(start, greaterThanOrEqualTo(0),
          reason: 'popup.js 缺少 function $name');
      final int end = src.indexOf('\n}', start);
      expect(end, greaterThan(start), reason: '$name 函数体未闭合？');
      return maskComments(src.substring(start, end + 2));
    }

    test(
        'constructPitchPositionHtml folds transcriptions into '
        '{pitch-accent-positions}（英语默认路径）', () {
      final String body = functionBody('constructPitchPositionHtml');
      expect(body, contains('pitchGroup.transcriptions'),
          reason: '制卡侧不再消费 transcriptions —— 英语卡声调字段会回到恒空');
      expect(body, contains('escapePitchText(ipa)'),
          reason: 'IPA 来自词典数据，进 HTML 前必须转义');
      // 全空组返回 ''（而不是 <ol></ol> 空壳），字段才会被按空跳过。
      expect(body, contains(r"items ? `<ol>${items}</ol>` : ''"));
    });

    test(
        'constructPhoneticTranscriptionsHtml exists and only reads '
        'transcriptions', () {
      final String body = functionBody('constructPhoneticTranscriptionsHtml');
      expect(body, contains('pitchGroup.transcriptions'));
      expect(body, isNot(contains('pitchGroup.pitchPositions')),
          reason: '{phonetic-transcriptions} 只含 IPA，不混声调 positions');
    });

    test('buildMinePayload computes and ships phoneticTranscriptions', () {
      final String body = functionBody('buildMinePayload');
      expect(
        body,
        contains(
            'const phoneticTranscriptions = constructPhoneticTranscriptionsHtml(pitches);'),
      );
      // return 对象里必须带该 key（shorthand 属性）。
      expect(body, contains('\n        phoneticTranscriptions,'));
    });
  });
}
