import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/video/subtitle/subtitle_language_preference.dart';
import 'package:fushi/src/media/video/video_duration_probe.dart';

class _Cand {
  const _Cand(this.name, this.language);
  final String name;
  final String? language;
}

void main() {
  group('normalizeSubtitleLanguageCode', () {
    test('BCP-47 取主标签', () {
      expect(normalizeSubtitleLanguageCode('ja-JP'), 'ja');
      expect(normalizeSubtitleLanguageCode('zh-Hans'), 'zh');
      expect(normalizeSubtitleLanguageCode('zh_CN'), 'zh');
      expect(normalizeSubtitleLanguageCode('pt-BR'), 'pt');
      expect(normalizeSubtitleLanguageCode('  KO  '), 'ko');
    });

    test('ISO 639-2 / 俗写映射到 639-1', () {
      expect(normalizeSubtitleLanguageCode('jpn'), 'ja');
      expect(normalizeSubtitleLanguageCode('jp'), 'ja');
      expect(normalizeSubtitleLanguageCode('kor'), 'ko');
      expect(normalizeSubtitleLanguageCode('chs'), 'zh');
      expect(normalizeSubtitleLanguageCode('cht'), 'zh');
      expect(normalizeSubtitleLanguageCode('yue'), 'zh');
      expect(normalizeSubtitleLanguageCode('eng'), 'en');
      expect(normalizeSubtitleLanguageCode('ger'), 'de');
    });

    test('空/空白 → null；不在别名表里的三字母原样返回（比错映射安全）', () {
      expect(normalizeSubtitleLanguageCode(null), isNull);
      expect(normalizeSubtitleLanguageCode(''), isNull);
      expect(normalizeSubtitleLanguageCode('   '), isNull);
      expect(normalizeSubtitleLanguageCode('swe'), 'swe');
    });
  });

  group('resolveSubtitleDownloadLanguage（默认取视频语言）', () {
    test('用户显式选的字幕语言压过一切——他就这件事表过态', () {
      expect(
        resolveSubtitleDownloadLanguage(
          explicitSubtitlePreference: 'zh',
          videoContentLanguage: 'ja',
          contentMetadataLanguage: 'ja',
          globalDefaultContentLanguage: 'ja',
        ),
        'zh',
      );
    });

    test('没显式选 → 视频内容语言（用户对本视频手动指定的最优先）', () {
      expect(
        resolveSubtitleDownloadLanguage(
          videoContentLanguage: 'ko-KR',
          contentMetadataLanguage: 'ja',
          globalDefaultContentLanguage: 'en',
        ),
        'ko',
        reason: 'VideoBooks.language 是用户手动指定，压过刮削与音轨',
      );
    });

    test('没手动指定 → 内容元数据（刮削 originalLanguage / 音轨 tag）', () {
      expect(
        resolveSubtitleDownloadLanguage(
          contentMetadataLanguage: 'jpn',
          globalDefaultContentLanguage: 'en',
        ),
        'ja',
      );
    });

    test('都没有 → 全局默认内容语言', () {
      expect(
        resolveSubtitleDownloadLanguage(
            globalDefaultContentLanguage: 'zh-Hant'),
        'zh',
      );
    });

    test('🔴 全空 → null，绝不猜、绝不硬编码日语（本 app 无全局学习语言）', () {
      expect(resolveSubtitleDownloadLanguage(), isNull);
      expect(
        resolveSubtitleDownloadLanguage(
          explicitSubtitlePreference: '',
          videoContentLanguage: '   ',
          contentMetadataLanguage: '',
          globalDefaultContentLanguage: '',
        ),
        isNull,
      );
    });
  });

  group('rankByPreferredLanguage（是排序，不是过滤）', () {
    final List<_Cand> candidates = <_Cand>[
      const _Cand('en1', 'en'),
      const _Cand('ja1', 'ja'),
      const _Cand('zh1', 'zh'),
      const _Cand('ja2', 'ja-JP'),
      const _Cand('unknown', null),
    ];

    List<String> namesOf(List<_Cand> list) =>
        list.map((_Cand c) => c.name).toList();

    test('首选语言排到前面，其余**一条不丢**', () {
      final List<_Cand> ranked = rankByPreferredLanguage(
        candidates,
        'ja',
        (_Cand c) => c.language,
      );
      expect(namesOf(ranked), <String>['ja1', 'ja2', 'en1', 'zh1', 'unknown']);
      expect(
        ranked.length,
        candidates.length,
        reason: '按语言硬过滤会把「只有英文字幕的日语番」从有字幕变成没字幕',
      );
    });

    test('归一后比较：`jpn` / `ja-JP` 都算 ja', () {
      final List<_Cand> ranked = rankByPreferredLanguage(
        <_Cand>[const _Cand('en', 'en'), const _Cand('x', 'jpn')],
        'ja-JP',
        (_Cand c) => c.language,
      );
      expect(namesOf(ranked), <String>['x', 'en']);
    });

    test('同语言内部保持原顺序（稳定）——否则重跑两次拿到不同字幕', () {
      final List<_Cand> ranked = rankByPreferredLanguage(
        candidates,
        'ja',
        (_Cand c) => c.language,
      );
      expect(
        namesOf(ranked).sublist(0, 2),
        <String>['ja1', 'ja2'],
        reason: '候选进来时已按 provider 优先级+下载量排好，语言只是外层键',
      );
    });

    test('首选为 null / 无人命中 → 原样返回（不做无谓重排）', () {
      expect(
        rankByPreferredLanguage(candidates, null, (_Cand c) => c.language),
        same(candidates),
      );
      expect(
        rankByPreferredLanguage(candidates, 'sv', (_Cand c) => c.language),
        same(candidates),
      );
    });
  });

  group('parseFfprobeFacts（时长 + 音轨语言一次拿到）', () {
    const String json = '''
{
  "streams": [
    {"index": 0, "codec_type": "video"},
    {"index": 1, "codec_type": "audio", "tags": {"language": "jpn"}},
    {"index": 2, "codec_type": "audio", "tags": {"language": "eng"}},
    {"index": 3, "codec_type": "subtitle", "tags": {"language": "chi"}}
  ],
  "format": {"duration": "1421.234000"}
}
''';

    test('时长与音轨语言都解析出来，按流顺序', () {
      final VideoProbeFacts facts = parseFfprobeFacts(json);
      expect(facts.durationMs, 1421234);
      expect(facts.audioLanguages, <String>['jpn', 'eng']);
      expect(facts.primaryAudioLanguage, 'jpn');
    });

    test('只取音轨——字幕轨的 language 不能冒充视频语言', () {
      expect(parseFfprobeFacts(json).audioLanguages, isNot(contains('chi')));
    });

    test('`und` 等同未标注，跳过它去看后面真有标注的音轨', () {
      const String withUnd = '''
{"streams":[
  {"index":0,"codec_type":"audio","tags":{"language":"und"}},
  {"index":1,"codec_type":"audio","tags":{"language":"kor"}}
]}
''';
      final VideoProbeFacts facts = parseFfprobeFacts(withUnd);
      expect(facts.audioLanguages, <String>['kor']);
      expect(facts.primaryAudioLanguage, 'kor');
    });

    test('一半缺失不让另一半作废', () {
      expect(
        parseFfprobeFacts('{"format":{"duration":"60"}}').durationMs,
        60000,
      );
      expect(
        parseFfprobeFacts('{"format":{"duration":"60"}}').audioLanguages,
        isEmpty,
      );
      final VideoProbeFacts noDuration = parseFfprobeFacts(
        '{"streams":[{"codec_type":"audio","tags":{"language":"ja"}}]}',
      );
      expect(noDuration.durationMs, isNull);
      expect(noDuration.primaryAudioLanguage, 'ja');
    });

    test('无 tags / 非 json / 空 → 空结果，不抛', () {
      expect(
        parseFfprobeFacts('{"streams":[{"codec_type":"audio"}]}')
            .audioLanguages,
        isEmpty,
      );
      expect(parseFfprobeFacts('not json').durationMs, isNull);
      expect(parseFfprobeFacts('').audioLanguages, isEmpty);
    });
  });
}
