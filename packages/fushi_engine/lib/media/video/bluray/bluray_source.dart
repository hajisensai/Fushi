// 把一条 MPLS 变成播放内核吃得下的东西。
//
// 两种形态，能用第一种就绝不用第二种：
//
//   1. **真实文件路径**——播放列表只有一个片段、且把这段从头用到尾时，直接交出
//      `STREAM/<id>.m2ts`。这是绝大多数 MV 盘、剧集盘每集、以及单段正片的形态。给真
//      实路径的好处不在播放（两种都能播），而在下游：ffmpeg 抽封面、内嵌字幕探测、
//      制卡裁剪这些链路全都吃「一个本地文件」，换成别的什么它们就地失效。
//   2. **`edl://`**——多段拼接，或需要按 IN/OUT 截取时。EDL 是 mpv 内核自带的时间轴
//      拼接语法（不是可选构建项，五端的 libmpv 都有），它把若干段拼成一条连续时间
//      轴，seek、时长、进度全部按拼接后的轴走，正是 BD 播放列表要的语义。
//
// 为什么不交给 `bluray://` 让 mpv 自己解盘：只有 Windows 的随包 libmpv 编了
// libbluray，另外三个平台的 vendored 包由别的 fork 仓构建、上游默认不编。同一个功能
// 在五端要么都有要么都没有，不能做成「只有 Windows 能看」。
//
// 时间零点上有一个容易踩反的地方：MPLS 的 IN/OUT 是片段自身时间轴上的绝对 PTS，而
// m2ts 首个 PTS 几乎从不为 0。mpv 打开**顶层文件**时会把首帧归零
// （`--rebase-start-time` 默认 yes，就是为传输流写的），但 **EDL 段的 `start` 不走这
// 条路**：`demux_edl.c` 在省略 `start` 时填的默认值是源 demuxer 的 `start_time`，而
// `demux_timeline.c` 的 `switch_segment()` 用 `ts_offset = start - d_start` 把源包映
// 到虚拟时间轴上——两处都要求 `start` 与源包的**原始** PTS 同域。所以 EDL 里直接写
// MPLS 的 IN，不减 CLPI 零点；减了的话该段的包会全部落到 `seg->end` 之外被丢掉，表现
// 是这一段瞬间 EOF、画面出不来。
//
// CLPI 的零点仍然要读，但只用在一个地方：判断这条 PlayItem 是不是把整段从头用到尾
// （是就走形态 1）。读不到时退化成「整段照播」——多播一点是可接受的降级，播到别处不是。

import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'bluray_clip_info.dart';
import 'bluray_playlist.dart';

/// 一条 MPLS 解析出的可播放源。
class BluraySource {
  const BluraySource({
    required this.uri,
    required this.isPlainFile,
    required this.primaryStreamPath,
    required this.duration,
    required this.chapters,
  });

  /// 交给播放内核的东西：`isPlainFile` 时是本地文件绝对路径，否则是 `edl://…`。
  final String uri;

  /// [uri] 是不是一个真实存在的本地文件路径。
  final bool isPlainFile;

  /// 播放列表引用的第一个 `STREAM/*.m2ts` 绝对路径。
  ///
  /// 抽封面、探容器这类「随便给我一段真实码流」的用途都用它，即使整条播放列表是拼
  /// 起来的。
  final String primaryStreamPath;

  /// 按播放列表时间轴算出的总时长（来自 MPLS，不需要探测）。
  final Duration duration;

  /// 章节起点，相对播放列表时间轴。
  final List<Duration> chapters;
}

/// [path] 是不是一条蓝光播放列表。
bool isBlurayPlaylistPath(String path) =>
    p.extension(path).toLowerCase() == '.mpls';

/// 从一条 `.mpls` 的绝对路径反推盘根（含 `BDMV` 的那一层）。
String? blurayDiscRootForPlaylistPath(String playlistPath) {
  final List<String> parts = p.split(p.normalize(playlistPath));
  if (parts.length < 4) return null;
  if (parts[parts.length - 2].toUpperCase() != 'PLAYLIST') return null;
  if (parts[parts.length - 3].toUpperCase() != 'BDMV') return null;
  return p.joinAll(parts.sublist(0, parts.length - 3));
}

/// 读入 [playlistPath] 指向的 MPLS 并解析成可播放源。
///
/// 不是 MPLS、盘结构不完整、或引用的片段一个都不在，返回 null。
Future<BluraySource?> resolveBluraySource(String playlistPath) async {
  if (!isBlurayPlaylistPath(playlistPath)) return null;
  final String? root = blurayDiscRootForPlaylistPath(playlistPath);
  if (root == null) return null;

  final File file = File(playlistPath);
  final Uint8List bytes;
  try {
    if (!file.existsSync()) return null;
    bytes = await file.readAsBytes();
  } on FileSystemException {
    return null;
  }
  final BlurayPlaylist? playlist = parseBlurayPlaylist(
    bytes,
    id: p.basenameWithoutExtension(playlistPath),
  );
  if (playlist == null) return null;

  return buildBluraySource(
    playlist,
    discRootPath: root,
    timebases: await _readTimebases(root, playlist),
  );
}

/// 读出播放列表用到的每个片段的时间零点。读不到的片段不进表。
Future<Map<String, BlurayClipTimebase>> _readTimebases(
  String discRootPath,
  BlurayPlaylist playlist,
) async {
  final Map<String, BlurayClipTimebase> result = <String, BlurayClipTimebase>{};
  for (final String clipId in playlist.clipIds.toSet()) {
    final File file = File(
      p.join(discRootPath, 'BDMV', 'CLIPINF', '$clipId.clpi'),
    );
    try {
      if (!file.existsSync()) continue;
      final BlurayClipTimebase? timebase = parseBlurayClipTimebase(
        await file.readAsBytes(),
      );
      if (timebase != null) result[clipId] = timebase;
    } on FileSystemException {
      continue;
    }
  }
  return result;
}

/// 纯函数版：给定播放列表与各段零点，算出该交给内核什么。
///
/// [timebases] 缺项表示该段零点未知，这一段按整段照播处理。
BluraySource? buildBluraySource(
  BlurayPlaylist playlist, {
  required String discRootPath,
  required Map<String, BlurayClipTimebase> timebases,
}) {
  if (playlist.clips.isEmpty) return null;

  String streamPath(String clipId) =>
      p.join(discRootPath, 'BDMV', 'STREAM', '$clipId.m2ts');

  final String primary = streamPath(playlist.clips.first.clipId);
  final List<Duration> chapters = playlist.chapters
      .map((BlurayChapter c) => c.start)
      .toList(growable: false);

  // 单段且完整覆盖：直接给文件路径。
  if (playlist.clips.length == 1) {
    final BlurayClipRef clip = playlist.clips.first;
    final BlurayClipTimebase? timebase = timebases[clip.clipId];
    if (timebase == null || _coversWholeClip(clip, timebase)) {
      return BluraySource(
        uri: primary,
        isPlainFile: true,
        primaryStreamPath: primary,
        duration: playlist.duration,
        chapters: chapters,
      );
    }
  }

  final StringBuffer edl = StringBuffer('edl://');
  for (final BlurayClipRef clip in playlist.clips) {
    final String path = streamPath(clip.clipId);
    edl.write(encodeEdlField(path));
    // 每段一律显式写起止，**整段用满的段也写**：省略时 mpv 取 lavf 对 MPEG-TS 从尾部
    // 扫出来的估计时长当段长（demux_edl.c `part->length = source->duration + …`），
    // 每道接缝的误差累加到后续段的虚拟起点，而 [chapters] 是按 MPLS 精确 tick 算的
    // ——多段正片后段章节与画面就错位。IN/OUT 本来就精确已知，没有理由交给估计。
    // 起点直接用 MPLS 的 IN——EDL 的 start 在**源文件原始时间戳域**里，不减零点
    // （零点未知的段同样成立：IN 本就是原始 PTS）。
    edl.write(',');
    edl.write(_seconds(clip.inTimeTicks));
    edl.write(',');
    edl.write(_seconds(clip.durationTicks));
    edl.write(';');
  }

  return BluraySource(
    uri: edl.toString(),
    isPlainFile: false,
    primaryStreamPath: primary,
    duration: playlist.duration,
    chapters: chapters,
  );
}

/// 这段 PlayItem 是不是把整个片段从头用到尾。
///
/// 留 1 帧（按最慢的 24000/1001 算约 42ms）的容差：授权工具写出来的 IN/OUT 与 CLPI
/// 的呈现区间常差几个 tick，逐 tick 相等会把绝大多数「其实是整段」判成需要截取。
bool _coversWholeClip(BlurayClipRef clip, BlurayClipTimebase timebase) {
  const int tolerance = kBlurayTimeScale ~/ 24 + 1;
  return clip.inTimeTicks <= timebase.presentationStartTicks + tolerance &&
      clip.outTimeTicks >= timebase.presentationEndTicks - tolerance;
}

/// 45 kHz tick → 秒；6 位小数把 1 tick（22.2 µs）也保住，mpv 按 double 解析。
String _seconds(int ticks) => (ticks / kBlurayTimeScale).toStringAsFixed(6);

/// 按 mpv EDL 的 `%<字节数>%<内容>` 形式转义一个字段。
///
/// 路径里的 `:`（盘符）、`,`（字段分隔）、`;`（条目分隔）在 EDL 里都有语义，Windows
/// 路径必然撞上，所以一律走长度前缀而不是逐字符转义——EDL 没有转义字符。
String encodeEdlField(String value) {
  final int byteLength = utf8Length(value);
  return '%$byteLength%$value';
}

/// [value] 的 UTF-8 字节数。EDL 的长度前缀按字节算，不是按码点。
int utf8Length(String value) {
  int length = 0;
  for (final int rune in value.runes) {
    if (rune <= 0x7F) {
      length += 1;
    } else if (rune <= 0x7FF) {
      length += 2;
    } else if (rune <= 0xFFFF) {
      length += 3;
    } else {
      length += 4;
    }
  }
  return length;
}
