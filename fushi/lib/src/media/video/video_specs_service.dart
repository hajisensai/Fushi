/// 视频文件技术规格的读取与按需探测（v95）。
///
/// UI 的约束决定了这个模块的形状：库页在 `build` 里同步渲染几十张卡，**不能 await**。
/// 所以对外只有一个同步读 [specsFor]（命中内存缓存就给，没有就返回 null），另有一个
/// [prime] 让调用方把「我这一屏要用到的路径」交进来——GridView 只 build 可见项与缓存
/// 区，于是天然只探可见的那些，不会因为库里有几千个文件就把它们全 ffprobe 一遍。
///
/// 三层：内存 map（渲染读它）→ `video_file_specs` 表（跨启动持久）→ ffprobe（最后手段）。
///
/// 失效判据是「文件大小 + 修改时刻 + 探测器字段集版本」三者全等，任一不同就重探：
/// 用户换了个同名的高清片源、补录了音轨，或者我们自己扩了探测字段，缓存都必须让路。
library;

import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/media/video/video_duration_probe.dart';
import 'package:fushi/src/models/app_model.dart' show appProvider;

/// 同时在跑的 ffprobe 进程数上限。
///
/// 2 而不是更多：探测只读 header（几十毫秒），瓶颈是进程启动与磁盘寻道；开太多会在
/// 机械盘/网络盘上互相抢寻道，反而更慢，还会跟正在播放的视频抢 IO。
const int kVideoSpecsProbeConcurrency = 2;

/// 订阅面。生命周期归 `AppModel`（那里懒建、db 关闭时销毁），这里只负责让 widget
/// 订阅到它，**且只重建 watch 它的那个子树**——服务通知频率高（滚一屏几十次），
/// 绝不能经 AppModel 的 `notifyListeners` 转发出去。
final videoSpecsProvider = ChangeNotifierProvider<VideoSpecsService>(
  (ref) => ref.watch(appProvider).videoSpecsService,
);

/// 规格服务。挂在 [AppModel] 之下，库页与详情页共用一份缓存。
class VideoSpecsService extends ChangeNotifier {
  VideoSpecsService(this._db, {this.probe = probeVideoFacts});

  final FushiDatabase _db;

  /// 探测入口，可注入以便单测不真起 ffprobe。
  final Future<VideoProbeFacts> Function(String path) probe;

  /// 已知规格。**value 可为 null**：null = 已经查过、这个文件探不出规格（没装
  /// ffprobe / 文件损坏 / 是流 URL），用来防止对同一个失败文件反复重试。
  final Map<String, VideoProbeFacts?> _cache = <String, VideoProbeFacts?>{};

  final Queue<String> _queue = Queue<String>();
  final Set<String> _queued = <String>{};
  int _running = 0;
  bool _disposed = false;

  /// 同步读一个文件的规格。没探过或探不出返回 null。
  ///
  /// **不触发探测**——渲染路径必须是纯读。要探请先调 [prime]。
  VideoProbeFacts? specsFor(String? filePath) {
    if (filePath == null || filePath.isEmpty) return null;
    return _cache[filePath];
  }

  /// 是否已经对这个路径有过结论（不论探到与否）。
  bool isResolved(String? filePath) =>
      filePath != null && _cache.containsKey(filePath);

  /// 把一批路径纳入视野：先一条查询批量读库，仍缺的排进后台探测队列。
  ///
  /// 幂等且可高频调用——库页每次滚动都会调它，已知的路径直接跳过。
  Future<void> prime(Iterable<String> filePaths) async {
    if (_disposed) return;
    final List<String> unknown = <String>[
      for (final String path in filePaths.toSet())
        if (path.isNotEmpty && !_cache.containsKey(path) && !_queued.contains(path))
          path,
    ];
    if (unknown.isEmpty) return;

    // 先批量读库：绝大多数情况下这一步就够了，一条 IN 查询换掉几十次 ffprobe。
    final Map<String, VideoFileSpecRow> rows =
        await _db.videoFileSpecsByPath(unknown);
    if (_disposed) return;

    bool changed = false;
    for (final String path in unknown) {
      final VideoFileSpecRow? row = rows[path];
      if (row != null && await _rowIsFresh(row)) {
        _cache[path] = videoProbeFactsFromRow(row);
        changed = true;
        continue;
      }
      // 库里没有、或已过期 → 排队现探。
      _enqueue(path);
    }
    if (changed) notifyListeners();
    _pump();
  }

  /// 立刻探一个文件并等结果（详情页用：只有一个文件，值得等）。
  ///
  /// 与队列共用缓存与失效判据，不会重复探。
  Future<VideoProbeFacts?> resolve(String filePath) async {
    if (filePath.isEmpty) return null;
    if (_cache.containsKey(filePath)) return _cache[filePath];
    final VideoFileSpecRow? row = await _db.videoFileSpec(filePath);
    if (row != null && await _rowIsFresh(row)) {
      final VideoProbeFacts facts = videoProbeFactsFromRow(row);
      _cache[filePath] = facts;
      if (!_disposed) notifyListeners();
      return facts;
    }
    return _probeAndStore(filePath);
  }

  /// 丢弃一个文件的缓存（文件被删/被替换时）。
  Future<void> invalidate(String filePath) async {
    _cache.remove(filePath);
    await _db.deleteVideoFileSpec(filePath);
    if (!_disposed) notifyListeners();
  }

  void _enqueue(String path) {
    if (_queued.contains(path)) return;
    _queued.add(path);
    _queue.add(path);
  }

  /// 把队列跑到并发上限。每完成一个就再拉一个，不用定时器轮询。
  void _pump() {
    while (!_disposed &&
        _running < kVideoSpecsProbeConcurrency &&
        _queue.isNotEmpty) {
      final String path = _queue.removeFirst();
      _running++;
      unawaited(_probeAndStore(path).whenComplete(() {
        _running--;
        _queued.remove(path);
        _pump();
      }));
    }
  }

  /// 真探一次并落库。任何失败都在 [_cache] 里记 null（已问过，别再问）。
  Future<VideoProbeFacts?> _probeAndStore(String path) async {
    try {
      final FileStat stat = await FileStat.stat(path);
      if (stat.type == FileSystemEntityType.notFound) {
        _cache[path] = null;
        return null;
      }
      final VideoProbeFacts facts = await probe(path);
      if (_disposed) return null;
      if (facts.isEmpty) {
        // 探不出就不落库——写一个空壳会让它永远「命中缓存」，再也不会重试。
        _cache[path] = null;
        notifyListeners();
        return null;
      }
      _cache[path] = facts;
      await _db.upsertVideoFileSpec(videoFileSpecCompanion(
        filePath: path,
        facts: facts,
        fileSizeBytes: stat.size,
        fileModifiedAt: stat.modified.millisecondsSinceEpoch,
      ));
      if (!_disposed) notifyListeners();
      return facts;
    } catch (e) {
      debugPrint('[VideoSpecsService] probe failed for "$path": $e');
      _cache[path] = null;
      return null;
    }
  }

  /// 缓存行是否仍代表磁盘上那个文件。
  Future<bool> _rowIsFresh(VideoFileSpecRow row) async {
    if (row.probeVersion != kVideoProbeFieldSetVersion) return false;
    final FileStat stat = await FileStat.stat(row.filePath);
    if (stat.type == FileSystemEntityType.notFound) return false;
    return stat.size == row.fileSizeBytes &&
        stat.modified.millisecondsSinceEpoch == row.fileModifiedAt;
  }

  @override
  void dispose() {
    _disposed = true;
    _queue.clear();
    _queued.clear();
    super.dispose();
  }
}

/// DB 行 → 探测事实。
///
/// 刻意复用 [VideoProbeFacts] 而不是另立一个「已落库的规格」类：两者是同一份事实的
/// 两种存放形态，各写一个类就得写一套互转，还得保证两边字段永远同步。
VideoProbeFacts videoProbeFactsFromRow(VideoFileSpecRow row) => VideoProbeFacts(
      durationMs: row.durationMs,
      fileSizeBytes: row.fileSizeBytes,
      containerBitrate: row.containerBitrate,
      video: _videoStreamFromRow(row),
      audioTracks: decodeTrackListJson<AudioTrackFacts>(
        row.audioTracksJson,
        AudioTrackFacts.fromJson,
      ),
      subtitleTracks: decodeTrackListJson<SubtitleTrackFacts>(
        row.subtitleTracksJson,
        SubtitleTrackFacts.fromJson,
      ),
    );

/// 视频流那部分全为空时返回 null——纯音频文件与「探到了但没视频流」应当同形。
VideoStreamFacts? _videoStreamFromRow(VideoFileSpecRow row) {
  if (row.width == null &&
      row.height == null &&
      row.videoCodec == null &&
      row.pixelFormat == null) {
    return null;
  }
  return VideoStreamFacts(
    codec: row.videoCodec,
    width: row.width,
    height: row.height,
    pixelFormat: row.pixelFormat,
    bitDepth: row.bitDepth,
    frameRateMilli: row.frameRateMilli,
    bitrate: row.videoBitrate,
    colorPrimaries: row.colorPrimaries,
    colorTransfer: row.colorTransfer,
    colorSpace: row.colorSpace,
  );
}

/// 探测事实 → 待写入的 DB 行。
VideoFileSpecsCompanion videoFileSpecCompanion({
  required String filePath,
  required VideoProbeFacts facts,
  required int fileSizeBytes,
  required int fileModifiedAt,
  DateTime? now,
}) {
  final VideoStreamFacts? video = facts.video;
  return VideoFileSpecsCompanion.insert(
    filePath: filePath,
    fileSizeBytes: fileSizeBytes,
    fileModifiedAt: fileModifiedAt,
    probedAt: (now ?? DateTime.now()).millisecondsSinceEpoch,
    probeVersion: kVideoProbeFieldSetVersion,
    durationMs: Value<int?>(facts.durationMs),
    containerBitrate: Value<int?>(facts.containerBitrate),
    videoCodec: Value<String?>(video?.codec),
    width: Value<int?>(video?.width),
    height: Value<int?>(video?.height),
    pixelFormat: Value<String?>(video?.pixelFormat),
    bitDepth: Value<int?>(video?.bitDepth),
    frameRateMilli: Value<int?>(video?.frameRateMilli),
    videoBitrate: Value<int?>(video?.bitrate),
    colorPrimaries: Value<String?>(video?.colorPrimaries),
    colorTransfer: Value<String?>(video?.colorTransfer),
    colorSpace: Value<String?>(video?.colorSpace),
    audioTracksJson: Value<String>(encodeTrackListJson(<Map<String, Object?>>[
      for (final AudioTrackFacts t in facts.audioTracks) t.toJson(),
    ])),
    subtitleTracksJson:
        Value<String>(encodeTrackListJson(<Map<String, Object?>>[
      for (final SubtitleTrackFacts t in facts.subtitleTracks) t.toJson(),
    ])),
  );
}
