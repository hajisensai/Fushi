import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/external_provider.dart';
import 'package:fushi/src/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi/src/media/video/download/video_subtitle_registry.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_models.dart';
import 'package:fushi/src/media/video/subtitle/video_subtitle_provider.dart';

/// 只记录「有没有被叫到、以什么顺序」的假 provider。
class _RecordingProvider implements VideoSubtitleProvider {
  _RecordingProvider(this.id, this.priority, this.log);

  @override
  final String id;

  @override
  final int priority;

  final List<String> log;

  @override
  Future<ProviderBatchResult<VideoSubtitleCandidate>> search(
    VideoSubtitleSearchRequest request,
  ) async {
    log.add(id);
    return ProviderBatchResult<VideoSubtitleCandidate>.success(
      <VideoSubtitleCandidate>[
        _FakeCandidate(providerId: id, providerPriority: priority),
      ],
    );
  }

  @override
  Future<VideoSubtitleDownload> download(
      VideoSubtitleCandidate candidate) async {
    log.add('download:$id');
    return VideoSubtitleDownload(
      bytes: Uint8List.fromList(<int>[1]),
      fileName: '$id.srt',
      language: 'ja',
    );
  }

  @override
  void close() {}
}

class _FakeCandidate extends VideoSubtitleCandidate {
  _FakeCandidate({required String providerId, required int providerPriority})
      : super(
          providerId: providerId,
          remoteId: 'r',
          fileName: '$providerId.srt',
          language: 'ja',
          providerPriority: providerPriority,
        );
}

VideoMediaReference _reference(VideoDiscoveryCategory category) =>
    VideoMediaReference(
      providerId: 'tmdb',
      mediaId: '1',
      mediaKind: VideoMetadataMediaKind.tv,
      discoveryCategory: category,
      title: '最愛',
    );

void main() {
  group('VideoSubtitleRegistry provider 路由', () {
    test('非动漫检索也要问 Jimaku（真人剧字幕接入）', () async {
      final List<String> log = <String>[];
      final VideoSubtitleRegistry registry = VideoSubtitleRegistry(
        <VideoSubtitleProvider>[
          _RecordingProvider('jimaku', 100, log),
          _RecordingProvider('opensubtitles', 200, log),
        ],
      );

      await registry.search(
        VideoSubtitleSearchRequest(
          media: _reference(VideoDiscoveryCategory.tv),
          query: '最愛',
        ),
      );

      // 旧实现在这里只放行 opensubtitles，Jimaku 的真人剧库整片不可见。
      expect(log, containsAll(<String>['jimaku', 'opensubtitles']));
    });

    test('动漫检索合并两家结果，顺序由 provider 优先级决定', () async {
      final List<String> log = <String>[];
      // 用默认优先级：Jimaku 100 先于 OpenSubtitles 200。候选的最终顺序只由
      // providerPriority 决定（deduplicateVideoSubtitles），与 fan-out 的启动
      // 顺序无关，故此处断言结果而不是调用次序。
      final VideoSubtitleRegistry registry = VideoSubtitleRegistry(
        <VideoSubtitleProvider>[
          _RecordingProvider('opensubtitles', 200, log),
          _RecordingProvider('jimaku', 100, log),
        ],
      );

      final ProviderBatchResult<VideoSubtitleCandidate> result =
          await registry.search(
        VideoSubtitleSearchRequest(
          media: _reference(VideoDiscoveryCategory.anime),
          query: 'frieren',
        ),
      );

      expect(log, containsAll(<String>['jimaku', 'opensubtitles']));
      expect(
        result.items.map((VideoSubtitleCandidate c) => c.providerId).toList(),
        <String>['jimaku', 'opensubtitles'],
      );
    });

    test('无媒体引用时全部 provider 参与', () async {
      final List<String> log = <String>[];
      final VideoSubtitleRegistry registry = VideoSubtitleRegistry(
        <VideoSubtitleProvider>[
          _RecordingProvider('jimaku', 100, log),
          _RecordingProvider('opensubtitles', 200, log),
        ],
      );

      await registry.search(VideoSubtitleSearchRequest(query: '半沢直樹'));

      expect(log, containsAll(<String>['jimaku', 'opensubtitles']));
    });

    test('download 按候选的 providerId 回到原 provider', () async {
      final List<String> log = <String>[];
      final VideoSubtitleRegistry registry = VideoSubtitleRegistry(
        <VideoSubtitleProvider>[
          _RecordingProvider('jimaku', 100, log),
          _RecordingProvider('opensubtitles', 200, log),
        ],
      );

      final VideoSubtitleDownload download = await registry.download(
        _FakeCandidate(providerId: 'opensubtitles', providerPriority: 200),
      );

      expect(download.fileName, 'opensubtitles.srt');
      expect(log, <String>['download:opensubtitles']);
    });
  });
}
