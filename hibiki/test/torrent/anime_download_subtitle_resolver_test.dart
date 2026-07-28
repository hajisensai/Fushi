import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

import 'package:hibiki/src/media/torrent/anime_download_plan.dart';
import 'package:hibiki/src/media/torrent/anime_download_subtitle_resolver.dart';

/// BUG-1206 的集成层：resolver 真的走 HTTP 拉条目文件、真的按包内文件名反查、
/// 真的只下配得上的那几条。断言的是**发出去的请求**与**落盘的文件**，不是符号。
void main() {
  late Directory tempDir;
  late List<String> requested;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('jimaku_resolver_test');
    requested = <String>[];
  });

  tearDown(() {
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// Jimaku 条目返回 [episodes] 这些集的字幕；文件本体一律返回 `cue`。
  MockClient jimakuServing(List<int> episodes) {
    return MockClient((http.Request req) async {
      final String url = req.url.toString();
      requested.add(url);
      if (url.contains('/files')) {
        return http.Response.bytes(
          utf8.encode(jsonEncode(<Map<String, Object>>[
            for (final int ep in episodes)
              <String, Object>{
                'name': 'Show - ${ep.toString().padLeft(2, '0')}.ja.srt',
                'url': 'https://jimaku.cc/f/$ep.srt',
              },
          ])),
          200,
        );
      }
      if (url.contains('/f/')) return http.Response('cue', 200);
      return http.Response('', 404);
    });
  }

  JimakuPlanSubtitleResolver buildResolver(MockClient client,
      {String apiKey = 'key'}) {
    return JimakuPlanSubtitleResolver(
      apiKeyProvider: () => apiKey,
      httpClientFactory: () async => client,
      stagingDirFor: (String planId) =>
          Directory(p.join(tempDir.path, 'subs', planId)),
    );
  }

  AnimeDownloadPlan pendingPlan({int? entryId = 7, String? language}) {
    return AnimeDownloadPlan(
      id: 'a' * 40,
      createdAtMs: 0,
      seriesTitle: 'Show',
      torrentTitle: '[Grp] Show S2 Complete',
      magnet: 'magnet:?xt=urn:btih:${'a' * 40}',
      qbCategory: 'hibiki',
      jimakuEntryId: entryId,
      jimakuLanguage: language,
      subtitleStatus: AnimeDownloadPlan.subtitlePending,
    );
  }

  List<String> packVideos(int count) => <String>[
        for (int ep = 1; ep <= count; ep++)
          p.join(tempDir.path, 'dl',
              '[Grp] Show - ${ep.toString().padLeft(2, '0')} [1080p].mkv'),
      ];

  test('错季：包 01-12 遇绝对编号条目 13-24 → 失败带原因，且一个字节都没下', () async {
    final MockClient client =
        jimakuServing(<int>[for (int e = 13; e <= 24; e++) e]);
    final ResolvedPlanSubtitles result =
        await buildResolver(client).resolve(pendingPlan(), packVideos(12));

    expect(result.subtitles, isEmpty);
    expect(result.failureReason, 'no jimaku file matches the pack episodes');
    expect(requested.where((String u) => u.contains('/f/')), isEmpty,
        reason: '配不上就不该下载任何字幕文件');
    expect(Directory(p.join(tempDir.path, 'subs')).existsSync(), isFalse);
  });

  test('条数收敛：条目 24 集、包只 12 集 → 只下 12 条且都是包里的集', () async {
    final MockClient client =
        jimakuServing(<int>[for (int e = 1; e <= 24; e++) e]);
    final ResolvedPlanSubtitles result =
        await buildResolver(client).resolve(pendingPlan(), packVideos(12));

    expect(result.failureReason, isNull);
    expect(result.subtitles, hasLength(12));
    expect(
      result.subtitles.map((PlanSubtitle s) => s.episode).toList(),
      <int>[for (int e = 1; e <= 12; e++) e],
    );
    // 只对这 12 集发过下载请求（第 13 集之后一条都没碰）。
    final List<String> downloads =
        requested.where((String u) => u.contains('/f/')).toList();
    expect(downloads, hasLength(12));
    expect(downloads, isNot(contains('https://jimaku.cc/f/13.srt')));
    // 真落盘了。
    for (final PlanSubtitle s in result.subtitles) {
      expect(File(s.stagedPath).readAsStringSync(), 'cue');
      expect(s.language, 'ja');
    }
  });

  test('缺 API key / 缺条目 id → 明确原因，不发请求', () async {
    final MockClient client = jimakuServing(<int>[1]);
    expect(
      (await buildResolver(client, apiKey: '  ')
              .resolve(pendingPlan(), packVideos(1)))
          .failureReason,
      'jimaku api key missing',
    );
    expect(
      (await buildResolver(client)
              .resolve(pendingPlan(entryId: null), packVideos(1)))
          .failureReason,
      'no jimaku entry recorded',
    );
    expect(requested, isEmpty);
  });

  test('条目一个文件都没有 → 明确原因', () async {
    final ResolvedPlanSubtitles result =
        await buildResolver(jimakuServing(<int>[]))
            .resolve(pendingPlan(), packVideos(3));
    expect(result.failureReason, 'jimaku entry has no files');
  });

  test('包里没有视频文件 → 明确原因，不发请求', () async {
    final ResolvedPlanSubtitles result =
        await buildResolver(jimakuServing(<int>[1]))
            .resolve(pendingPlan(), const <String>[]);
    expect(result.failureReason, 'no video files in pack');
    expect(requested, isEmpty);
  });
}
