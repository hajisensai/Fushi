import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/video/metadata/anidb_title_catalog.dart';
import 'package:fushi_engine/media/video/metadata/tmdb_episode_matcher.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/scraper/title_normalizer.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/anidb_parity_inputs.dart';

/// 标题归一化 / 相似度、AniDB 标题目录（解析 + 搜索）、TMDB 分集匹配搬进 Rust
/// （native/fushi_compute）后的逐位对拍：下面的摘要由**搬迁前的 Dart 实现**对
/// support/anidb_parity_inputs.dart 的确定性输入算出并冻结。任何一项变了都说明原生实现与
/// 原 Dart 语义不再一致（或输入生成器被改了）——不要改常量，去查哪一步不一致。
///
/// 覆盖：3000 部合成目录的全部记录（含 normalizedValue）、370 条查询的完整排序结果
/// （animeId / 标题 / 类型 / 种类 / 相似度位模式）、3255 对标题的 normalize / tokens /
/// similarity / similarityNormalized、300 个分集匹配场景（正片 + 特典）。
/// 真实 AniDB 每日标题包（17063 部 / 101889 个标题、679 条查询）与 1500 个分集匹配场景的
/// 全量对拍在迁移时离线做过，结果完全一致（大文件不入库）。
void main() {
  late Directory root;

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('fushi-anidb-parity-');
  });

  tearDownAll(() => root.delete(recursive: true));

  Future<AniDbTitleCatalog> openCached(String xml) async {
    final Directory dir = await root.createTemp('cache-');
    final File file = File('${dir.path}/${AniDbTitleCatalog.cacheFileName}');
    await file.writeAsBytes(gzip.encode(utf8.encode(xml)));
    final DateTime now = DateTime.now();
    await file.setLastModified(now);
    await File(
      '${dir.path}/${AniDbTitleCatalog.refreshMarkerFileName}',
    ).writeAsString('');
    return AniDbTitleCatalog(
      cacheDirectory: dir,
      client: MockClient((_) async => http.Response('offline', 500)),
      now: () => now.add(const Duration(minutes: 1)),
    );
  }

  String matchScenario(MatcherScenario s) {
    List<TmdbEpisodeMatchSource> sources(
      List<(int, List<String>, String?)> l,
    ) => <TmdbEpisodeMatchSource>[
      for (final (int n, List<String> t, String? d) in l)
        TmdbEpisodeMatchSource(number: n, titles: t, airDate: d),
    ];
    final List<VideoMetadataEpisode> episodes = <VideoMetadataEpisode>[
      for (final (int season, int ep, String title, String? air) in s.episodes)
        VideoMetadataEpisode(
          seasonNumber: season,
          episodeNumber: ep,
          title: title,
          airDate: air,
        ),
    ];
    String ser(Map<int, TmdbEpisodeMatch> m) => <String>[
      for (final MapEntry<int, TmdbEpisodeMatch> e in m.entries)
        '${e.key}>${e.value.episode.seasonNumber}x'
            '${e.value.episode.episodeNumber}:${e.value.rating.index}',
    ].join(',');
    return '${ser(matchEpisodesToTmdb(sources(s.sources), episodes, candidateAliases: s.aliases))}'
        '|${ser(matchSpecialsToTmdb(sources(s.specials), episodes, candidateAliases: s.aliases))}';
  }

  test('outputs match the frozen pre-migration Dart implementation', () async {
    final Map<String, String> digests = await parityDigests(
      normalize: TitleNormalizer.normalize,
      tokens: TitleNormalizer.tokens,
      similarity: TitleNormalizer.similarity,
      similarityNormalized: TitleNormalizer.similarityNormalized,
      openCatalog: openCached,
      matchScenario: matchScenario,
    );
    expect(digests, <String, String>{
      'records': '3000:4fc9973a3be6cf11',
      'search': '370/3477:-178fb6078643a94d',
      'text': '3255:60d53dff9b1f499a',
      'matcher': '300:-51f5af6e81dfea94',
    });
  }, timeout: const Timeout(Duration(minutes: 5)));
}
