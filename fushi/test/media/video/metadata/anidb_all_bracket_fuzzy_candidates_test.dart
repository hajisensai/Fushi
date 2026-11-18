import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/media/video/metadata/anidb_title_catalog.dart';
import 'package:fushi_engine/media/video/metadata/anidb_video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_resolver.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_coordinator.dart';
import 'package:fushi_engine/media/video/video_filename_parser.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

/// BUG-4894：`[K-ON!][04][BIG5][x264_aac][BDrip_720P]` 的待确认列表里出现
/// 「この音とまれ!」「この世界の片隅に」「結婚指輪物語II」。
///
/// 两层根因：① 解析器把块外无字的首块 `[K-ON!]` 当发布组，标题为空、集号丢失，
/// 上层只剩整串原名可搜；② 原名在 AniDB 目录里精确 / 前缀都落空，退到 3-gram
/// 模糊召回（下限 0.2），只共享 `kon` 音节的作品（0.28～0.33）原样进了待确认。
void main() {
  const String fileName = '[K-ON!][04][BIG5][x264_aac][BDrip_720P].mp4';
  const String videoPath = '/storage/emulated/0/Download/$fileName';

  test('all-bracket name parses the first block as title, not group', () {
    final VideoNameInfo parsed = parseVideoFilename(fileName);
    expect(parsed.series, 'K-ON!');
    expect(parsed.episode, 4);
    expect(
      videoScrapeTitleCandidates(
        workTitle: '[K-ON!][04][BIG5][x264_aac][BDrip_720P]',
        parsedSeries: parsed.series,
        videoPath: videoPath,
      ).first,
      'K-ON!',
    );
  });

  test(
    'weak fuzzy AniDB catalog hits never become confirmation candidates',
    () async {
      final Directory directory = await Directory.systemTemp.createTemp(
        'fushi-anidb-bug4714-',
      );
      final AniDbTitleCatalog catalog = AniDbTitleCatalog(
        cacheDirectory: directory,
        client: MockClient(
          (http.Request request) async =>
              http.Response.bytes(gzip.encode(utf8.encode(_catalogXml)), 200),
        ),
      );
      final AniDbVideoMetadataProvider provider = AniDbVideoMetadataProvider(
        clientName: '',
        clientVersion: null,
        language: 'ja',
        titleCatalog: catalog,
        client: MockClient((http.Request request) async {
          throw StateError('HTTP API must not be called without an identity');
        }),
      );
      addTearDown(() async {
        provider.close();
        catalog.close();
        await directory.delete(recursive: true);
      });

      // 搜索面保留模糊命中（手动搜索要用），但带上「弱」证据。
      final List<VideoMetadataWork> raw = await provider.search(
        const VideoMetadataSearchRequest(
          title: '[K-ON!][04][BIG5][x264_aac][BDrip_720P]',
          mediaKind: VideoMetadataMediaKind.tv,
        ),
      );
      expect(raw, isNotEmpty);
      expect(raw.every(AniDbVideoMetadataProvider.isWeakCatalogMatch), isTrue);

      final VideoNameInfo parsed = parseVideoFilename(fileName);
      final VideoMetadataResolution result =
          await VideoMetadataResolver(
            registry: VideoMetadataProviderRegistry(<VideoMetadataProvider>[
              provider,
            ]),
          ).resolve(
            VideoMetadataResolveRequest(
              selectedProvider: VideoMetadataProviderKind.anidb,
              mediaKind: VideoMetadataMediaKind.tv,
              titleCandidates: videoScrapeTitleCandidates(
                workTitle: '[K-ON!][04][BIG5][x264_aac][BDrip_720P]',
                parsedSeries: parsed.series,
                videoPath: videoPath,
              ),
            ),
          );

      final Set<String> ids = <String>{
        for (final VideoMetadataWork work in result.candidates)
          for (final VideoMetadataId id in work.ids)
            if (id.type == 'anidb') id.value,
        for (final VideoMetadataId id
            in result.work?.ids ?? const <VideoMetadataId>[])
          if (id.type == 'anidb') id.value,
      };
      expect(ids, containsAll(<String>['6257', '7307']));
      expect(ids.intersection(<String>{'14553', '9376', '18559'}), isEmpty);
      // 目录摘要标题对不上的候选只是「可能」，不能让确认框说成严格匹配。
      expect(result.strictMatches, isFalse);
    },
  );
}

const String _catalogXml = '''
<?xml version="1.0" encoding="UTF-8"?>
<animetitles>
  <anime aid="6257">
    <title type="syn" xml:lang="x-jat">K-ON</title>
    <title type="official" xml:lang="en">K-On!</title>
    <title type="official" xml:lang="ja">けいおん!</title>
  </anime>
  <anime aid="7307">
    <title type="main" xml:lang="x-jat">K-On!!</title>
    <title type="official" xml:lang="ja">けいおん!!</title>
  </anime>
  <anime aid="8280">
    <title type="main" xml:lang="x-jat">Eiga K-On!</title>
    <title type="official" xml:lang="ja">映画 けいおん!</title>
    <title type="syn" xml:lang="pl">K-On! Film kinowy</title>
  </anime>
  <anime aid="14553">
    <title type="main" xml:lang="x-jat">Kono Oto Tomare! (2019)</title>
    <title type="syn" xml:lang="x-jat">Kono Oto Tomare! Part 2</title>
    <title type="official" xml:lang="ja">この音とまれ! (2019)</title>
  </anime>
  <anime aid="9376">
    <title type="main" xml:lang="x-jat">Kono Sekai no Katasumi ni</title>
    <title type="official" xml:lang="ja">この世界の片隅に</title>
  </anime>
  <anime aid="18559">
    <title type="main" xml:lang="x-jat">Kekkon Yubiwa Monogatari II</title>
    <title type="official" xml:lang="ja">結婚指輪物語II</title>
  </anime>
</animetitles>
''';
