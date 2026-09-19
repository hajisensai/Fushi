/// 视频源扩展流经本机中继时的两项归一化（BUG-2609）。
///
/// 盗版动画 CDN 常把 HLS 分片伪装成图片：响应 `image/png`、正文先是一张真 1×1 PNG
/// （AnimeKai / MegaPlay 存 tiktokcdn 的 `.image`，IEND 之后再垫几十字节），然后才是
/// MPEG-TS。ffmpeg 的 hls demuxer 逐分片探测容器，探到 PNG 就判 `Video: png` 读不出
/// 一个包，整条流在 open 后一瞬 EOF：`time-pos` 直接等于 `duration`、进度条拉满，
/// 每一集都如此，看起来像「换集也没用」。
///
/// 处理点定在中继而不是播放器：libmpv 的全部网络请求本来就经中继（`http-proxy`），
/// 剥前缀对所有扩展 / 所有 hoster 一次生效；ffmpeg 没有「跳过前 N 字节」的选项。
/// 但播放列表里的分片是 **绝对 https** 地址，libmpv 会对它们走 CONNECT 隧道——中继
/// 看不到密文里的字节。所以播放列表也要在中继改写：https 分片地址换成
/// `nativePlaybackUri` 同款的明文显式端口形式（中继终结 TLS），分片请求才会以明文
/// 形态回到中继手上。
///
/// 纯函数，与 `dart:io` 无关，便于单测。
library;

import 'dart:typed_data';

/// MPEG-TS 包长。
const int kTransportStreamPacketLength = 188;

/// 判「伪装分片」最多探前多少字节：真伪装用的都是小图（几十到几 KB），256 KiB 足够
/// 覆盖，也把「这其实就是一张大图」的探测代价封住。
const int kDisguisedSegmentProbeLimit = 256 * 1024;

/// 正文是否以常见图片格式的魔数开头（PNG / JPEG / GIF / WebP / BMP）。
bool looksLikeImagePrefix(List<int> bytes) {
  if (bytes.length < 12) return false;
  // PNG
  if (bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47) {
    return true;
  }
  // JPEG
  if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) return true;
  // GIF8
  if (bytes[0] == 0x47 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x38) {
    return true;
  }
  // RIFF....WEBP
  if (bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return true;
  }
  // BMP
  if (bytes[0] == 0x42 && bytes[1] == 0x4D) return true;
  return false;
}

/// 图片前缀之后真正的媒体起点：MPEG-TS（连续 [packets] 个 0x47 同步字节、间隔 188）
/// 或 fMP4（`ftyp` / `styp` 盒，盒长合理）。找不到返回 null（那就真是一张图）。
///
/// 只在 [looksLikeImagePrefix] 为真时调；从偏移 1 起找（偏移 0 已是图片魔数）。
int? disguisedMediaPayloadOffset(List<int> bytes, {int packets = 4}) {
  final Uint8List b = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  final int? ts = _transportStreamStart(b, packets: packets);
  final int? mp4 = _fragmentedMp4Start(b);
  if (ts == null) return mp4;
  if (mp4 == null) return ts;
  return ts < mp4 ? ts : mp4;
}

int? _transportStreamStart(Uint8List b, {required int packets}) {
  final int span = kTransportStreamPacketLength * (packets - 1);
  for (int i = 1; i + span < b.length; i++) {
    if (b[i] != 0x47) continue;
    bool ok = true;
    for (int k = 1; k < packets; k++) {
      if (b[i + kTransportStreamPacketLength * k] != 0x47) {
        ok = false;
        break;
      }
    }
    if (ok) return i;
  }
  return null;
}

int? _fragmentedMp4Start(Uint8List b) {
  // 盒头 = 4 字节大端长度 + 4 字节类型；从 i>=5 起找类型，起点 = i-4。
  for (int i = 5; i + 4 <= b.length; i++) {
    final bool ftyp =
        b[i] == 0x66 &&
        b[i + 1] == 0x74 &&
        b[i + 2] == 0x79 &&
        b[i + 3] == 0x70;
    final bool styp =
        b[i] == 0x73 &&
        b[i + 1] == 0x74 &&
        b[i + 2] == 0x79 &&
        b[i + 3] == 0x70;
    if (!ftyp && !styp) continue;
    final int start = i - 4;
    final int size =
        (b[start] << 24) |
        (b[start + 1] << 16) |
        (b[start + 2] << 8) |
        b[start + 3];
    if (size >= 8 && size <= 64 * 1024 * 1024) return start;
  }
  return null;
}

/// 响应的 Content-Type 是否 HLS 播放列表。
bool isHlsPlaylistContentType(String? contentType) {
  if (contentType == null) return false;
  final String lower = contentType.toLowerCase();
  return lower.contains('mpegurl') || lower.contains('x-mpegurl');
}

/// 请求路径是否 `.m3u8` / `.m3u`。
bool isHlsPlaylistPath(String path) {
  final String lower = path.toLowerCase();
  return lower.endsWith('.m3u8') || lower.endsWith('.m3u');
}

/// 正文是否以 `#EXTM3U` 开头。
bool looksLikeHlsPlaylist(List<int> bytes) {
  const List<int> magic = <int>[
    0x23,
    0x45,
    0x58,
    0x54,
    0x4D,
    0x33,
    0x55,
  ]; // #EXTM3U
  if (bytes.length < magic.length) return false;
  for (int i = 0; i < magic.length; i++) {
    if (bytes[i] != magic[i]) return false;
  }
  return true;
}

final RegExp _uriAttribute = RegExp(r'URI="([^"]*)"');

/// 把播放列表里的**绝对 https** 地址（分片行、变体行，以及 `#EXT-X-KEY` /
/// `#EXT-X-MAP` / `#EXT-X-MEDIA` 等标签的 `URI="…"`）逐个交给 [map]；相对地址与
/// 明文 http 原样（相对地址由 ffmpeg 按播放列表自己的中继地址解析，天然回到中继）。
/// 行尾统一成 LF（ffmpeg 两种都认）。
String rewriteHlsPlaylistUris(
  String playlist,
  String Function(String uri) map,
) {
  final List<String> out = <String>[];
  for (final String rawLine in playlist.split('\n')) {
    final String line = rawLine.endsWith('\r')
        ? rawLine.substring(0, rawLine.length - 1)
        : rawLine;
    final String trimmed = line.trim();
    if (trimmed.isEmpty) {
      out.add(line);
    } else if (trimmed.startsWith('#')) {
      out.add(
        line.replaceAllMapped(_uriAttribute, (Match m) {
          final String uri = m.group(1)!;
          return _isHttps(uri) ? 'URI="${map(uri)}"' : m.group(0)!;
        }),
      );
    } else {
      out.add(_isHttps(trimmed) ? map(trimmed) : line);
    }
  }
  return out.join('\n');
}

bool _isHttps(String uri) =>
    uri.length > 8 && uri.substring(0, 8).toLowerCase() == 'https://';

/// 请求要的是不是从 0 起的整包：没带 Range，或 `bytes=0-`（ffmpeg 的 http 首请求
/// 默认这么带，用来探服务器支不支持范围）。
bool isWholeBodyRangeRequest(String? rangeHeader) {
  if (rangeHeader == null) return true;
  return rangeHeader.replaceAll(' ', '').toLowerCase() == 'bytes=0-';
}

/// 206 的 `Content-Range` 是否覆盖整个实体（`bytes 0-(N-1)/N`）：这种 206 与 200
/// 等价，可以改写 / 剥前缀后以 200 回给 native。
bool isCompleteContentRange(String? contentRange) {
  if (contentRange == null) return false;
  final RegExpMatch? m = RegExp(
    r'^\s*bytes\s+(\d+)-(\d+)/(\d+)\s*$',
    caseSensitive: false,
  ).firstMatch(contentRange);
  if (m == null) return false;
  final int start = int.parse(m.group(1)!);
  final int end = int.parse(m.group(2)!);
  final int total = int.parse(m.group(3)!);
  return start == 0 && end + 1 == total;
}
