import 'package:flutter/foundation.dart';

/// 在线源扩展（Aniyomi lib 16 `Video.mpvArgs`）要求附加给 mpv 的选项，按白名单
/// 翻译成宿主自己的通路（EXlaIL2eKQ）。
///
/// 为什么是白名单：扩展是第三方代码，原样把任意 mpv 选项塞给 libmpv 等于允许它
/// 改脚本路径 / 输出 / 网络代理等宿主行为。这里只认取流必需的几类：
/// - `http-header-fields` / `referrer` / `user-agent` → 取流请求头（播放与下载共用，
///   与 [MihonVideo.headers] 合并，扩展显式给的 headers 优先）；
/// - `audio-file` / `audio-files` → 可选外挂音轨（与 `audioTracks` 同一通路）。
///
/// 白名单外的键记入 [ignoredKeys]（调用方打日志），不生效。
@immutable
class AnimeSourceMpvArgs {
  const AnimeSourceMpvArgs({
    this.headers = const <String, String>{},
    this.audioFiles = const <String>[],
    this.ignoredKeys = const <String>[],
  });

  static const AnimeSourceMpvArgs empty = AnimeSourceMpvArgs();

  final Map<String, String> headers;
  final List<String> audioFiles;
  final List<String> ignoredKeys;

  /// 纯函数：解析扩展给的 `mpvArgs` 键值对。键允许带前导 `--`（mpv 命令行写法）。
  static AnimeSourceMpvArgs parse(List<MapEntry<String, String>> args) {
    if (args.isEmpty) return empty;
    final Map<String, String> headers = <String, String>{};
    final List<String> audioFiles = <String>[];
    final List<String> ignored = <String>[];
    for (final MapEntry<String, String> arg in args) {
      final String key = arg.key.trim().replaceFirst(RegExp('^--'), '');
      final String value = arg.value.trim();
      switch (key) {
        case 'http-header-fields':
        case 'http-header-fields-append':
          headers.addAll(parseHttpHeaderFields(value));
        case 'referrer':
          if (value.isNotEmpty) headers['Referer'] = value;
        case 'user-agent':
          if (value.isNotEmpty) headers['User-Agent'] = value;
        case 'audio-file':
        case 'audio-files':
        case 'audio-files-append':
          audioFiles.addAll(_splitPathList(value));
        default:
          ignored.add(key);
      }
    }
    return AnimeSourceMpvArgs(
      headers: Map<String, String>.unmodifiable(headers),
      audioFiles: List<String>.unmodifiable(audioFiles),
      ignoredKeys: List<String>.unmodifiable(ignored),
    );
  }

  /// mpv `http-header-fields` 是逗号分隔的 `Name: value` 列表；值里可能含逗号
  /// （如 Cookie / Accept），所以只在「逗号后紧跟一个 `Token:`」处切分。
  static Map<String, String> parseHttpHeaderFields(String value) {
    final Map<String, String> headers = <String, String>{};
    if (value.isEmpty) return headers;
    final List<String> fields = value.split(
      RegExp(r",(?=\s*[!#$%&'*+.^_`|~0-9A-Za-z-]+\s*:)"),
    );
    for (final String field in fields) {
      final int colon = field.indexOf(':');
      if (colon <= 0) continue;
      final String name = field.substring(0, colon).trim();
      final String headerValue = field.substring(colon + 1).trim();
      if (name.isEmpty) continue;
      headers[name] = headerValue;
    }
    return headers;
  }

  /// `audio-files` 在 mpv 里按平台路径分隔符（`;` / `:`）分隔；URL 里含 `:`，所以
  /// 只按 `;` 切，单个 URL 原样保留。
  static List<String> _splitPathList(String value) => <String>[
    for (final String part in value.split(';'))
      if (part.trim().isNotEmpty) part.trim(),
  ];
}
