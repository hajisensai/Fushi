import 'dart:async';
import 'dart:io';

import 'package:hibiki/src/media/video/video_storage.dart';
import 'package:hibiki/src/utils/misc/desktop_audio_clipper.dart'
    show extractVideoFrameViaFfmpeg;
import 'package:path/path.dart' as p;

/// 剧集面板一集的缩略图描述（Netflix/Jellyfin 式带封面剧集列表，TODO 视频封面剧集列表）。
///
/// 数据来源分两类（见 `video_hibiki_page._PlaylistEpisodeRef`）：
/// - **本地成员集**：每集是独立 `VideoBooks` 行，导入时已抽帧落 [coverPath]（DB `coverPath`）。
///   直接 `Image.file` 显示，文件缺失时才退回懒抽帧 / 占位。
/// - **远端集**：无本地封面、无可抽帧的本地文件（[coverPath] / [videoPath] 均空），
///   面板回退到纯序号占位。
class VideoEpisodeEntry {
  const VideoEpisodeEntry({
    required this.title,
    this.coverPath,
    this.videoPath,
    this.thumbnailKey,
  });

  /// 剧集标题（面板右侧显示）。
  final String title;

  /// DB 已有封面绝对路径（本地成员集导入抽帧）；空 / 文件缺失时回退懒抽帧或占位。
  final String? coverPath;

  /// 本地视频文件绝对路径（懒抽帧输入）；远端集为空，不抽帧。
  final String? videoPath;

  /// 懒抽帧缓存去重的稳定 key（bookUid，或 playlist 内部集的 path）；空则不做懒抽帧。
  final String? thumbnailKey;
}

/// 缩略图解析器接口：把一集 [VideoEpisodeEntry] 解析成一个可显示的封面文件绝对路径，
/// 或 null（无封面可用 → 面板显示占位）。抽象出接口便于面板 widget 测试注入替身，
/// 不真跑 ffmpeg。
abstract class EpisodeThumbnailResolver {
  Future<String?> resolve(VideoEpisodeEntry entry);
}

/// 帧抽取器签名（对齐 [extractVideoFrameViaFfmpeg] 的具名参数形状）；仅供测试注入替身。
typedef EpisodeFrameExtractor = Future<String?> Function({
  required String inputPath,
  required String outputPath,
  double atSeconds,
});

/// 剧集缩略图懒加载缓存（TODO 视频封面剧集列表）。
///
/// 解析优先级（[resolve]）：
///   1. **DB 已有封面**（[VideoEpisodeEntry.coverPath] 且文件存在）——本地成员集导入
///      时抽的帧，直接用、零 IO 开销。
///   2. **懒抽帧缓存命中**（`<video_covers>/episodes/ep_<safe key>.jpg`）——之前抽过。
///   3. **懒抽帧**——用 [extractVideoFrameViaFfmpeg] 从本地视频固定 10s 处抽一帧
///      （与导入抽帧偏移一致），写入缓存路径后返回。**去重**：同 key 进行中不重复启动。
///   4. 以上都不成立（无封面、无本地视频、抽帧失败）→ 返回 null，面板显示占位。
///
/// 抽帧是进程 / IO 开销：只在面板真正构建某行（[resolve] 被调）时触发，**绝不**在页面
/// 打开时全量预抽；失败静默回退占位，不阻塞列表滚动与播放。
class EpisodeThumbnailCache implements EpisodeThumbnailResolver {
  EpisodeThumbnailCache({
    EpisodeFrameExtractor? extractor,
    Directory? coversDirectoryOverride,
    double atSeconds = 10.0,
  })  : _extractor = extractor ?? extractVideoFrameViaFfmpeg,
        _coversDirectoryOverride = coversDirectoryOverride,
        _atSeconds = atSeconds;

  /// 进程内共享单例：跨面板打开 / 换集复用同一 in-flight 去重表与已抽缓存，避免重复抽帧。
  static final EpisodeThumbnailCache instance = EpisodeThumbnailCache();

  final EpisodeFrameExtractor _extractor;
  final Directory? _coversDirectoryOverride;
  final double _atSeconds;

  /// 同 key 正在进行的抽帧 Future（去重：并发 / 重建同一集只抽一次）。
  final Map<String, Future<String?>> _inFlight = <String, Future<String?>>{};

  @override
  Future<String?> resolve(VideoEpisodeEntry entry) {
    final String? key = entry.thumbnailKey;
    // 无稳定 key（远端集等）：无法缓存 / 去重，只查 DB 已有封面。
    if (key == null || key.isEmpty) {
      return _resolveCoverOnly(entry.coverPath);
    }
    // **同步**登记 in-flight，杜绝并发 resolve 在首个 await 前都看到空表而重复抽帧。
    final Future<String?>? existing = _inFlight[key];
    if (existing != null) return existing;
    final Future<String?> pending = _resolveKeyed(entry, key);
    _inFlight[key] = pending;
    return pending;
  }

  Future<String?> _resolveCoverOnly(String? cover) async {
    if (cover != null && cover.isNotEmpty && await File(cover).exists()) {
      return cover;
    }
    return null;
  }

  Future<String?> _resolveKeyed(VideoEpisodeEntry entry, String key) async {
    try {
      // 1. DB 已有封面：文件存在就直接用（本地成员集导入抽帧）。
      final String? cover = entry.coverPath;
      if (cover != null && cover.isNotEmpty && await File(cover).exists()) {
        return cover;
      }
      // 无本地视频路径 → 无法懒抽帧，回退占位。
      final String? videoPath = entry.videoPath;
      if (videoPath == null || videoPath.isEmpty) return null;
      // 2. 懒抽帧缓存命中即返回（之前抽过）。
      final File cacheFile = await _cacheFileFor(key);
      if (await cacheFile.exists() && await cacheFile.length() > 0) {
        return cacheFile.path;
      }
      // 3. 懒抽帧。
      return await _extractor(
        inputPath: videoPath,
        outputPath: cacheFile.path,
        atSeconds: _atSeconds,
      );
    } catch (_) {
      // 抽帧异常静默回退占位，绝不抛断面板。
      return null;
    } finally {
      // 完成即出表：成功已落缓存（下次命中），失败可重试。
      _inFlight.remove(key);
    }
  }

  /// 懒抽帧缓存文件：`<video_covers>/episodes/ep_<safe key>.jpg`。key 里的路径分隔符 /
  /// `:` 等非法字符归一成 `_`（复用 [videoCoverFileName] 的清洗思路），避免带 `/` `:`
  /// 的 bookUid 当文件名非法（尤其 Windows）。
  Future<File> _cacheFileFor(String key) async {
    final Directory covers =
        _coversDirectoryOverride ?? await VideoStorage.coversDir();
    final String safe = key.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    return File(p.join(covers.path, 'episodes', 'ep_$safe.jpg'));
  }
}
