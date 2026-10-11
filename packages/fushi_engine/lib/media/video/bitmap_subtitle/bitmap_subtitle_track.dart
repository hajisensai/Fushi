/// 一条位图字幕轨的抽取产物：载荷文件 + 头文件（编码、extradata、流宽高），以及把它
/// 解成 [BitmapSubtitleCue] 的统一入口。
///
/// 载荷按编码选容器（见 `bitmap_subtitle/graphic_subtitle_track_extract.dart` 的抽轨参数）：
/// - PGS：`-f sup` 段流，交 [PgsSubtitleParser]（`-c copy` 逐字节等同 BD 的 `.sup`）；
/// - VobSub / DVB：`-f mpegts` 单轨 TS，[demuxMpegTsSubtitlePackets] 拆回逐包 PTS +
///   payload，再交各自解码器。TS 不带 codec extradata（VobSub 的调色板 / 画布尺寸、DVB
///   的页号），所以抽轨前先用 ffprobe 读出来写进头文件。
///
/// 头文件在 ffmpeg 起跑**之前**写好：边抽边识别时读者随时可能读到一个正在增长的载荷，
/// 必须先知道怎么解它。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:fushi_engine/media/video/bitmap_subtitle/bitmap_subtitle_cue.dart';
import 'package:fushi_engine/media/video/bitmap_subtitle/dvb_subtitle_decoder.dart';
import 'package:fushi_engine/media/video/bitmap_subtitle/dvd_subtitle_decoder.dart';
import 'package:fushi_engine/media/video/bitmap_subtitle/mpegts_subtitle_demuxer.dart';
import 'package:fushi_engine/media/video/bitmap_subtitle/pgs_subtitle_parser.dart';

/// 支持整轨解码的位图字幕编码。[ffmpegName] 是 ffmpeg / ffprobe / mpv 报的 codec 名。
enum BitmapSubtitleCodec {
  pgs('hdmv_pgs_subtitle'),
  dvd('dvd_subtitle'),
  dvb('dvb_subtitle');

  const BitmapSubtitleCodec(this.ffmpegName);

  final String ffmpegName;

  /// 抽轨封装器：PGS 走 `sup`，其它走 `mpegts`。
  String get muxer => this == pgs ? 'sup' : 'mpegts';

  /// 抽轨载荷文件的扩展名。
  String get payloadExtension => this == pgs ? 'sup' : 'ts';
}

/// codec 名（ffmpeg 的 `hdmv_pgs_subtitle` / `dvd_subtitle` / `dvb_subtitle`，Matroska
/// 的 `S_HDMV/PGS` / `S_VOBSUB` / `S_DVBSUB` 等写法）→ 编码；不是位图字幕返回 null。
/// DVB **图文电视**（`dvb_teletext`）是字符页，不是位图，不认。
BitmapSubtitleCodec? bitmapSubtitleCodecOf(String? codec) {
  if (codec == null) return null;
  final String c = codec.toLowerCase();
  if (c.contains('pgs')) return BitmapSubtitleCodec.pgs;
  if (c.contains('dvd_sub') || c.contains('dvdsub') || c.contains('vobsub')) {
    return BitmapSubtitleCodec.dvd;
  }
  if (c.contains('dvb_sub') || c.contains('dvbsub')) {
    return BitmapSubtitleCodec.dvb;
  }
  return null;
}

/// 抽轨头：解码载荷需要的全部轨级信息。
class BitmapSubtitleTrackHeader {
  const BitmapSubtitleTrackHeader({
    required this.codec,
    this.extradata,
    this.width = 0,
    this.height = 0,
  });

  final BitmapSubtitleCodec codec;

  /// codec extradata（VobSub `.idx` 头文本 / DVB 页号）；探测不到为 null。
  final Uint8List? extradata;

  /// 探测出的流宽高（VobSub 的 extradata 没写 `size:` 时的画布兜底）；不知道为 0。
  final int width;
  final int height;

  Map<String, Object?> toJson() => <String, Object?>{
    'codec': codec.ffmpegName,
    if (extradata case final Uint8List e) 'extradata': base64.encode(e),
    'width': width,
    'height': height,
  };

  /// [toJson] 的逆；形状不对 / 编码不认识返回 null。
  static BitmapSubtitleTrackHeader? fromJson(Object? json) {
    if (json is! Map) return null;
    final BitmapSubtitleCodec? codec = bitmapSubtitleCodecOf(
      json['codec'] as String?,
    );
    if (codec == null) return null;
    final Object? e = json['extradata'];
    Uint8List? extradata;
    if (e is String) {
      try {
        extradata = base64.decode(e);
      } on FormatException {
        return null;
      }
    }
    final Object? w = json['width'];
    final Object? h = json['height'];
    return BitmapSubtitleTrackHeader(
      codec: codec,
      extradata: extradata,
      width: w is int ? w : 0,
      height: h is int ? h : 0,
    );
  }
}

/// 载荷文件旁的头文件路径。
String bitmapSubtitleTrackHeaderPath(String payloadPath) =>
    '$payloadPath.header.json';

/// 解一份抽轨载荷（[complete] 为假 = 文件还在增长，尾部半个包不交出）。损坏 / 截断的
/// 部分被跳过，已解出的 cue 照常返回。
List<BitmapSubtitleCue> decodeBitmapSubtitlePayload(
  Uint8List payload,
  BitmapSubtitleTrackHeader header, {
  bool complete = true,
}) {
  switch (header.codec) {
    case BitmapSubtitleCodec.pgs:
      return PgsSubtitleParser.parse(payload);
    case BitmapSubtitleCodec.dvd:
      return decodeDvdSubtitlePackets(
        demuxMpegTsSubtitlePackets(payload, complete: complete),
        header: VobSubHeader.parse(header.extradata),
        fallbackWidth: header.width,
        fallbackHeight: header.height,
      );
    case BitmapSubtitleCodec.dvb:
      return decodeDvbSubtitlePackets(
        demuxMpegTsSubtitlePackets(payload, complete: complete),
        extradata: header.extradata,
      );
  }
}

/// ffprobe `-show_streams -show_data -of json` 的输出 → 第一条流的抽轨头。流不是位图字幕
/// / 输出解析不了返回 null；[codecName] 回报探测到的原始 codec 名（失败摘要用）。
BitmapSubtitleTrackHeader? parseBitmapSubtitleProbe(
  String output, {
  void Function(String? codecName)? codecName,
}) {
  final int open = output.indexOf('{');
  final int close = output.lastIndexOf('}');
  if (open < 0 || close <= open) return null;
  final Object? json;
  try {
    json = jsonDecode(output.substring(open, close + 1));
  } on FormatException {
    return null;
  }
  if (json is! Map) return null;
  final Object? streams = json['streams'];
  if (streams is! List || streams.isEmpty || streams.first is! Map) {
    return null;
  }
  final Map<Object?, Object?> stream = streams.first as Map<Object?, Object?>;
  final String? name = stream['codec_name'] as String?;
  codecName?.call(name);
  final BitmapSubtitleCodec? codec = bitmapSubtitleCodecOf(name);
  if (codec == null) return null;
  final Object? extradata = stream['extradata'];
  final Object? w = stream['width'];
  final Object? h = stream['height'];
  return BitmapSubtitleTrackHeader(
    codec: codec,
    extradata: extradata is String ? parseFfprobeHexDump(extradata) : null,
    width: w is int ? w : 0,
    height: h is int ? h : 0,
  );
}

/// ffprobe `-show_data` 的十六进制转储 → 字节。
///
/// 每行 `%08x: ` 偏移 + 至多 16 字节（每 2 字节一组、组后一个空格）+ 补空格到第 41 列 +
/// ASCII 列（fftools/ffprobe.c `writer_print_data`）。所以十六进制区恒为行内第 10–50 列，
/// 只取这一段，不会把 ASCII 列里恰好像十六进制的字符当数据。
Uint8List? parseFfprobeHexDump(String dump) {
  final BytesBuilder out = BytesBuilder(copy: false);
  final RegExp offset = RegExp(r'^[0-9a-fA-F]{8}: ');
  for (final String line in const LineSplitter().convert(dump)) {
    if (!offset.hasMatch(line)) continue;
    final String hex = line
        .substring(10, line.length < 50 ? line.length : 50)
        .replaceAll(' ', '');
    if (hex.length.isOdd) return null;
    for (int i = 0; i < hex.length; i += 2) {
      final int? byte = int.tryParse(hex.substring(i, i + 2), radix: 16);
      if (byte == null) return null;
      out.addByte(byte);
    }
  }
  final Uint8List bytes = out.toBytes();
  return bytes.isEmpty ? null : bytes;
}
