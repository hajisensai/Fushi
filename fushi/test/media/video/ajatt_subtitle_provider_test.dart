import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/external_provider.dart';
import 'package:fushi/src/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_models.dart';
import 'package:fushi/src/media/video/subtitle/ajatt_catalog.dart';
import 'package:fushi/src/media/video/subtitle/ajatt_subtitle_provider.dart';
import 'package:fushi/src/media/video/subtitle/video_subtitle_provider.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// AJATT provider：目录文本匹配 → `.kitsuinfo.json` 按 AniList id 确认 → 作品页文件表
/// → 候选。全程用真实页面裁出的 fixture 走 [MockClient]，不联网。
String _fixture(String name) =>
    File('test/fixtures/ajatt/$name').readAsStringSync();

const String _konPage = 'https://subtitles.ajatt.top/anime_tv/k-on!.html';
const String _konInfo =
    'https://raw.githubusercontent.com/Ajatt-Tools/kitsunekko-mirror/'
    'refs/heads/main/subtitles/anime_tv/K-ON!/.kitsuinfo.json';

/// 站点 + raw 仓库的桩；[requests] 记录每次请求 URL 便于断言缓存/请求次数。
MockClient _server({
  required List<String> requests,
  int catalogStatus = 200,
  String? catalogBody,
  int? infoAnilistId = 5680,
  bool infoMissing = false,
}) {
  return MockClient((http.Request request) async {
    final String url = request.url.toString();
    requests.add(url);
    if (url == 'https://subtitles.ajatt.top/index.html') {
      return _utf8(catalogBody ?? _fixture('index.html'), catalogStatus);
    }
    if (url == 'https://subtitles.ajatt.top/drama.html') {
      return _utf8(catalogBody ?? _fixture('drama.html'), catalogStatus);
    }
    if (url == _konPage) return _utf8(_fixture('k-on.html'), 200);
    if (url == _konInfo) {
      if (infoMissing) return http.Response('', 404);
      return _utf8(
        jsonEncode(<String, Object?>{
          'entry_id': 941,
          'name': 'K-ON!',
          'entry_type': 'anime_tv',
          'anilist_id': infoAnilistId,
        }),
        200,
      );
    }
    if (url.startsWith('https://raw.githubusercontent.com/') &&
        url.endsWith('.srt')) {
      return http.Response.bytes(
        utf8.encode('1\n00:00:01,000 --> 00:00:02,000\nけいおん\n'),
        200,
      );
    }
    if (url.endsWith('.kitsuinfo.json')) return http.Response('', 404);
    return http.Response('unexpected $url', 500);
  });
}

/// `http.Response(String)` 默认按 latin1 编码正文，含日文的页面直接抛
/// ArgumentError——真实站点是 UTF-8，桩也必须是。
http.Response _utf8(String body, int status) => http.Response.bytes(
  utf8.encode(body),
  status,
  headers: <String, String>{'content-type': 'text/html; charset=utf-8'},
);

AjattVideoSubtitleProvider _provider(http.Client client) {
  return AjattVideoSubtitleProvider(
    client: AjattClient(client: client, parseInIsolate: false),
  );
}

VideoMediaReference _media({
  int? anilistId,
  VideoDiscoveryCategory category = VideoDiscoveryCategory.anime,
  String title = 'K-ON!',
  String? originalTitle,
  int? episode,
}) {
  return VideoMediaReference(
    providerId: 'anilist',
    mediaId: '${anilistId ?? 0}',
    mediaKind: VideoMetadataMediaKind.tv,
    discoveryCategory: category,
    title: title,
    originalTitle: originalTitle,
    anilistId: anilistId,
    episode: episode,
  );
}

void main() {
  group('AjattVideoSubtitleProvider.search', () {
    test('按标题命中作品 → 作品页文件表 → 候选；未标语言的文件按日语字幕库兜底 ja', () async {
      final List<String> requests = <String>[];
      final AjattVideoSubtitleProvider provider = _provider(
        _server(requests: requests),
      );
      final ProviderBatchResult<VideoSubtitleCandidate> result = await provider
          .search(VideoSubtitleSearchRequest(query: 'K-ON!'));
      expect(result.hasFailures, isFalse, reason: '${result.failures}');
      expect(result.items, hasLength(4));
      final VideoSubtitleCandidate first = result.items.first;
      expect(first.providerId, 'ajatt');
      expect(first.fileName, 'けいおん!.S01E01.廃部!.WEBRip.Netflix.ja[cc].srt');
      expect(first.language, 'ja');
      expect(first.episode, 1);
      expect(first.collectionId, 'anime_tv/k-on!.html');
      expect(first.collectionLabel, 'K-ON!');
      expect(first.uploadedAtMs, 1787659912 * 1000);
      expect(first.fileSize, 36114);
      // shincaps 的 `.ass` 没有语言标签 → ja。
      final VideoSubtitleCandidate shincaps = result.items.singleWhere(
        (VideoSubtitleCandidate c) => c.fileName.startsWith('[shincaps]'),
      );
      expect(shincaps.language, 'ja');
      // 没有 anilistId 的请求不去碰 `.kitsuinfo.json`。
      expect(requests.where((String u) => u == _konInfo), isEmpty);
    });

    test('日文原名（全角标点）也能命中：归一化后比较', () async {
      final AjattVideoSubtitleProvider provider = _provider(
        _server(requests: <String>[]),
      );
      final ProviderBatchResult<VideoSubtitleCandidate> result = await provider
          .search(
            VideoSubtitleSearchRequest(
              media: _media(title: '轻音少女', originalTitle: 'けいおん！'),
            ),
          );
      expect(result.hasFailures, isFalse, reason: '${result.failures}');
      expect(result.items, isNotEmpty);
    });

    test('带 AniList id：`.kitsuinfo.json` 相等才确认', () async {
      final List<String> requests = <String>[];
      final AjattVideoSubtitleProvider provider = _provider(
        _server(requests: requests, infoAnilistId: 5680),
      );
      final ProviderBatchResult<VideoSubtitleCandidate> result = await provider
          .search(VideoSubtitleSearchRequest(media: _media(anilistId: 5680)));
      expect(result.hasFailures, isFalse, reason: '${result.failures}');
      expect(result.items, hasLength(4));
      expect(requests.where((String u) => u == _konInfo), hasLength(1));
    });

    test('带 AniList id 且目录明确标了别的 id → 排除，0 候选但不是失败', () async {
      final AjattVideoSubtitleProvider provider = _provider(
        _server(requests: <String>[], infoAnilistId: 7777),
      );
      final ProviderBatchResult<VideoSubtitleCandidate> result = await provider
          .search(VideoSubtitleSearchRequest(media: _media(anilistId: 5680)));
      expect(result.hasFailures, isFalse);
      expect(result.items, isEmpty);
      expect(result.successfulProviderCount, 1);
    });

    test('带 AniList id 但目录没有 `.kitsuinfo.json` → 保留文本命中', () async {
      final AjattVideoSubtitleProvider provider = _provider(
        _server(requests: <String>[], infoMissing: true),
      );
      final ProviderBatchResult<VideoSubtitleCandidate> result = await provider
          .search(VideoSubtitleSearchRequest(media: _media(anilistId: 5680)));
      expect(result.hasFailures, isFalse);
      expect(result.items, hasLength(4));
    });

    test('指定集号：只留该集 + 认不出集号的文件', () async {
      final AjattVideoSubtitleProvider provider = _provider(
        _server(requests: <String>[]),
      );
      final ProviderBatchResult<VideoSubtitleCandidate> result = await provider
          .search(VideoSubtitleSearchRequest(query: 'K-ON!', episode: 2));
      expect(result.hasFailures, isFalse);
      expect(
        result.items.map((VideoSubtitleCandidate c) => c.episode),
        everyElement(anyOf(2, isNull)),
      );
      expect(result.items, isNotEmpty);
    });

    test('语言过滤：只要 en 时 ja 兜底的文件被滤掉', () async {
      final AjattVideoSubtitleProvider provider = _provider(
        _server(requests: <String>[]),
      );
      final ProviderBatchResult<VideoSubtitleCandidate> result = await provider
          .search(
            VideoSubtitleSearchRequest(
              query: 'K-ON!',
              languages: <String>['ko'],
            ),
          );
      expect(result.hasFailures, isFalse);
      expect(result.items, isEmpty);
    });

    test('真人剧分类不搜动画目录', () async {
      final AjattVideoSubtitleProvider provider = _provider(
        _server(requests: <String>[]),
      );
      final ProviderBatchResult<VideoSubtitleCandidate> result = await provider
          .search(
            VideoSubtitleSearchRequest(
              media: _media(category: VideoDiscoveryCategory.tv),
            ),
          );
      expect(result.hasFailures, isFalse);
      expect(result.items, isEmpty);
    });

    test('目录只抓一次：第二次搜索复用内存目录', () async {
      final List<String> requests = <String>[];
      final AjattVideoSubtitleProvider provider = _provider(
        _server(requests: requests),
      );
      await provider.search(VideoSubtitleSearchRequest(query: 'K-ON!'));
      await provider.search(VideoSubtitleSearchRequest(query: 'K-ON!'));
      expect(
        requests.where((String u) => u.endsWith('/index.html')),
        hasLength(1),
      );
      expect(
        requests.where((String u) => u.endsWith('/drama.html')),
        hasLength(1),
      );
    });

    test('目录页 HTTP 5xx → unavailable 且可重试', () async {
      final AjattVideoSubtitleProvider provider = _provider(
        _server(requests: <String>[], catalogStatus: 503),
      );
      final ProviderBatchResult<VideoSubtitleCandidate> result = await provider
          .search(VideoSubtitleSearchRequest(query: 'K-ON!'));
      expect(result.items, isEmpty);
      expect(result.failures, hasLength(1));
      expect(result.failures.single.providerId, 'ajatt');
      expect(
        result.failures.single.kind,
        ExternalProviderFailureKind.unavailable,
      );
      expect(result.failures.single.retryable, isTrue);
    });

    test('目录页结构对不上（站点改版）→ invalidResponse，不缓存空目录', () async {
      final AjattVideoSubtitleProvider provider = _provider(
        _server(
          requests: <String>[],
          catalogBody: '<html><body>redesigned</body></html>',
        ),
      );
      final ProviderBatchResult<VideoSubtitleCandidate> result = await provider
          .search(VideoSubtitleSearchRequest(query: 'K-ON!'));
      expect(result.failures, hasLength(1));
      expect(
        result.failures.single.kind,
        ExternalProviderFailureKind.invalidResponse,
      );
    });
  });

  group('AjattVideoSubtitleProvider.download', () {
    test('按候选的 raw URL 下载，文件名 / 语言原样带回', () async {
      final AjattVideoSubtitleProvider provider = _provider(
        _server(requests: <String>[]),
      );
      final ProviderBatchResult<VideoSubtitleCandidate> result = await provider
          .search(VideoSubtitleSearchRequest(query: 'K-ON!'));
      final VideoSubtitleDownload download = await provider.download(
        result.items.first,
      );
      expect(download.fileName, result.items.first.fileName);
      expect(download.language, 'ja');
      expect(utf8.decode(download.bytes), contains('けいおん'));
    });

    test('别家 provider 的候选 → unsupported', () async {
      final AjattVideoSubtitleProvider provider = _provider(
        _server(requests: <String>[]),
      );
      expect(
        () => provider.download(_ForeignCandidate()),
        throwsA(
          isA<ExternalProviderFailure>().having(
            (ExternalProviderFailure f) => f.kind,
            'kind',
            ExternalProviderFailureKind.unsupported,
          ),
        ),
      );
    });
  });

  group('rankAjattEntries', () {
    AjattCatalogEntry entry(
      String name, {
      String ja = '',
      String en = '',
      AjattEntryType type = AjattEntryType.animeTv,
      int mtime = 0,
    }) => AjattCatalogEntry(
      type: type,
      pagePath: '${type.wireName}/$name.html',
      name: name,
      englishName: en,
      japaneseName: ja,
      lastModifiedMs: mtime,
    );
    final List<AjattCatalogEntry> catalog = <AjattCatalogEntry>[
      entry('K-ON!', ja: 'けいおん!', mtime: 1),
      entry('K-ON!!', ja: 'けいおん!!', mtime: 2),
      entry(
        'K-ON! Movie',
        ja: 'けいおん! 映画',
        type: AjattEntryType.animeMovie,
        mtime: 3,
      ),
      entry('Kokoro', type: AjattEntryType.dramaTv, en: 'Heart', mtime: 4),
    ];

    test('有精确命中就只要精确命中：剧场版（子串命中）不带上；同档按修改时间降序', () {
      // 归一化会丢掉标点，「K-ON!」与「K-ON!!」同为 `kon`——文本层分不开它们是
      // 事实，分开靠 `.kitsuinfo.json` 的 AniList id（见 provider 测试）。
      final List<AjattCatalogEntry> ranked = rankAjattEntries(
        catalog,
        queries: <String>['K-ON!'],
      );
      expect(ranked.map((AjattCatalogEntry e) => e.name), <String>[
        'K-ON!!',
        'K-ON!',
      ]);
    });

    test('没有精确命中退回子串命中，按最后修改时间降序、受 limit 约束', () {
      final List<AjattCatalogEntry> withMore = <AjattCatalogEntry>[
        ...catalog,
        entry('Kokoro Connect', mtime: 5),
        entry('Kokoro Toshokan', mtime: 6),
      ];
      final List<AjattCatalogEntry> ranked = rankAjattEntries(
        withMore,
        queries: <String>['Kokoro'],
        category: VideoDiscoveryCategory.anime,
        limit: 1,
      );
      // 精确命中的「Kokoro」是真人剧，被分类过滤掉；退回子串命中取最新的一部。
      expect(ranked.map((AjattCatalogEntry e) => e.name), <String>[
        'Kokoro Toshokan',
      ]);
    });

    test('分类过滤：真人剧只看 drama_*（含 unsorted）', () {
      expect(
        rankAjattEntries(
          catalog,
          queries: <String>['Heart'],
          category: VideoDiscoveryCategory.tv,
        ).single.name,
        'Kokoro',
      );
      expect(
        rankAjattEntries(
          catalog,
          queries: <String>['Heart'],
          category: VideoDiscoveryCategory.anime,
        ),
        isEmpty,
      );
    });

    test('查询里的季/篇名尾巴也能反向包含到短目录名，但极短目录名不参与', () {
      final List<AjattCatalogEntry> withShort = <AjattCatalogEntry>[
        ...catalog,
        entry('K'),
      ];
      final List<AjattCatalogEntry> ranked = rankAjattEntries(
        withShort,
        queries: <String>['K-ON!! Season 2 Extra'],
      );
      expect(ranked.map((AjattCatalogEntry e) => e.name), isNot(contains('K')));
      expect(ranked.map((AjattCatalogEntry e) => e.name), contains('K-ON!!'));
    });

    test('空查询 → 空', () {
      expect(rankAjattEntries(catalog, queries: <String>['  ']), isEmpty);
    });
  });
}

class _ForeignCandidate extends VideoSubtitleCandidate {
  _ForeignCandidate()
    : super(
        providerId: 'jimaku',
        remoteId: '1:x.srt',
        fileName: 'x.srt',
        language: 'ja',
        providerPriority: 100,
      );
}
