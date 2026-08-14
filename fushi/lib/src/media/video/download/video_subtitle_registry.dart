import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi/src/media/external_provider.dart';
import 'package:fushi/src/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi/src/media/video/subtitle/video_subtitle_provider.dart';

class VideoSubtitleRegistry {
  VideoSubtitleRegistry(Iterable<VideoSubtitleProvider> providers)
      : providers = List<VideoSubtitleProvider>.unmodifiable(providers);

  final List<VideoSubtitleProvider> providers;

  Future<ProviderBatchResult<VideoSubtitleCandidate>> search(
    VideoSubtitleSearchRequest request,
  ) async {
    final bool anime =
        request.media?.discoveryCategory == VideoDiscoveryCategory.anime;
    // 每个 provider 自己决定能否服务这次检索（Jimaku 会按分类切 anime/live-action
    // 范围），注册表不再用 id 白名单替它们做可用性判断——那行白名单曾把 Jimaku 的整个
    // 真人剧库挡在非动漫检索之外。排序仍保留「动漫优先 Jimaku」的既有意图。
    final List<VideoSubtitleProvider> applicable = providers.toList()
      ..sort((VideoSubtitleProvider a, VideoSubtitleProvider b) {
        if (anime && a.id != b.id) {
          if (a.id == 'jimaku') return -1;
          if (b.id == 'jimaku') return 1;
        }
        return a.priority.compareTo(b.priority);
      });
    final List<ProviderBatchResult<VideoSubtitleCandidate>> results =
        await Future.wait(
      applicable.map(
        (VideoSubtitleProvider provider) async {
          try {
            return await provider.search(request);
          } on Object catch (error) {
            return ProviderBatchResult<VideoSubtitleCandidate>.failure(
              ExternalProviderFailure.fromException(
                providerId: provider.id,
                operation: 'search',
                error: error,
              ),
            );
          }
        },
      ),
    );
    final ProviderBatchResult<VideoSubtitleCandidate> merged =
        ProviderBatchResult.merge(results);
    return ProviderBatchResult<VideoSubtitleCandidate>(
      items: deduplicateVideoSubtitles(merged.items),
      failures: merged.failures,
      successfulProviderCount: merged.successfulProviderCount,
    );
  }

  Future<VideoSubtitleDownload> download(
    VideoSubtitleCandidate candidate,
  ) {
    VideoSubtitleProvider? provider;
    for (final VideoSubtitleProvider value in providers) {
      if (value.id == candidate.providerId) {
        provider = value;
        break;
      }
    }
    if (provider == null) {
      throw ExternalProviderFailure(
        providerId: candidate.providerId,
        operation: 'download',
        kind: ExternalProviderFailureKind.unsupported,
        message: 'subtitle provider is no longer configured',
      );
    }
    return provider.download(candidate);
  }

  void close() {
    for (final VideoSubtitleProvider provider in providers) {
      provider.close();
    }
  }
}

/// OpenSubtitles 64-bit movie hash：文件大小 + 首尾各 64 KiB 的 little-endian
/// uint64 累加。小于 128 KiB 的文件不发送 hash，自动回退到外部 id / 标题。
Future<String?> computeOpenSubtitlesMovieHash(String path) async {
  final File file = File(path);
  final int length = await file.length();
  const int chunkSize = 64 * 1024;
  if (length < chunkSize * 2) return null;
  final RandomAccessFile handle = await file.open();
  try {
    final Uint8List first = await handle.read(chunkSize);
    await handle.setPosition(length - chunkSize);
    final Uint8List last = await handle.read(chunkSize);
    const int mask = 0xffffffffffffffff;
    int hash = length & mask;
    for (final Uint8List chunk in <Uint8List>[first, last]) {
      final ByteData bytes = ByteData.sublistView(chunk);
      for (int offset = 0; offset + 8 <= chunk.length; offset += 8) {
        hash = (hash + bytes.getUint64(offset, Endian.little)) & mask;
      }
    }
    return hash.toRadixString(16).padLeft(16, '0');
  } finally {
    await handle.close();
  }
}
