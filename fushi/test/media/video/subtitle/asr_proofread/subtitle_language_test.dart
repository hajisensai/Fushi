import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_asr_core/asr_core.dart' as asr;
import 'package:fushi_engine/ai/web_search.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/ai_text_completer.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_clip_classifier.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_consistency_pass.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_glossary.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_language.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_pipeline_cancel.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_prompts_zh.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_proofreader.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_song_lyrics.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_host_job_runner.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_pipeline.dart';
import 'package:fushi_engine/media/video/video_duration_probe.dart';

import '../../../../helpers/fake_ai_text_completer.dart';

/// 只记下搜索词、不联网的搜索客户端。
class _RecordingSearch implements WebSearchClient {
  final List<String> queries = <String>[];

  @override
  bool get isEnabled => true;

  @override
  Future<List<WebSearchHit>> search(String query, {int limit = 8}) async {
    queries.add(query);
    return const <WebSearchHit>[];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<List<String>> _lyricQueries(SubtitleSongQuery query) async {
  final _RecordingSearch search = _RecordingSearch();
  await WebSearchSubtitleLyricsFinder(search).find(
    query,
    completer: FakeAiCompleter((String _, int _) => ''),
    usage: SubtitleAiUsageTally(),
    cancel: SubtitleCancelSource(),
  );
  return search.queries;
}

/// 普通话字幕（spec `2026-11-04-video-subtitle-mandarin`）：语言值的各项映射、音轨挑选与
/// 猜测、日语缓存键与提示词不变、各阶段按语言换提示词、歌词搜索词、汉字近形名、任务参数。
void main() {
  group('VideoSubtitleLanguage', () {
    test('标签 / ASR 语言 / fromTag', () {
      expect(VideoSubtitleLanguage.japanese.tag, 'ja');
      expect(VideoSubtitleLanguage.mandarin.tag, 'zh');
      expect(
        VideoSubtitleLanguage.mandarin.asrLanguage,
        asr.AsrLanguage.mandarin,
      );
      expect(
        VideoSubtitleLanguage.japanese.asrLanguage,
        asr.AsrLanguage.japanese,
      );
      expect(
        VideoSubtitleLanguage.fromTag(' ZH '),
        VideoSubtitleLanguage.mandarin,
      );
      expect(VideoSubtitleLanguage.fromTag('ko'), isNull);
      expect(VideoSubtitleLanguage.fromTag(null), isNull);
    });

    test('日语的任务目录与专名表键不变，普通话另开', () {
      expect(VideoSubtitleLanguage.japanese.jobId('abc'), 'abc');
      expect(VideoSubtitleLanguage.mandarin.jobId('abc'), 'abc.zh');
      expect(VideoSubtitleLanguage.japanese.glossaryKey('work:1'), 'work:1');
      expect(VideoSubtitleLanguage.mandarin.glossaryKey('work:1'), 'work:1:zh');
      const String video = 'Z:/no/such/video.mkv';
      expect(
        videoSubtitleJobIdFor(video, VideoSubtitleLanguage.japanese),
        videoSubtitleJobId(video),
      );
      expect(
        videoSubtitleJobIdFor(video, VideoSubtitleLanguage.mandarin),
        '${videoSubtitleJobId(video)}.zh',
      );
    });

    test('普通话作品名：中文原名优先，日文原名退回显示标题', () {
      const SubtitleWorkContext cn = SubtitleWorkContext(
        workKey: 'w',
        title: 'Nirvana in Fire',
        originalTitle: '琅琊榜',
      );
      const SubtitleWorkContext jp = SubtitleWorkContext(
        workKey: 'w',
        title: '间谍过家家',
        originalTitle: 'スパイファミリー',
      );
      expect(VideoSubtitleLanguage.mandarin.workTitle(cn), '琅琊榜');
      expect(VideoSubtitleLanguage.mandarin.workTitle(jp), '间谍过家家');
      expect(VideoSubtitleLanguage.japanese.workTitle(jp), jp.japaneseTitle);
    });
  });

  group('音轨', () {
    const List<AudioTrackFacts> dual = <AudioTrackFacts>[
      AudioTrackFacts(index: 1, language: 'jpn'),
      AudioTrackFacts(index: 2, language: 'chi'),
    ];

    test('按语言挑音轨，找不到取第一条', () {
      expect(
        pickVideoSubtitleAudioStream(dual, VideoSubtitleLanguage.japanese),
        1,
      );
      expect(
        pickVideoSubtitleAudioStream(dual, VideoSubtitleLanguage.mandarin),
        2,
      );
      expect(
        pickVideoSubtitleAudioStream(const <AudioTrackFacts>[
          AudioTrackFacts(index: 3, language: 'eng'),
          AudioTrackFacts(index: 4, language: 'zh-Hant'),
        ], VideoSubtitleLanguage.mandarin),
        4,
      );
      expect(
        pickVideoSubtitleAudioStream(const <AudioTrackFacts>[
          AudioTrackFacts(index: 5, language: 'eng'),
        ], VideoSubtitleLanguage.mandarin),
        5,
      );
    });

    test('只有中文标签才猜普通话；双语 / 无标签按日语', () {
      expect(
        guessVideoSubtitleLanguage(const <AudioTrackFacts>[
          AudioTrackFacts(index: 1, language: 'chi'),
        ]),
        VideoSubtitleLanguage.mandarin,
      );
      expect(guessVideoSubtitleLanguage(dual), VideoSubtitleLanguage.japanese);
      expect(
        guessVideoSubtitleLanguage(const <AudioTrackFacts>[
          AudioTrackFacts(index: 1),
        ]),
        VideoSubtitleLanguage.japanese,
      );
      expect(
        guessVideoSubtitleLanguage(const <AudioTrackFacts>[]),
        VideoSubtitleLanguage.japanese,
      );
    });
  });

  group('提示词按语言选', () {
    test('日语提示词缺省不变；普通话换中文规则', () {
      final String ja = buildProofreadStablePrefix(
        title: 'T',
        glossaryText: '',
      );
      expect(
        buildProofreadStablePrefix(
          title: 'T',
          glossaryText: '',
          language: VideoSubtitleLanguage.japanese,
        ),
        ja,
      );
      expect(ja, contains(kSubtitleProofreadRules));
      final String zh = buildProofreadStablePrefix(
        title: 'T',
        glossaryText: '',
        language: VideoSubtitleLanguage.mandarin,
      );
      expect(zh, contains(kSubtitleProofreadRulesZh));
      expect(zh, isNot(contains(kSubtitleProofreadRules)));
    });

    test('写法统一与片段分类也换中文', () {
      expect(
        buildConsistencyStablePrefix(
          title: 'T',
          glossaryText: '',
          language: VideoSubtitleLanguage.mandarin,
        ),
        allOf(
          startsWith(kSubtitleConsistencyRulesZh.split('{title}').first),
          isNot(contains(kSubtitleConsistencyRules.split('{title}').first)),
        ),
      );
      final String clipZh = buildClipClassifyStablePrefix(
        'T',
        language: VideoSubtitleLanguage.mandarin,
      );
      expect(clipZh, isNot(buildClipClassifyStablePrefix('T')));
      expect(clipZh, isNot(contains('アニメ')));
    });
  });

  test('歌词搜索词：普通话用「歌词」，日语仍是「歌詞」', () async {
    const List<String> sung = <String>['♪我们一起走过的那些年', '♪不会忘记'];
    expect(
      await _lyricQueries(
        const SubtitleSongQuery(
          workTitle: 'W',
          sungLines: sung,
          title: '那些年',
          artist: '胡夏',
          language: VideoSubtitleLanguage.mandarin,
        ),
      ),
      <String>['那些年 胡夏 ${SubtitleLyricsLabelsZh.searchSuffix}'],
    );
    expect(SubtitleLyricsLabelsZh.searchSuffix, '歌词');
    expect(
      await _lyricQueries(
        const SubtitleSongQuery(
          workTitle: 'W',
          sungLines: sung,
          language: VideoSubtitleLanguage.mandarin,
        ),
      ),
      <String>['"我们一起走过的那些年" 歌词'],
    );
    expect(
      await _lyricQueries(
        const SubtitleSongQuery(workTitle: 'W', sungLines: sung, title: 'S'),
      ),
      <String>['S 歌詞'],
    );
  });

  group('普通话写法统一：汉字名差一个字', () {
    const List<SubtitleGlossaryEntry> names = <SubtitleGlossaryEntry>[
      SubtitleGlossaryEntry(ja: '梅长苏', kind: '人名'),
    ];

    test('同长、差一字的汉字串标为可疑', () {
      expect(
        subtitleConsistencySuspects(
          '梅常苏来了',
          names,
          language: VideoSubtitleLanguage.mandarin,
        ),
        <String>['梅常苏→梅长苏?'],
      );
    });

    test('正式写法本身不报；日语不跑汉字近形', () {
      expect(
        subtitleConsistencySuspects(
          '梅长苏来了',
          names,
          language: VideoSubtitleLanguage.mandarin,
        ),
        isEmpty,
      );
      expect(subtitleConsistencySuspects('梅常苏来了', names), isEmpty);
    });
  });

  group('任务参数 language', () {
    test('缺省日语、后缀跟语言走', () {
      final VideoSubtitleJobParams ja = VideoSubtitleJobParams.parse(
        const <String, Object?>{'videoId': 'v1'},
      );
      expect(ja.language, VideoSubtitleLanguage.japanese);
      expect(ja.suffix, 'ja');
      final VideoSubtitleJobParams zh = VideoSubtitleJobParams.parse(
        const <String, Object?>{'videoId': 'v1', 'language': 'zh'},
      );
      expect(zh.language, VideoSubtitleLanguage.mandarin);
      expect(zh.suffix, 'zh');
      final VideoSubtitleJobParams custom = VideoSubtitleJobParams.parse(
        const <String, Object?>{
          'videoId': 'v1',
          'language': 'zh',
          'suffix': 'zh-Hans',
        },
      );
      expect(custom.suffix, 'zh-Hans');
    });

    test('不认识的语言 → FormatException', () {
      expect(
        () => VideoSubtitleJobParams.parse(const <String, Object?>{
          'videoId': 'v1',
          'language': 'ko',
        }),
        throwsFormatException,
      );
    });
  });
}
