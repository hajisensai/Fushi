/// 抽图形字幕轨的输入：本地路径，或 http(s) 远端地址 + 播放会话的请求头。
///
/// 远端输入的网络参数（UA / Referer / 其余头 / 重连 / 宿主中继 / TLS 钉扎）与制卡抽音频
/// 同一个出口（[buildFfmpegRemoteInputArgs]），ffmpeg 与 ffprobe 共用：头必须与播放器
/// 取流时一致，否则站点按 UA / Referer 拒发（BUG-2625）。
library;

import 'package:collection/collection.dart';
import 'package:fushi_engine/utils/misc/desktop_audio_clipper.dart'
    show buildFfmpegRemoteInputArgs, ffmpegRemoteInputFor;
import 'package:meta/meta.dart';

@immutable
class GraphicSubtitleInput {
  const GraphicSubtitleInput({
    required this.uri,
    this.headers = const <String, String>{},
    this.tlsPinSha256,
  });

  /// 本地文件。
  const GraphicSubtitleInput.local(String path)
    : uri = path,
      headers = const <String, String>{},
      tlsPinSha256 = null;

  /// 本地路径，或 `http://` / `https://` 地址。
  final String uri;

  /// 远端取流的请求头（本地输入忽略）。
  final Map<String, String> headers;

  /// 远端自签主机的证书 SHA-256 钉扎（互联 host；公网源为 null）。
  final String? tlsPinSha256;

  /// http(s) 远端输入。
  bool get isRemote => uri.startsWith('http://') || uri.startsWith('https://');

  /// 能否交给 ffmpeg 读：本地路径（含 Windows 盘符路径）或 http(s)。其它 scheme
  /// （`anime-source://`、`smb://`、`content://` 等）ffmpeg 读不了，返回 false。
  bool get isSupported {
    if (isRemote) return true;
    final Uri? parsed = Uri.tryParse(uri);
    // 单字母 scheme 是 Windows 盘符（`C:\…`）。
    return parsed == null || !parsed.hasScheme || parsed.scheme.length == 1;
  }

  /// `-i` 及其前置的输入选项（ffmpeg 与 ffprobe 通用）。
  List<String> ffmpegInputArgs() => isRemote
      ? <String>[
          ...buildFfmpegRemoteInputArgs(
            uri,
            tlsPinSha256: tlsPinSha256,
            httpHeaders: headers,
          ),
          '-i',
          ffmpegRemoteInputFor(uri),
        ]
      : <String>['-i', uri];

  @override
  bool operator ==(Object other) =>
      other is GraphicSubtitleInput &&
      other.uri == uri &&
      other.tlsPinSha256 == tlsPinSha256 &&
      const MapEquality<String, String>().equals(other.headers, headers);

  @override
  int get hashCode => Object.hash(
    uri,
    tlsPinSha256,
    const MapEquality<String, String>().hash(headers),
  );

  @override
  String toString() =>
      'GraphicSubtitleInput($uri${headers.isEmpty ? '' : ', ${headers.length} headers'})';
}
