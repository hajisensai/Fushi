/// 音乐资料源契约（音乐方案 §8.1）：照视频 `VideoMetadataProvider` 的形态——一个最小公共
/// 接口（种类 / 可用性 / 关闭）+ 按能力拆开的子接口，识别器只依赖能力，不依赖具体实现。
///
/// provider 边界（`docs/agent/anime-scraping.md`）：音乐刮削只装配 MusicBrainz（主源）、
/// AcoustID、Cover Art Archive、VGMdb；**不新增并行动画资料源**——动画出处只复用视频库里
/// 已有的 AniDB / MAL / TMDB 身份（经作品图谱 `media_links` 的主题曲连接）。
library;

import 'dart:async';

import 'package:fushi_engine/media/music/metadata/music_metadata_models.dart';
import 'package:fushi_engine/media/music/metadata/music_release_match.dart';

abstract interface class MusicMetadataProvider {
  MusicMetadataProviderKind get providerKind;

  /// 配置是否足以实际访问该来源。不可用的 provider 必须在发网络请求前返回 false，
  /// 识别器据此跳过（AcoustID 没填 key、VGMdb 被关掉）。
  bool get isAvailable;

  /// [isAvailable] 为 false 时给用户看的原因（设置页说明同一句）。
  String? get unavailableReason;

  void close();
}

/// 录音检索 / 详情（MusicBrainz）。
abstract interface class MusicRecordingProvider
    implements MusicMetadataProvider {
  /// 标签精确查：按 [query] 搜录音，返回原始顺序的候选（打分在识别器里做）。
  Future<List<MusicRecording>> searchRecordings(
    MusicRecordingSearchQuery query,
  );

  /// 录音详情（含发行、作品关系、MV 关系、URL 关系）。不存在返回 null。
  Future<MusicRecording?> fetchRecording(String mbRecordingId);

  /// 作品及其全部录音（原曲 / 其它版本）。不存在返回 null。
  Future<MusicWork?> fetchWork(String mbWorkId);
}

/// 整张发行的曲目表（MusicBrainz）：光盘专辑按曲目表对号（音乐方案 §9.2）。
abstract interface class MusicReleaseProvider implements MusicMetadataProvider {
  /// 按标题（可带艺人）搜 DVD-Video / Blu-ray 发行，返回带曲目表的候选（已逐张取详情，
  /// 至多 [limit] 张——MusicBrainz 搜索结果不含曲目表，每张详情各算一次请求）。
  Future<List<MusicReleaseTracklist>> searchDiscReleases(
    String title, {
    String? artist,
    int limit = 5,
  });

  /// 发行详情（含全部 medium 与曲目）。不存在返回 null。
  Future<MusicReleaseTracklist?> fetchReleaseTracklist(String mbReleaseId);

  /// 音频 CD：按 MusicBrainz Disc ID（可带 TOC 做模糊查）找发行。查不到返回空表。
  Future<List<MusicReleaseTracklist>> lookupDiscId(
    String discId, {
    String? toc,
  });
}

/// 声纹查询（AcoustID）。
abstract interface class MusicFingerprintProvider
    implements MusicMetadataProvider {
  /// [fingerprint] 是 chromaprint 压缩串（`fpcalc` 同形），[durationSec] 是整首时长（秒）。
  Future<List<AcoustidResult>> lookup({
    required String fingerprint,
    required int durationSec,
  });
}

/// 发行封面（Cover Art Archive）。
abstract interface class MusicCoverProvider implements MusicMetadataProvider {
  /// 一张发行的全部图（没有返回空表）。
  Future<List<MusicCoverImage>> fetchReleaseCovers(String mbReleaseId);

  /// 下载一张图的字节（[url] 来自 [fetchReleaseCovers]）。
  Future<List<int>> download(String url);
}

/// 动画 / 游戏唱片补充（VGMdb）。
abstract interface class MusicAlbumCatalogProvider
    implements MusicMetadataProvider {
  /// 按目录编号（Catalog No.）查唯一专辑；查不到 / 多个返回 null。
  Future<VgmdbAlbum?> findAlbumByCatalog(String catalog);
}

/// provider 未配置 / 被关掉时调用了它（编程错误：识别器应先看 [MusicMetadataProvider.isAvailable]）。
class MusicMetadataProviderUnavailable implements Exception {
  const MusicMetadataProviderUnavailable(this.provider, this.reason);

  final MusicMetadataProviderKind provider;
  final String reason;

  @override
  String toString() =>
      'MusicMetadataProviderUnavailable(${provider.wire}): $reason';
}

typedef MusicThrottleClock = DateTime Function();
typedef MusicThrottleSleep = Future<void> Function(Duration duration);

/// 按来源的请求节流：同一个闸门上的请求**串行**，相邻两次请求的发起时刻至少隔
/// [minInterval]。MusicBrainz 要求每 IP 平均不超过 1 req/s（与 AniDB 同等纪律），
/// AcoustID 3 req/s，VGMdb 社区镜像没有公开额度、按保守值。
///
/// 不是重试：闸门只排队，不会把失败的请求再发一遍（有界重试在传输层）。
class MusicRequestThrottle {
  MusicRequestThrottle(
    this.minInterval, {
    MusicThrottleClock? now,
    MusicThrottleSleep? sleep,
  }) : _now = now ?? DateTime.now,
       _sleep = sleep ?? Future<void>.delayed;

  final Duration minInterval;
  final MusicThrottleClock _now;
  final MusicThrottleSleep _sleep;
  DateTime? _last;
  Future<void> _tail = Future<void>.value();

  /// 进程内共享的 MusicBrainz 闸门（musicbrainz.org，含 coverartarchive.org 的 JSON 索引）。
  static final MusicRequestThrottle musicBrainz = MusicRequestThrottle(
    const Duration(milliseconds: 1100),
  );

  /// AcoustID（api.acoustid.org，官方额度 3 req/s）。
  static final MusicRequestThrottle acoustid = MusicRequestThrottle(
    const Duration(milliseconds: 350),
  );

  /// VGMdb 社区镜像：保守 1 次 / 3 s。
  static final MusicRequestThrottle vgmdb = MusicRequestThrottle(
    const Duration(seconds: 3),
  );

  /// 在闸门里执行 [body]（排在之前的请求之后，并与上一次发起隔开 [minInterval]）。
  Future<T> run<T>(Future<T> Function() body) {
    final Completer<T> done = Completer<T>();
    _tail = _tail.then((_) async {
      final DateTime? last = _last;
      if (last != null) {
        final Duration wait = minInterval - _now().difference(last);
        if (wait > Duration.zero) await _sleep(wait);
      }
      _last = _now();
      try {
        done.complete(await body());
      } catch (e, st) {
        done.completeError(e, st);
      }
    });
    return done.future;
  }
}
