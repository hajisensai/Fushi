/// 互联 host 回传**图形字幕整轨**的接入缝（`GET /api/library/videos/<id>/graphicsubtitle`）。
///
/// 图形字幕（PGS / VobSub / DVB）由 libmpv 自绘，client 要每句的起止才能制卡锚句、裁
/// 句子音频。host 有原文件：由 host 在本机把那一条字幕轨原样抽出来（几百 KB），client
/// 只下这一小份自己解析，不为了字幕把几个 GB 的片子再读一遍。
///
/// 抽取本身（按编码选封装、按进度判活、缓存）不住在互联层：生产实现是
/// `interconnect_graphic_subtitle_export.dart`，app 与无头服务端都经
/// `FushiSyncServer.graphicSubtitleTrackExporter` 注入同一份；没注入的 host 对该端点
/// 回 501、能力位 `videoGraphicSubtitleTrack=false`，client 的时间表退回边播边记。
library;

import 'dart:io';

/// 一次整轨抽取的产物。
class GraphicSubtitleTrackExport {
  const GraphicSubtitleTrackExport({
    required this.file,
    required this.format,
    this.headerFile,
  });

  /// 抽出的整轨载荷。**归抽取实现所有**（通常是它的缓存文件）：host 只读它回传，
  /// 不删除、不移动。
  final File file;

  /// 封装标识（如 `sup` = PGS 段流、`mpegts` = VobSub / DVB 单轨 TS），回传时放进
  /// `X-Fushi-Graphic-Subtitle-Format` 响应头供排障。
  final String format;

  /// 轨头（JSON：编码 + 容器丢掉的 extradata，如 VobSub 调色板 / 画布、DVB 页号）。
  /// 载荷单靠自己解不出来时必须有；PGS 可为 null。同样归抽取实现所有。client 用
  /// `?part=header` 单独取。
  final File? headerFile;
}

/// 把 [videoPath] 容器里第 [streamIndex] 条字幕轨（ffmpeg `0:s:N` 相对序号）原样抽成
/// 一份独立文件。[codec] 是 ffprobe 报的轨编码（`hdmv_pgs_subtitle` / `dvd_subtitle` /
/// `dvb_subtitle` …）。
///
/// 这台 host 抽不了这种编码时抛 [GraphicSubtitleTrackExportUnsupported]（端点回 415）；
/// 抽取失败返回 null 或抛其它异常（端点回 500）。
typedef GraphicSubtitleTrackExporter =
    Future<GraphicSubtitleTrackExport?> Function({
      required String videoPath,
      required int streamIndex,
      required String codec,
    });

/// [GraphicSubtitleTrackExporter] 抛出：这台 host 的抽取实现不支持该编码。
class GraphicSubtitleTrackExportUnsupported implements Exception {
  const GraphicSubtitleTrackExportUnsupported(this.codec);

  final String codec;

  @override
  String toString() => 'GraphicSubtitleTrackExportUnsupported: $codec';
}
