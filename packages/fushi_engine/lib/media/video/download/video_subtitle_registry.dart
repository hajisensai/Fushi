import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/subtitle/video_subtitle_provider.dart';

class VideoSubtitleRegistry {
  VideoSubtitleRegistry(Iterable<VideoSubtitleProvider> providers)
      : providers = List<VideoSubtitleProvider>.unmodifiable(providers);

  final List<VideoSubtitleProvider> providers;

  Future<ProviderBatchResult<VideoSubtitleCandidate>> search(
    VideoSubtitleSearchRequest request,
  ) async {
    final bool anime =
        request.media?.discoveryCategory == VideoDiscoveryCategory.anime;
    // 此前非动画只放 OpenSubtitles，理由大概是「Jimaku 是番剧字幕站」。这不成立：
    // Jimaku 上有数千条真人日剧/日影条目，而它们恰恰是本 app（日语沉浸）最需要
    // 日语字幕、OpenSubtitles 又最缺日语轨的一类。真正把真人剧挡死的是
    // JimakuAnimeFilter（BUG-1694），那个修好之后这道分类门就只剩「少搜一家」的
    // 净损失。动画仍旧 Jimaku 优先，排序不变。
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

  /// 一次搜索**一条候选都没拿到**时，逐来源说明各自怎么了，如
  /// `jimaku: no match; opensubtitles: provider request timed out`。
  ///
  /// 不能只报 `failures.first`：正常应答但零命中的来源不进 failures，于是「Jimaku
  /// 没搜到这部作品」会被另一家的超时盖住，用户看到「超时」去查网络，真正该查的
  /// 身份问题无人知晓（BUG-3892）。
  String describeEmptySearch(
    ProviderBatchResult<VideoSubtitleCandidate> result,
  ) {
    final Map<String, String> failed = <String, String>{};
    for (final ExternalProviderFailure failure in result.failures) {
      failed.putIfAbsent(failure.providerId, () => failure.message);
    }
    return <String>[
      for (final VideoSubtitleProvider provider in providers)
        '${provider.id}: ${failed.remove(provider.id) ?? 'no match'}',
      // 不属于任何已登记来源的失败（理论上没有）也要说出来，不吞。
      for (final MapEntry<String, String> rest in failed.entries)
        '${rest.key}: ${rest.value}',
    ].join('; ');
  }

  /// 这条候选的来源 provider 是否允许为「正文语言探测」白下载一次。
  ///
  /// 判据必须落在 **provider 有没有下载配额** 上（见
  /// [VideoSubtitleProvider.allowsFreeProbeDownload]），不能用「候选的 language
  /// 字段是不是空的」代替——后者与配额毫无关系，而 OpenSubtitles 恰恰经常不给
  /// language，于是最该被保护的源反而最常被探测。未知 provider 一律不许。
  bool allowsFreeProbeDownload(VideoSubtitleCandidate candidate) {
    for (final VideoSubtitleProvider value in providers) {
      if (value.id == candidate.providerId) {
        return value.allowsFreeProbeDownload;
      }
    }
    return false;
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
