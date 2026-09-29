import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/subtitle/video_subtitle_backfill.dart';
import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/download/video_subtitle_registry.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/subtitle/video_subtitle_provider.dart';
import 'package:path/path.dart' as p;

/// 补字幕服务的「按作品显式语言」契约：目标带 [SubtitleBackfillTarget.explicitLanguage]
/// 时它压过全局 `preferredLanguages` 进搜索请求的硬过滤；不带时照旧用全局。
void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fushi-backfill-language-');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<SubtitleBackfillTarget> target({String? explicitLanguage}) async {
    final File video = File(p.join(root.path, 'Show - S01E01.mkv'));
    await video.writeAsBytes(<int>[0, 1, 2, 3], flush: true);
    return SubtitleBackfillTarget(
      bookUid: 'book-1',
      videoPath: video.path,
      media: VideoMediaReference(
        providerId: 'anilist',
        mediaId: '100',
        mediaKind: VideoMetadataMediaKind.tv,
        discoveryCategory: VideoDiscoveryCategory.anime,
        title: 'Show',
        season: 1,
        episode: 1,
      ),
      explicitLanguage: explicitLanguage,
    );
  }

  test('explicit language replaces the global filter', () async {
    final _RecordingSubtitleProvider provider = _RecordingSubtitleProvider();
    final VideoSubtitleBackfillService service = VideoSubtitleBackfillService(
      registry: VideoSubtitleRegistry(<VideoSubtitleProvider>[provider]),
      preferredLanguages: const <String>['ja'],
    );
    await service.backfill(await target(explicitLanguage: 'zh'));
    expect(provider.lastRequest!.languages, <String>['zh']);
  });

  test('without an explicit language the global filter applies', () async {
    final _RecordingSubtitleProvider provider = _RecordingSubtitleProvider();
    final VideoSubtitleBackfillService service = VideoSubtitleBackfillService(
      registry: VideoSubtitleRegistry(<VideoSubtitleProvider>[provider]),
      preferredLanguages: const <String>['ja'],
    );
    await service.backfill(await target());
    expect(provider.lastRequest!.languages, <String>['ja']);
  });
}

class _RecordingSubtitleProvider implements VideoSubtitleProvider {
  VideoSubtitleSearchRequest? lastRequest;

  @override
  bool get allowsFreeProbeDownload => false;

  @override
  String get id => 'recording';

  @override
  int get priority => 0;

  @override
  Future<ProviderBatchResult<VideoSubtitleCandidate>> search(
    VideoSubtitleSearchRequest request,
  ) async {
    lastRequest = request;
    // 空结果：本测试只钉请求形状，不走下载 / 时长校验。
    return ProviderBatchResult<VideoSubtitleCandidate>.success(
      const <VideoSubtitleCandidate>[],
    );
  }

  @override
  Future<VideoSubtitleDownload> download(VideoSubtitleCandidate candidate) {
    throw UnimplementedError();
  }

  @override
  void close() {}
}
