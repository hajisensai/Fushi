/// 互联 host 的图形字幕整轨抽取（[GraphicSubtitleTrackExporter] 的唯一生产实现）：app 当
/// host（`FushiSyncServerController`）与无头服务端（`fushi_server` 的 `HeadlessHost`）都注入
/// 这一份，ffmpeg 一律经 `resolveFfmpegBackend`（app 移动端装 ffmpeg-kit，桌面与服务端走 CLI）。
///
/// 抽轨本身复用本地播放的同一个函数（[extractGraphicSubtitleTrack]：`-c copy` 原样复制，
/// 载荷封装按编码选——PGS 为 `.sup` 段流、VobSub / DVB 为单轨 TS 并另写轨头；按进度
/// 判活）；这里只加互联回传需要的两样：
/// - **缓存**：按（路径, 大小, 修改时间, 轨序号）落临时目录，同一集第二次请求（换轨
///   回来 / client 超时重试 / 取轨头 / 另一台 client）不再整片读盘；
/// - **在途合并**：同一条轨并发请求只抽一次。
///
/// 解码不了的编码抛 [GraphicSubtitleTrackExportUnsupported]，端点回 415，client 退回
/// 边播边记。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:fushi_engine/media/video/bitmap_subtitle/bitmap_subtitle_track.dart'
    show
        BitmapSubtitleCodec,
        bitmapSubtitleCodecOf,
        bitmapSubtitleTrackHeaderPath;
import 'package:fushi_engine/media/video/bitmap_subtitle/graphic_subtitle_input.dart';
import 'package:fushi_engine/media/video/bitmap_subtitle/graphic_subtitle_track_extract.dart'
    show extractGraphicSubtitleTrack;
import 'package:fushi_engine/sync/graphic_subtitle_track_export.dart';
import 'package:path/path.dart' as p;

/// 抽轨函数的形状（测试替换用，生产是 [extractGraphicSubtitleTrack]：载荷写到
/// [outputPath]，需要轨头时写到 `bitmapSubtitleTrackHeaderPath(outputPath)`）。
typedef GraphicSubtitleTrackExtract =
    Future<bool> Function({
      required String videoPath,
      required int streamIndex,
      required String outputPath,
      required String codec,
    });

/// 带缓存与在途合并的图形字幕整轨抽取。
class InterconnectGraphicSubtitleExporter {
  InterconnectGraphicSubtitleExporter({
    Directory? cacheDir,
    GraphicSubtitleTrackExtract? extract,
  }) : _cacheDirOverride = cacheDir,
       _extract = extract ?? _defaultExtract;

  /// 进程内共用的一份（缓存跨 host 重启保留在临时目录）。
  static final InterconnectGraphicSubtitleExporter shared =
      InterconnectGraphicSubtitleExporter();

  final Directory? _cacheDirOverride;
  final GraphicSubtitleTrackExtract _extract;
  final Map<String, Future<GraphicSubtitleTrackExport?>> _inflight =
      <String, Future<GraphicSubtitleTrackExport?>>{};

  static Future<bool> _defaultExtract({
    required String videoPath,
    required int streamIndex,
    required String outputPath,
    required String codec,
  }) => extractGraphicSubtitleTrack(
    input: GraphicSubtitleInput.local(videoPath),
    streamIndex: streamIndex,
    outputPath: outputPath,
    codec: codec,
  );

  Directory get _cacheDir =>
      _cacheDirOverride ??
      Directory(p.join(Directory.systemTemp.path, 'fushi_graphic_sub_tracks'));

  /// [GraphicSubtitleTrackExporter] 签名的入口。
  Future<GraphicSubtitleTrackExport?> export({
    required String videoPath,
    required int streamIndex,
    required String codec,
  }) {
    final BitmapSubtitleCodec? kind = bitmapSubtitleCodecOf(codec);
    if (kind == null) throw GraphicSubtitleTrackExportUnsupported(codec);
    final FileStat stat = File(videoPath).statSync();
    if (stat.type != FileSystemEntityType.file) {
      return Future<GraphicSubtitleTrackExport?>.value();
    }
    final String key = graphicSubtitleExportCacheKey(
      videoPath: videoPath,
      sizeBytes: stat.size,
      modifiedMs: stat.modified.millisecondsSinceEpoch,
      streamIndex: streamIndex,
    );
    final File payload = File(p.join(_cacheDir.path, '$key.bin'));
    final GraphicSubtitleTrackExport? cached = _exportOf(payload, kind);
    if (cached != null) {
      return Future<GraphicSubtitleTrackExport?>.value(cached);
    }
    final Future<GraphicSubtitleTrackExport?>? running = _inflight[key];
    if (running != null) return running;
    final Future<GraphicSubtitleTrackExport?> loading =
        _extractInto(
          payload,
          kind,
          videoPath: videoPath,
          streamIndex: streamIndex,
          codec: codec,
        ).whenComplete(() {
          // 块体而非箭头：`remove` 返回被移除的 Future，箭头会让 whenComplete 等它自己。
          _inflight.remove(key);
        });
    _inflight[key] = loading;
    return loading;
  }

  /// 缓存里的载荷（+ 轨头）→ 回传描述；没有 / 是空壳返回 null。
  static GraphicSubtitleTrackExport? _exportOf(
    File payload,
    BitmapSubtitleCodec kind,
  ) {
    if (!payload.existsSync() || payload.lengthSync() == 0) return null;
    final File header = File(bitmapSubtitleTrackHeaderPath(payload.path));
    return GraphicSubtitleTrackExport(
      file: payload,
      format: kind.muxer,
      headerFile: header.existsSync() ? header : null,
    );
  }

  /// 先抽到工作目录再改名进缓存：抽到一半被杀 / 失败不会留下一份截断的「缓存」。
  /// 轨头先于载荷落位——缓存命中的判据是载荷，载荷在就一定带着它的轨头。
  Future<GraphicSubtitleTrackExport?> _extractInto(
    File payload,
    BitmapSubtitleCodec kind, {
    required String videoPath,
    required int streamIndex,
    required String codec,
  }) async {
    payload.parent.createSync(recursive: true);
    final Directory work = payload.parent.createTempSync('extract_');
    try {
      final String workPayload = p.join(work.path, 'track.bin');
      final bool ok = await _extract(
        videoPath: videoPath,
        streamIndex: streamIndex,
        outputPath: workPayload,
        codec: codec,
      );
      final File extracted = File(workPayload);
      if (!ok || !extracted.existsSync() || extracted.lengthSync() == 0) {
        return null;
      }
      final File workHeader = File(bitmapSubtitleTrackHeaderPath(workPayload));
      if (workHeader.existsSync()) {
        workHeader.renameSync(bitmapSubtitleTrackHeaderPath(payload.path));
      }
      extracted.renameSync(payload.path);
      return _exportOf(payload, kind);
    } finally {
      try {
        work.deleteSync(recursive: true);
      } on FileSystemException {
        // 工作目录留给系统清理临时目录。
      }
    }
  }
}

/// 缓存键：同路径的文件被原地替换（大小 / 修改时间变了）就不再命中旧缓存。
String graphicSubtitleExportCacheKey({
  required String videoPath,
  required int sizeBytes,
  required int modifiedMs,
  required int streamIndex,
}) => sha1
    .convert(utf8.encode('$videoPath|$sizeBytes|$modifiedMs|$streamIndex|v2'))
    .toString();

/// `FushiSyncServer.graphicSubtitleTrackExporter` 的生产实现（app 与无头服务端同一份）。
Future<GraphicSubtitleTrackExport?> exportGraphicSubtitleTrackForInterconnect({
  required String videoPath,
  required int streamIndex,
  required String codec,
}) => InterconnectGraphicSubtitleExporter.shared.export(
  videoPath: videoPath,
  streamIndex: streamIndex,
  codec: codec,
);
