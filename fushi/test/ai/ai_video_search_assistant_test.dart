// 视频搜索辅助的纯逻辑：查询词解析（去重 / 排除原词 / 截断）、重排解析（越界 /
// 重复 / 缺失补齐 / 坏 JSON 恒等）、三种提示词含全部候选下标、请求函数只喂前 30 条。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fushi/src/ai/ai_chat_client.dart';
import 'package:fushi/src/ai/ai_provider_config.dart';
import 'package:fushi/src/ai/ai_video_search_assistant.dart';
import 'package:fushi_engine/media/torrent/video_resource_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi/src/media/video/subtitle/video_subtitle_backfill.dart';
import 'package:fushi_engine/media/video/subtitle/video_subtitle_provider.dart';

class _Sub extends VideoSubtitleCandidate {
  _Sub(int i)
    : super(
        providerId: 'jimaku',
        remoteId: 'r$i',
        fileName: 'sub-$i.ass',
        language: 'ja',
        providerPriority: 10,
        releaseName: 'Release $i',
        episode: i + 1,
        downloadCount: i * 10,
        uploadedAtMs: 1700000000000 + i,
      );
}

class _Res extends VideoResourceCandidate {
  _Res(int i)
    : super(
        providerId: 'nyaa',
        providerInstanceId: 'nyaa',
        remoteId: 'n$i',
        title: '[Group] Show - 0$i [1080p]',
        providerPriority: 10,
        seeders: i,
        sizeBytes: 1000 * i,
        resolution: '1080p',
        releaseGroup: 'Group',
        publishedAt: DateTime.utc(2024, 1, 1 + i),
      );
}

AiProviderConfig _provider() => AiProviderConfig(
  id: 'p1',
  presetId: 'openai',
  name: 'Fake',
  baseUrl: Uri.parse('https://example.invalid/v1'),
  apiKey: 'k',
  model: 'm',
);

http.Response _openAiReply(String content) => http.Response(
  jsonEncode(<String, Object?>{
    'choices': <Object?>[
      <String, Object?>{
        'message': <String, Object?>{'content': content},
      },
    ],
  }),
  200,
  headers: <String, String>{'content-type': 'application/json'},
);

/// 记录发出去的 user 消息文本，回固定 [reply]。
AiChatClient _client(String reply, {List<String>? userPrompts}) => AiChatClient(
  client: MockClient((http.Request request) async {
    final Map<String, Object?> body =
        jsonDecode(request.body) as Map<String, Object?>;
    final List<Object?> messages = body['messages'] as List<Object?>;
    for (final Object? m in messages) {
      final Map<String, Object?> message = m as Map<String, Object?>;
      if (message['role'] == 'user') {
        userPrompts?.add(message['content'] as String);
      }
    }
    return _openAiReply(reply);
  }),
);

VideoMediaReference _media() => VideoMediaReference(
  providerId: 'anilist',
  mediaId: '1',
  mediaKind: VideoMetadataMediaKind.tv,
  discoveryCategory: VideoDiscoveryCategory.anime,
  title: '响け！ユーフォニアム',
  originalTitle: '響け！ユーフォニアム',
  aliases: const <String>['Hibike! Euphonium'],
  year: 2015,
  season: 2,
);

void main() {
  group('parseAiSearchQueries', () {
    test('去重、剔除与原词归一化相等的、最多 4 条', () {
      final List<String> out = parseAiSearchQueries(
        '{"queries":["Hibike! Euphonium","hibike!  euphonium","響け！ユーフォニアム",'
        '"Sound! Euphonium","Sound! Euphonium","Hibike","Extra","More"]}',
        exclude: <String>['  hibike! euphonium '],
      );
      expect(out, <String>[
        '響け！ユーフォニアム',
        'Sound! Euphonium',
        'Hibike',
        'Extra',
      ]);
    });

    test('超过 80 字符的截断到 80', () {
      final String long = 'a' * 100;
      final List<String> out = parseAiSearchQueries('{"queries":["$long"]}');
      expect(out.single.length, kAiSearchQueryMaxLength);
    });

    test('围栏包裹的 JSON 也能解析；坏 JSON / 非字符串项返回空', () {
      expect(
        parseAiSearchQueries('```json\n{"queries":["A","B"]}\n```'),
        <String>['A', 'B'],
      );
      expect(parseAiSearchQueries('nothing here'), isEmpty);
      expect(parseAiSearchQueries('{"queries":[1,null,""]}'), isEmpty);
    });
  });

  group('parseAiRankResult', () {
    test('越界与重复剔除，缺失的按原序补在末尾，推荐与备注只留有效下标', () {
      final AiRankResult rank = parseAiRankResult(
        '{"order":[3,"1",3,9,-1,1],"recommended":3,'
        '"notes":{"3":"best","9":"x","0":"  "}}',
        count: 5,
      );
      expect(rank.orderedIds, <int>[3, 1, 0, 2, 4]);
      expect(rank.recommendedIndex, 3);
      expect(rank.notes, <int, String>{3: 'best'});
      expect(rank.isIdentity, isFalse);
    });

    test('坏 JSON 返回恒等排列', () {
      final AiRankResult rank = parseAiRankResult('I refuse.', count: 4);
      expect(rank.orderedIds, <int>[0, 1, 2, 3]);
      expect(rank.recommendedIndex, isNull);
      expect(rank.notes, isEmpty);
      expect(rank.isIdentity, isTrue);
    });

    test('推荐越界归 null；reorder 按排列取值', () {
      final AiRankResult rank = parseAiRankResult(
        '{"order":[2,0,1],"recommended":7}',
        count: 3,
      );
      expect(rank.recommendedIndex, isNull);
      expect(rank.reorder(<String>['a', 'b', 'c']), <String>['c', 'a', 'b']);
    });
  });

  group('提示词', () {
    test('查询扩展提示词带上用户词与作品身份', () {
      final String prompt = buildAiSearchQueriesUserPrompt(
        query: 'hibike 2',
        media: _media(),
      );
      expect(prompt, contains('"hibike 2"'));
      expect(prompt, contains('響け！ユーフォニアム'));
      expect(prompt, contains('Hibike! Euphonium'));
      expect(prompt, contains('Season: 2'));
      expect(
        buildAiSearchQueriesSystemPrompt(AiSearchPurpose.torrent),
        contains('"queries"'),
      );
    });

    test('字幕重排提示词含全部候选下标与字段', () {
      final List<VideoSubtitleCandidate> candidates = List<_Sub>.generate(
        5,
        _Sub.new,
      );
      final String prompt = buildAiSubtitleRankUserPrompt(
        candidates: candidates,
        context: const AiSubtitleRankContext(
          localFileName: '[Group] Show - 01 [1080p].mkv',
          preferredLanguages: <String>['ja'],
          episode: 1,
        ),
      );
      for (int i = 0; i < candidates.length; i++) {
        expect(prompt, contains('"index":$i'));
        expect(prompt, contains('sub-$i.ass'));
      }
      expect(prompt, contains('"ai_translated":false'));
      expect(prompt, contains('"uploaded":"2023-11-14"'));
      expect(prompt, contains('[Group] Show - 01 [1080p].mkv'));
    });

    test('资源重排提示词含全部候选下标与字段', () {
      final List<VideoResourceCandidate> candidates = List<_Res>.generate(
        4,
        _Res.new,
      );
      final String prompt = buildAiResourceRankUserPrompt(
        candidates: candidates,
        context: const AiResourceRankContext(query: 'Show', season: 1),
      );
      for (int i = 0; i < candidates.length; i++) {
        expect(prompt, contains('"index":$i'));
        expect(prompt, contains('[Group] Show - 0$i [1080p]'));
      }
      expect(prompt, contains('"seeders":3'));
      expect(prompt, contains('"published":"2024-01-04"'));
      expect(prompt, contains('Season: 1'));
    });
  });

  group('请求函数', () {
    test('requestAiSearchQueries 剔除原词', () async {
      final List<String> out = await requestAiSearchQueries(
        client: _client('{"queries":["Show","Original"]}'),
        provider: _provider(),
        query: 'show',
        purpose: AiSearchPurpose.subtitle,
      );
      expect(out, <String>['Original']);
    });

    test('字幕重排只喂前 30 条，返回值仍是全长排列', () async {
      final List<VideoSubtitleCandidate> candidates = List<_Sub>.generate(
        35,
        _Sub.new,
      );
      final List<String> prompts = <String>[];
      final AiRankResult rank = await requestAiSubtitleRank(
        client: _client(
          '{"order":[34,2],"recommended":2}',
          userPrompts: prompts,
        ),
        provider: _provider(),
        candidates: candidates,
        context: const AiSubtitleRankContext(),
      );
      expect(prompts.single, contains('"index":29'));
      expect(prompts.single, isNot(contains('"index":30')));
      expect(rank.orderedIds, hasLength(35));
      // 34 在喂给模型的范围之外，但仍是合法下标——解析层按候选总数判界。
      expect(rank.orderedIds.take(3), <int>[34, 2, 0]);
      expect(rank.recommendedIndex, 2);
    });

    test('资源重排空候选不发请求', () async {
      int calls = 0;
      final AiRankResult rank = await requestAiResourceRank(
        client: AiChatClient(
          client: MockClient((_) async {
            calls++;
            return _openAiReply('{}');
          }),
        ),
        provider: _provider(),
        candidates: const <VideoResourceCandidate>[],
        context: const AiResourceRankContext(query: 'x'),
      );
      expect(calls, 0);
      expect(rank.orderedIds, isEmpty);
    });
  });

  group('aiSubtitleBackfillReorder', () {
    final SubtitleBackfillTarget target = SubtitleBackfillTarget(
      bookUid: 'b',
      videoPath: 'D:/v/[Group] Show - 01.mkv',
      media: _media(),
    );

    test('未指派提供商原序返回且不发请求', () async {
      int calls = 0;
      final SubtitleBackfillReorder reorder = aiSubtitleBackfillReorder(
        resolveProvider: () => null,
        clientFactory: () => AiChatClient(
          client: MockClient((_) async {
            calls++;
            return _openAiReply('{}');
          }),
        ),
      );
      final List<VideoSubtitleCandidate> input = List<_Sub>.generate(
        3,
        _Sub.new,
      );
      expect(await reorder(input, target), same(input));
      expect(calls, 0);
    });

    test('AI 失败退回原序；成功按排列重排', () async {
      final List<VideoSubtitleCandidate> input = List<_Sub>.generate(
        3,
        _Sub.new,
      );
      final SubtitleBackfillReorder failing = aiSubtitleBackfillReorder(
        resolveProvider: _provider,
        clientFactory: () => AiChatClient(
          client: MockClient((_) async => http.Response('nope', 500)),
        ),
      );
      expect(await failing(input, target), same(input));

      final SubtitleBackfillReorder ok = aiSubtitleBackfillReorder(
        resolveProvider: _provider,
        clientFactory: () => _client('{"order":[2,0,1]}'),
      );
      final List<VideoSubtitleCandidate> out = await ok(input, target);
      expect(out.map((VideoSubtitleCandidate c) => c.fileName), <String>[
        'sub-2.ass',
        'sub-0.ass',
        'sub-1.ass',
      ]);
    });
  });
}
