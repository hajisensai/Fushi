import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

/// **纯函数**：从 `VideoBooks.playlistJson` 解析出集数；空 / 非播放列表 / 解析失败
/// 返回 0。供视频库卡片角标与「单视频 vs 播放列表」区分用——返回 ≥2 即播放列表。
int playlistEpisodeCount(String? playlistJson) {
  if (playlistJson == null || playlistJson.isEmpty) return 0;
  try {
    final dynamic decoded = jsonDecode(playlistJson);
    if (decoded is List) return decoded.length;
  } catch (_) {
    // 坏 JSON：当单视频处理（返回 0），不抛。
  }
  return 0;
}

/// 播放列表中的一集：标题 + 视频绝对路径 + 本集自己的播放进度。
///
/// [path] 始终是绝对路径（由 [parseM3u8] 用 baseDir 解析 m3u8 中的相对路径得到，
/// Windows `\` 已归一化为平台分隔符）。
///
/// [positionMs] 记本集自己的播放进度（毫秒，默认 0）；换集时各集互不干扰，下次
/// 打开播放列表回到 currentEpisode 那集的该位置（取代旧的「整个 VideoBook 一个
/// lastPositionMs、换集归零」语义）。
class PlaylistEntry {
  const PlaylistEntry({
    required this.title,
    required this.path,
    this.positionMs = 0,
  });

  final String title;
  final String path;
  final int positionMs;

  /// 返回一个仅 [positionMs] 改变的副本（不可变更新）。
  PlaylistEntry copyWith({int? positionMs}) => PlaylistEntry(
        title: title,
        path: path,
        positionMs: positionMs ?? this.positionMs,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'title': title,
        'path': path,
        'positionMs': positionMs,
      };

  factory PlaylistEntry.fromJson(Map<String, dynamic> json) => PlaylistEntry(
        title: json['title'] as String,
        path: json['path'] as String,
        // 兼容旧 playlistJson（无 positionMs 字段）：缺省回退 0。
        positionMs: (json['positionMs'] as int?) ?? 0,
      );
}

/// 把 [entries] 中第 [index] 集的播放进度更新为 [positionMs]，返回新列表
/// （不可变更新；越界或负位置安全处理）。纯函数，便于单测「切集保存+恢复各集
/// position」逻辑。
List<PlaylistEntry> updateEntryPosition(
  List<PlaylistEntry> entries,
  int index,
  int positionMs,
) {
  if (index < 0 || index >= entries.length) return entries;
  final int clamped = positionMs < 0 ? 0 : positionMs;
  final List<PlaylistEntry> next = List<PlaylistEntry>.of(entries);
  next[index] = next[index].copyWith(positionMs: clamped);
  return next;
}

/// 视频播到 EOF 后播放列表应切到的下一集；没有下一集时返回 null。
///
/// 单集列表 / 越界下标 / 最后一集都不推进，调用方据此保持当前位置。
int? nextPlaylistIndexAfterCompletion(
  List<PlaylistEntry> entries,
  int currentIndex,
) {
  if (entries.length <= 1) return null;
  if (currentIndex < 0 || currentIndex >= entries.length - 1) return null;
  return currentIndex + 1;
}

/// 当前集 load 成功后可后台预热的下一集视频路径。
///
/// [lastPrewarmedPath] 是调用方保存的去重位：同一下一集已经预热过时返回 null，
/// 避免每次 setState / reload 都重复触发整容器 ffmpeg 预抽。
String? nextPlaylistPathToPrewarm({
  required List<PlaylistEntry> entries,
  required int currentIndex,
  required String? lastPrewarmedPath,
}) {
  final int? nextIndex =
      nextPlaylistIndexAfterCompletion(entries, currentIndex);
  if (nextIndex == null) return null;
  final String path = entries[nextIndex].path;
  return path == lastPrewarmedPath ? null : path;
}

/// TODO-1237: resolve one m3u8 entry path [entryRaw] against the manifest dir
/// [playlistDir]. Absoluteness is judged by STRING SHAPE
/// ([_isAbsoluteM3uEntryPath]), not the host-dependent `p.isAbsolute`, so a
/// `D:\...` entry stays absolute even on a non-Windows CI / after cross-device
/// sync and is never mis-joined onto [playlistDir]:
/// - Absolute (Windows drive root `X:\`/`X:/`, UNC `\host\share`/`//host/share`,
///   POSIX `/...`): normalized and returned as-is (NOT joined with playlistDir;
///   the old unconditional `p.join(baseDir, entry)` only "worked" on Windows by
///   luck and turned UNC `\NAS\a` into `D:\NAS\a`).
/// - Relative: both `\` and `/` treated as separators, resolved against
///   [playlistDir] (the m3u8 file's own directory).
///
/// [context] is a test seam to inject a fixed [p.Context] (windows/posix) for
/// deterministic assertions; production uses the host `p.context`, byte-for-byte
/// identical to the old parseM3u8 relative-path resolution.
String resolveM3uEntryPath(
  String entryRaw,
  String playlistDir, {
  p.Context? context,
}) {
  final p.Context ctx = context ?? p.context;
  final String entry = entryRaw.trim();
  if (entry.isEmpty) return entry;
  if (_isAbsoluteM3uEntryPath(entry)) {
    // Absolute: normalize only; never join playlistDir (would break drive/UNC).
    return ctx.normalize(entry);
  }
  // Relative: normalize both separators to `/`, resolve against the m3u8 dir.
  final String rel = entry.replaceAll('\\', '/');
  return ctx.normalize(ctx.join(playlistDir, rel));
}

/// Pure string test for whether m3u8 entry [entry] is an ABSOLUTE path (no IO,
/// host-independent). True for: UNC prefix (`\`/`//`), Windows drive root
/// (`X:\`/`X:/`), or POSIX root (single leading `/`). A drive-relative `X:foo`
/// and ordinary relative paths return false.
bool _isAbsoluteM3uEntryPath(String entry) {
  if (entry.length >= 2) {
    final String c0 = entry[0];
    final String c1 = entry[1];
    // UNC: \host\share or //host/share (mixed separators tolerated).
    if ((c0 == '\\' || c0 == '/') && (c1 == '\\' || c1 == '/')) return true;
    // Windows drive root: X:\ or X:/ (must carry a root separator).
    if (_isDriveLetter(c0) &&
        c1 == ':' &&
        entry.length >= 3 &&
        (entry[2] == '\\' || entry[2] == '/')) {
      return true;
    }
  }
  // POSIX absolute: single leading `/` (UNC's `//` already handled above).
  return entry.startsWith('/');
}

/// Pure: is [ch] an ASCII letter (a Windows drive letter A-Z / a-z).
bool _isDriveLetter(String ch) {
  final int code = ch.codeUnitAt(0);
  return (code >= 65 && code <= 90) || (code >= 97 && code <= 122);
}

/// 解析扩展 M3U（m3u8）播放列表为 [PlaylistEntry] 列表（纯函数，无 IO）。
///
/// 语义：
/// - `#EXTINF:-1,<title>` 记下一条目的标题；逗号后整段为标题（含中文、括号）。
/// - 紧随其后的第一条非空、非注释行视为该集的相对路径，用 [baseDir] 解析成绝对
///   路径。Windows 反斜杠 `\` 先统一成 `/` 再 `p.join` + `p.normalize`，得到当前
///   平台的分隔符表示。
/// - 没有前置 `#EXTINF` 的裸路径行也作为一集，标题回退为该文件的 basename。
/// - 空行、`#EXTM3U` 及其它 `#` 注释行跳过（仅 `#EXTINF` 携带标题）。
List<PlaylistEntry> parseM3u8({
  required String content,
  required String baseDir,
}) {
  final List<PlaylistEntry> entries = <PlaylistEntry>[];
  String? pendingTitle;

  for (final String rawLine in content.split('\n')) {
    final String line = rawLine.trim();
    if (line.isEmpty) continue;

    if (line.startsWith('#')) {
      if (line.startsWith('#EXTINF:')) {
        final int comma = line.indexOf(',');
        // 逗号后整段是标题（保留其中的中文/括号/逗号以外字符）。
        pendingTitle = comma >= 0 ? line.substring(comma + 1).trim() : null;
      }
      // 其它注释（#EXTM3U 等）忽略。
      continue;
    }

    // 非注释非空行 = 视频相对/绝对路径。
    final String absPath = resolveM3uEntryPath(line, baseDir);
    final String title = (pendingTitle != null && pendingTitle.isNotEmpty)
        ? pendingTitle
        : p.basename(absPath);
    entries.add(PlaylistEntry(title: title, path: absPath));
    pendingTitle = null;
  }

  return entries;
}

/// HLS **master** playlist 里的一个码率 variant（同一内容的不同画质档）。
///
/// 每个 variant 由一行 `#EXT-X-STREAM-INF:...` 属性 + 紧随其后的子 playlist URI 组成
/// （见 [parseM3u8Master]）。[url] 已解析成相对 master URL 的绝对 URL（HTTP URL 语义，
/// 不是文件路径）；[bandwidth]（bps）/ [resolution]（`宽x高`）/ [codecs] / [frameRate]
/// 可能缺省（HLS 规范只强制 BANDWIDTH，其余可空）。
///
/// 与 [PlaylistEntry]（本地多集文件清单）正交：那是「一本书多集本地文件」，这是「一条
/// 网络流多档码率」。两者靠 m3u8 内容里有无 `#EXT-X-STREAM-INF` 区分（[isHlsMasterPlaylist]），
/// 互不误伤。
@immutable
class HlsVariant {
  const HlsVariant({
    required this.url,
    this.bandwidth,
    this.resolution,
    this.codecs,
    this.frameRate,
  });

  /// variant 子 playlist 的绝对 URL（已按 master URL 做 HTTP URL 语义解析）。
  final String url;

  /// BANDWIDTH（峰值码率，bps）；缺省 null。
  final int? bandwidth;

  /// RESOLUTION（`宽x高`，如 `1920x1080`）；缺省 null。
  final String? resolution;

  /// CODECS（逗号分隔编解码器标识，原样保留）；缺省 null。
  final String? codecs;

  /// FRAME-RATE（帧率）；缺省 null。
  final double? frameRate;

  /// 从 [resolution] `宽x高` 取宽；解析不出返回 null。
  int? get width => _resolutionPart(0);

  /// 从 [resolution] `宽x高` 取高（用于 `720p` 这类画质档标注）；解析不出返回 null。
  int? get height => _resolutionPart(1);

  int? _resolutionPart(int index) {
    final String? res = resolution;
    if (res == null) return null;
    final List<String> parts = res.toLowerCase().split('x');
    if (parts.length != 2) return null;
    return int.tryParse(parts[index].trim());
  }

  /// UI 画质标签：优先 `高度p`（如 `1080p`），附加码率（`1080p · 5.0 Mbps`）；无分辨率
  /// 时退回纯码率；两者都无退回 `HLS`。纯函数便于单测。
  String get qualityLabel {
    final int? h = height;
    final String? res = h != null ? '${h}p' : null;
    final String? rate = _bitrateLabel;
    if (res != null && rate != null) return '$res · $rate';
    return res ?? rate ?? 'HLS';
  }

  String? get _bitrateLabel {
    final int? b = bandwidth;
    if (b == null || b <= 0) return null;
    if (b >= 1000000) return '${(b / 1000000).toStringAsFixed(1)} Mbps';
    return '${(b / 1000).round()} kbps';
  }
}

/// 判定 m3u8 [content] 是否为 HLS **master** playlist（含 `#EXT-X-STREAM-INF` 码率
/// variant）。纯函数。
///
/// master → true；media playlist（只有 `#EXTINF` 分段 / `#EXT-X-TARGETDURATION`）与本地
/// 多集文件清单（[parseM3u8] 消费的扩展 M3U）→ false。判据是「有无 STREAM-INF」，故
/// 绝不误伤本地分集清单（那里只有 `#EXTINF`，无 STREAM-INF）。
bool isHlsMasterPlaylist(String content) {
  for (final String rawLine in content.split('\n')) {
    if (rawLine.trim().startsWith('#EXT-X-STREAM-INF')) return true;
  }
  return false;
}

/// 解析 HLS **master** playlist 的 `#EXT-X-STREAM-INF` variant 列表（纯函数，无 IO）。
///
/// 语义：
/// - 每行 `#EXT-X-STREAM-INF:BANDWIDTH=..,RESOLUTION=WxH,CODECS="..",FRAME-RATE=..`
///   携带该 variant 属性（属性值可含引号包裹的逗号，用引号感知切分）。
/// - 紧随其后的第一条非空、非注释行是该 variant 子 playlist 的 URI，按 **HTTP URL 语义**
///   相对 [baseUrl]（master playlist URL）解析成绝对 URL（`Uri.resolve`，不是文件路径 join）。
/// - media playlist（无 STREAM-INF，只有 `#EXTINF` 分段）或本地文件清单 → 返回空列表。
///
/// 与 [parseM3u8]（本地多集文件清单，走 `p.join` 文件路径语义）严格分开：master 的
/// 子 URI 是 URL、按 URL 解析；本地清单的路径是文件、按平台分隔符 join。
List<HlsVariant> parseM3u8Master({
  required String content,
  required String baseUrl,
}) {
  final List<HlsVariant> variants = <HlsVariant>[];
  final Uri? base = Uri.tryParse(baseUrl);
  Map<String, String>? pendingAttrs;

  for (final String rawLine in content.split('\n')) {
    final String line = rawLine.trim();
    if (line.isEmpty) continue;

    if (line.startsWith('#')) {
      if (line.startsWith('#EXT-X-STREAM-INF:')) {
        pendingAttrs = _parseHlsAttributes(
          line.substring('#EXT-X-STREAM-INF:'.length),
        );
      }
      // 其它标签（#EXTM3U / #EXT-X-MEDIA / #EXT-X-VERSION 等）忽略。
      continue;
    }

    // 非注释非空行：仅当前面有 STREAM-INF 时才是 variant URI；否则（无 pendingAttrs）
    // 是 media playlist 的分段或裸行，跳过（master 解析只关心 variant）。
    if (pendingAttrs == null) continue;

    final Map<String, String> attrs = pendingAttrs;
    pendingAttrs = null;

    final String resolvedUrl = _resolveHlsUri(base, baseUrl, line);
    final String? bw = attrs['BANDWIDTH'];
    final String? avgBw = attrs['AVERAGE-BANDWIDTH'];
    variants.add(HlsVariant(
      url: resolvedUrl,
      bandwidth: int.tryParse(bw ?? avgBw ?? ''),
      resolution: attrs['RESOLUTION'],
      codecs: attrs['CODECS'],
      frameRate: double.tryParse(attrs['FRAME-RATE'] ?? ''),
    ));
  }

  return variants;
}

/// 按画质从高到低排序 variant（高度优先、码率其次）；缺分辨率的排后。返回新列表，
/// 不改入参。纯函数便于单测「1080/720/480 降序」。
List<HlsVariant> sortedHlsVariantsByQualityDesc(List<HlsVariant> variants) {
  final List<HlsVariant> sorted = List<HlsVariant>.of(variants);
  sorted.sort((HlsVariant a, HlsVariant b) {
    final int ha = a.height ?? -1;
    final int hb = b.height ?? -1;
    if (ha != hb) return hb.compareTo(ha);
    final int ba = a.bandwidth ?? -1;
    final int bb = b.bandwidth ?? -1;
    return bb.compareTo(ba);
  });
  return sorted;
}

/// 解析 `#EXT-X-STREAM-INF:` 后的属性串为 `键→值` map（引号感知：`CODECS="a,b"` 的
/// 内部逗号不切分，值两端引号剥掉）。纯函数。
Map<String, String> _parseHlsAttributes(String attrs) {
  final Map<String, String> out = <String, String>{};
  final List<String> fields = <String>[];
  final StringBuffer buf = StringBuffer();
  bool inQuotes = false;
  for (int i = 0; i < attrs.length; i++) {
    final String ch = attrs[i];
    if (ch == '"') {
      inQuotes = !inQuotes;
      buf.write(ch);
    } else if (ch == ',' && !inQuotes) {
      fields.add(buf.toString());
      buf.clear();
    } else {
      buf.write(ch);
    }
  }
  if (buf.isNotEmpty) fields.add(buf.toString());

  for (final String field in fields) {
    final int eq = field.indexOf('=');
    if (eq < 0) continue;
    final String key = field.substring(0, eq).trim().toUpperCase();
    if (key.isEmpty) continue;
    String value = field.substring(eq + 1).trim();
    if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
      value = value.substring(1, value.length - 1);
    }
    out[key] = value;
  }
  return out;
}

/// 把 variant 子 URI [uri] 相对 master URL 解析成绝对 URL（HTTP URL 语义）。解析失败
/// （baseUrl 非法 URL 等）时原样返回 [uri]。纯函数。
String _resolveHlsUri(Uri? base, String baseUrl, String uri) {
  final Uri? child = Uri.tryParse(uri);
  if (child != null && child.hasScheme) return uri; // 已是绝对 URL。
  if (base == null) return uri;
  try {
    return base.resolve(uri).toString();
  } catch (_) {
    return uri;
  }
}
