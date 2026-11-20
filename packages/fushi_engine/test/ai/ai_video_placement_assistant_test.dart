// 视频摆放判断的回复解析（ai_video_placement_assistant.dart）：模型回复必须过本地
// 校验——键在提问的文件键里、判定是四种之一、episode 的季集落在作品正片范围内。
import 'dart:convert';

import 'package:fushi_engine/ai/ai_video_placement_assistant.dart';
import 'package:test/test.dart';

void main() {
  final AiVideoPlacementQuery query = AiVideoPlacementQuery(
    workTitle: 'Beta',
    regularEpisodeMinutes: 24,
    regularLocalFiles: 12,
    regularSeasons: const <int, int>{1: 12},
    files: const <AiVideoPlacementFile>[
      AiVideoPlacementFile(
        key: 'f1',
        path: 'Beta/Season 00/movie.mkv',
        minutes: 95,
        boundTo: 'S00E01',
      ),
      AiVideoPlacementFile(key: 'f2', path: 'Beta/ep05.mkv', minutes: 24),
      AiVideoPlacementFile(key: 'f3', path: 'Beta/ova.mkv'),
    ],
  );

  List<AiVideoPlacementAnswer> parse(List<Object?> files) =>
      parseAiVideoPlacementAnswers(
        '```json\n${jsonEncode(<String, Object?>{'files': files})}\n```',
        query: query,
      );

  test('提问体：作品事实与文件事实都在，没有时长的不写 minutes', () {
    final Map<String, Object?> body =
        jsonDecode(buildAiVideoPlacementUserPrompt(query))
            as Map<String, Object?>;
    expect(body['work'], <String, Object?>{
      'title': 'Beta',
      'regularEpisodeMinutes': 24,
      'regularSeasons': <String, Object?>{'1': 12},
      'localRegularFiles': 12,
    });
    expect((body['files']! as List<Object?>)[0], <String, Object?>{
      'key': 'f1',
      'path': 'Beta/Season 00/movie.mkv',
      'minutes': 95,
      'boundTo': 'S00E01',
    });
    expect((body['files']! as List<Object?>)[2], <String, Object?>{
      'key': 'f3',
      'path': 'Beta/ova.mkv',
      'boundTo': null,
    });
  });

  test('合法回复原样采用；movie 才带片名', () {
    final List<AiVideoPlacementAnswer> out = parse(<Object?>[
      <String, Object?>{
        'key': 'f1',
        'verdict': 'movie',
        'confidence': 0.93,
        'title': ' Beta Movie ',
        'reason': 'x',
      },
      <String, Object?>{
        'key': 'f2',
        'verdict': 'episode',
        'confidence': 0.9,
        'season': 1,
        'episode': 5,
      },
      <String, Object?>{
        'key': 'f3',
        'verdict': 'special',
        'confidence': 0.86,
        'title': 'ignored',
      },
    ]);
    expect(
      out.map((AiVideoPlacementAnswer a) => a.verdict),
      <AiVideoPlacementVerdict>[
        AiVideoPlacementVerdict.movie,
        AiVideoPlacementVerdict.episode,
        AiVideoPlacementVerdict.special,
      ],
    );
    expect(out[0].title, 'Beta Movie');
    expect(out[0].isAutoAcceptable, isTrue);
    expect((out[1].season, out[1].episode), (1, 5));
    expect(out[2].title, isNull);
  });

  test('不在提问里的键、重复的键丢弃；未知判定 / 越界置信度不可自动执行', () {
    final List<AiVideoPlacementAnswer> out = parse(<Object?>[
      <String, Object?>{'key': 'f9', 'verdict': 'movie', 'confidence': 1},
      <String, Object?>{'key': 'f1', 'verdict': 'delete', 'confidence': 1},
      <String, Object?>{'key': 'f1', 'verdict': 'movie', 'confidence': 1},
      <String, Object?>{'key': 'f2', 'verdict': 'special', 'confidence': 7},
      'junk',
    ]);
    expect(out.map((AiVideoPlacementAnswer a) => a.key), <String>['f1', 'f2']);
    expect(out[0].verdict, AiVideoPlacementVerdict.unsure);
    expect(out[0].isAutoAcceptable, isFalse);
    expect(out[1].confidence, 0);
    expect(out[1].isAutoAcceptable, isFalse);
  });

  test('episode 给不出作品里存在的集位 → 降为 unsure', () {
    for (final Map<String, Object?> bad in <Map<String, Object?>>[
      <String, Object?>{'season': 2, 'episode': 1},
      <String, Object?>{'season': 1, 'episode': 13},
      <String, Object?>{'season': 1, 'episode': 0},
      <String, Object?>{'season': 0, 'episode': 1},
      <String, Object?>{'season': '1', 'episode': 1},
      <String, Object?>{},
    ]) {
      final AiVideoPlacementAnswer a = parse(<Object?>[
        <String, Object?>{
          'key': 'f2',
          'verdict': 'episode',
          'confidence': 0.99,
          ...bad,
        },
      ]).single;
      expect(a.verdict, AiVideoPlacementVerdict.unsure, reason: '$bad');
      expect(a.isAutoAcceptable, isFalse);
    }
  });

  test('抠不出 JSON → 没有结论', () {
    expect(parseAiVideoPlacementAnswers('sorry', query: query), isEmpty);
    expect(
      parseAiVideoPlacementAnswers('{"files": "x"}', query: query),
      isEmpty,
    );
  });
}
