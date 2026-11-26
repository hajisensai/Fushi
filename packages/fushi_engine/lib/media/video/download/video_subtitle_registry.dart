import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_engine/foundation/engine_log.dart';
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
          applicable.map((VideoSubtitleProvider provider) async {
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
          }),
        );
    final ProviderBatchResult<VideoSubtitleCandidate> merged =
        ProviderBatchResult.merge(results);
    // 各来源的失败到这里都已归一成返回值、不再抛出，界面只挑一条拼成「搜索失败
    // （HTTP 400）」，连是哪一家都不说。这里是所有入口（字幕面板、下载管线、遥控）
    // 共用的汇合点，逐条留诊断：来源、操作、状态码都在 [ExternalProviderFailure]
    // 的 toString 里（BUG-5455：一次 OpenSubtitles 400 被当成 Jimaku 的问题报上来，
    // 日志里一行线索都没有）。
    for (final ExternalProviderFailure failure in merged.failures) {
      engineLog.logDiagnostic('VideoSubtitleRegistry.search', failure);
    }
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
  /// 身份问题无人知晓（BUG-3926）。
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

  /// 并行预热所有支持预热的来源连接（见 [VideoSubtitleConnectionWarmup]）。
  Future<void> warmUpConnections() => Future.wait(<Future<void>>[
    for (final VideoSubtitleProvider provider in providers)
      if (provider is VideoSubtitleConnectionWarmup)
        (provider as VideoSubtitleConnectionWarmup).warmUpConnection(),
  ]);

  Future<VideoSubtitleDownload> download(VideoSubtitleCandidate candidate) {
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

/// 把 64 位 movie hash 按**无符号**拼成 OpenSubtitles 要求的 16 位小写十六进制。
///
/// 不能直接 `hash.toRadixString(16)`：Dart 的 int 有符号，最高位为 1（约一半的
/// 视频文件）时会拼出 `-1a2b…` 这种带负号的串，OpenSubtitles 对它回
/// `400 moviehash must be 16 hex characters`，而 hash 档失败会让整次 OpenSubtitles
/// 搜索作废（BUG-5455）。高低 32 位分开拼，与平台的 int 表示无关。
String formatOpenSubtitlesMovieHash(int hash) {
  final String high = ((hash >> 32) & 0xffffffff).toRadixString(16);
  final String low = (hash & 0xffffffff).toRadixString(16);
  return '${high.padLeft(8, '0')}${low.padLeft(8, '0')}';
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
    // Dart 的 int 是有符号 64 位：累加按二进制补码自然回绕，结果与无符号 uint64
    // 逐位相同，但最高位为 1 时数值是负的。
    int hash = length;
    for (final Uint8List chunk in <Uint8List>[first, last]) {
      final ByteData bytes = ByteData.sublistView(chunk);
      for (int offset = 0; offset + 8 <= chunk.length; offset += 8) {
        hash += bytes.getUint64(offset, Endian.little);
      }
    }
    return formatOpenSubtitlesMovieHash(hash);
  } finally {
    await handle.close();
  }
}
