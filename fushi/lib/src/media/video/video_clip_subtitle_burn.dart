/// 片段导出的**硬字幕烧录**（BUG-2202）：把字幕画进画面像素，而不是封成独立轨。
///
/// 为什么必须烧：软字幕轨（mp4 里只能是 3GPP Timed Text = `tx3g`）会让 QQ 这类 IM
/// 的内置播放器**整个文件判为不可播**——实测同一份片段，带 tx3g 轨打不开，去掉轨
/// 就能放；把轨的 `tkhd` enabled 位清零、把 `hdlr` 从 `sbtl` 改成规范的 `text`，两种
/// 都仍然打不开。而即便它能播，QQ 也不会去渲染 tx3g，所以「内封」在导出→分享这个
/// 主场景里是纯负资产：既让文件播不了，播得了也看不见字。
///
/// 为什么走 `overlay` 而不是 libass 的 `subtitles` filter：
/// - `overlay` 是 ffmpeg **内建** filter，五个平台一个新原生依赖都不加，`ffmpeg-min`
///   的构建脚本只需在 `FILTERS` 白名单里多一个词；libass 要拖进 libass + freetype +
///   fribidi + fontconfig 四个库，而 macOS 那边（BUG-1443 起不能用 brew 的动态库）
///   得把整条依赖链从源码静态编一遍。
/// - 布局全在 Dart 侧算完（[ClipBurnCue.pngPath] 是一张与视频**同分辨率**的全画幅
///   RGBA 图，overlay 到 (0,0)），于是字幕的字体、字号、描边、注音与用户在播放器里
///   看到的完全一致——这正是本模块既有的设计哲学（见 `video_clip_subtitle.dart`：
///   字幕真相源是播放器内存里的 cue 而非源文件的 `0:s:N`）。libass 渲染的是 SRT
///   默认样式，注音直接没有。
///
/// 实测（`ffmpeg -v verbose` 解图）：这条链真正实例化的 filter 只有 `overlay`，外加
/// ffmpeg 为 rgba→yuva420p 自动插入的 `scale`（白名单里本来就有），连 `format` 都
/// 用不上。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

/// 烧录需要、且 `ffmpeg-min` 的 `FILTERS` 白名单里必须有的 filter。
///
/// 只有 `overlay` 是新增的；rgba→yuva420p 的转换由 ffmpeg 自动插入的 `scale`
/// 承担，而 `scale` 早就在白名单里（见 `tool/ffmpeg-min/build-ffmpeg-min.sh`）。
const Set<String> kClipBurnRequiredFilters = <String>{'overlay'};

/// 一次导出最多烧多少条字幕。
///
/// 每条 cue = 一个 `-i <png>` 输入 + 一个 overlay 节点，两者都写进命令行。Windows
/// 的 `CreateProcess` 命令行上限是 32767 字符：单条 cue 约占「输入 90 字符 + 图节点
/// 68 字符」，120 条约 19 KB，留足余量；再多就有把命令行顶爆的风险，而命令行超长的
/// 失败形态是 ffmpeg 压根没启动，很难从日志看出真因。
///
/// 片段导出的实际负载是几秒到几分钟，120 条覆盖到分钟级的密集对白。超过就整段不烧
/// （导出仍成功，只是没有字幕），**不做静默截断**——只烧前 120 条会得到一个「后半段
/// 突然没字幕」的诡异产物，比干脆没有更难排查。
const int kMaxClipBurnCues = 120;

/// 一条要烧进画面的字幕：时间窗（相对**片段起点**，毫秒）+ 已渲染好的全画幅 PNG。
///
/// 时间轴与 `buildClipSrtContent` 同一约定——已平移到片段起点为 0，并 clamp 到片段
/// 边界。overlay 的 `enable` 表达式读的是主输入经 `-ss` 之后的时间戳，也从 0 起。
@immutable
class ClipBurnCue {
  const ClipBurnCue({
    required this.startMs,
    required this.endMs,
    required this.pngPath,
  });

  /// 相对片段起点的出现时刻（毫秒）。
  final int startMs;

  /// 相对片段起点的消失时刻（毫秒）。
  final int endMs;

  /// 与视频同分辨率的全画幅 RGBA PNG（透明底，只有字那一块不透明）。
  final String pngPath;

  @override
  bool operator ==(Object other) =>
      other is ClipBurnCue &&
      other.startMs == startMs &&
      other.endMs == endMs &&
      other.pngPath == pngPath;

  @override
  int get hashCode => Object.hash(startMs, endMs, pngPath);

  @override
  String toString() => 'ClipBurnCue($startMs..$endMs, $pngPath)';
}

/// 纯函数：解析 `ffmpeg -filters` 的输出，拿到本机 ffmpeg 真正编进去了哪些 filter。
///
/// 为什么必须解析而不是假设：随包的 `ffmpeg-min` 是 `--disable-everything` + 显式
/// 白名单构建的（当前只有 28 个 filter），而用户也可能用 `FUSHI_FFMPEG` 指到自己的
/// 完整版 ffmpeg。烧录能力只能探，不能猜。
///
/// 两种真实输出的列宽**不一样**，解析器必须都吃：
/// ```
///  T.. ametadata         A->A       (null)      ← ffmpeg-min（n7.1.x），3 位 flag
///  TS overlay           VV->V      Overlay ...  ← 新版完整构建，2 位 flag
/// ```
/// 判据取「有 `->` 的行」而不是列位置：表头的 `T.. = Timeline support`、
/// `A = Audio input/output` 这些图例行都没有箭头，天然被排除。
Set<String> parseFfmpegFilterNames(String filtersLog) {
  final Set<String> names = <String>{};
  for (final String raw in const LineSplitter().convert(filtersLog)) {
    final Match? m = _kFilterLine.firstMatch(raw);
    if (m != null) names.add(m.group(1)!);
  }
  return names;
}

/// `<flags> <name> <in>-><out> <描述>`；flags 位数不固定，只要求不含空格。
final RegExp _kFilterLine =
    RegExp(r'^\s*[A-Z.]{1,4}\s+([A-Za-z0-9_]+)\s+[AVN|]+->[AVN|]+');

/// 本机 ffmpeg 能不能烧字幕。
///
/// 探测失败（[filters] 为空，比如 `-filters` 跑挂了或输出格式变了）一律判**不能**：
/// 烧不了顶多导出一个无字幕但到处能播的片段，而误判成能烧会让整次导出直接失败。
bool ffmpegCanBurnClipSubtitles(Set<String> filters) =>
    filters.isNotEmpty && kClipBurnRequiredFilters.every(filters.contains);

/// 源视频的画面尺寸，烧录时用来决定字幕 PNG 渲染成多大。
@immutable
class ClipFrameSize {
  const ClipFrameSize(this.width, this.height);

  final int width;
  final int height;

  @override
  bool operator ==(Object other) =>
      other is ClipFrameSize && other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(width, height);

  @override
  String toString() => '${width}x$height';
}

/// 纯函数：从 `ffmpeg -i` 的日志里取**首条视频流**的画面尺寸。
///
/// 与 `parseClipSourceCodecs` 读同一份探测日志（导出前那次 `ffmpeg -i` 已经跑过，
/// 不额外起进程）。取不到返回 null——调用方据此**不烧**，而不是拿一个猜的分辨率去
/// 渲染：尺寸猜错的后果是字幕被 overlay 拉伸或裁掉，比没有字幕更糟。
///
/// 只认 `1920x1080` 这种「数字 x 数字」的整段字段，避开 `[SAR 1:1 DAR 16:9]`、
/// `994 kb/s`、`23.98 fps` 这些同行邻居。
ClipFrameSize? parseClipFrameSize(String ffmpegLog) {
  for (final String raw in const LineSplitter().convert(ffmpegLog)) {
    final String line = raw.trim();
    if (!line.startsWith('Stream #')) continue;
    final int videoAt = line.indexOf('Video: ');
    if (videoAt < 0) continue;
    final Match? m = _kFrameSize.firstMatch(line.substring(videoAt + 7));
    if (m == null) return null; // 首条视频流没有尺寸 → 判探测失败，不再往下找
    final int w = int.parse(m.group(1)!);
    final int h = int.parse(m.group(2)!);
    if (w <= 0 || h <= 0) return null;
    return ClipFrameSize(w, h);
  }
  return null;
}

/// `, 1920x1080 ` / `, 1920x1080[SAR...` / 行尾。前置的 `, ` 与词边界一起，
/// 避免把 `DAR 16:9` 或时长里的数字凑成尺寸。
final RegExp _kFrameSize = RegExp(r'(?:^|,)\s*(\d{2,5})x(\d{2,5})(?=[\s,\[]|$)');

/// 纯函数：拼字幕 PNG 的输入段（`-i c0.png -i c1.png …`）。
///
/// 输入下标 0 恒是源视频，所以第 i 条 cue 的流是 `${i + 1}:v`。
List<String> buildClipBurnInputArgs(List<ClipBurnCue> cues) {
  return <String>[
    for (final ClipBurnCue cue in cues) ...<String>['-i', cue.pngPath],
  ];
}

/// 输出标签：烧录链的末端，`-map` 要用它取代 `-map 0:v:0`。
const String kClipBurnOutputLabel = '[vout]';

/// 纯函数：拼 `-filter_complex` 的图。
///
/// 形如（两条 cue）：
/// ```
/// [0:v][1:v]overlay=0:0:enable='between(t,0.083,1.447)'[vb0];
/// [vb0][2:v]overlay=0:0:enable='between(t,1.547,3.867)'[vout]
/// ```
///
/// 三个容易踩的点：
/// - **`enable` 的单引号不能省**。filtergraph 里 `,` 是链接分隔符，
///   `between(t,0.083,1.447)` 不加引号会被 ffmpeg 自己的词法器拆成三段。这层引号由
///   **ffmpeg 解析**，不是给 shell 的——参数是按列表传给进程的，不经 shell，所以
///   引号必须**留在字符串里**。
/// - **不给 PNG 输入加 `-loop 1`**。那会让图片变成无限流、输出永不结束；单帧输入靠
///   overlay 默认的 `eof_action=repeat` 一直重复最后一帧就够了。
/// - **最后一个节点的标签固定是 [kClipBurnOutputLabel]**，中间节点用 `vb<i>`，绝不
///   与 ffmpeg 自己的 `Parsed_*` / `auto_*` 命名撞车。
String buildClipBurnFilterGraph(List<ClipBurnCue> cues) {
  if (cues.isEmpty) return '';
  final StringBuffer sb = StringBuffer();
  for (int i = 0; i < cues.length; i++) {
    final ClipBurnCue cue = cues[i];
    final String inLabel = i == 0 ? '[0:v]' : '[vb${i - 1}]';
    final String outLabel =
        i == cues.length - 1 ? kClipBurnOutputLabel : '[vb$i]';
    if (i > 0) sb.write(';');
    sb
      ..write(inLabel)
      ..write('[${i + 1}:v]')
      ..write('overlay=0:0:enable=')
      ..write("'between(t,${_secs(cue.startMs)},${_secs(cue.endMs)})'")
      ..write(outLabel);
  }
  return sb.toString();
}

/// 毫秒 → `enable` 表达式里的秒。三位小数足够（一帧 24fps ≈ 41.7ms），且与
/// `-ss` / `-t` 的 `toStringAsFixed(3)` 同精度。
String _secs(int ms) => (ms / 1000.0).toStringAsFixed(3);

/// 纯函数：这批 cue 能不能烧。
///
/// 三个门，任何一个不过就整段不烧（导出照常成功，只是没字幕）：
/// - 一条都没有 → 没什么可烧的；
/// - 超过 [kMaxClipBurnCues] → 命令行会顶爆，见该常量注释；
/// - 有时间窗是空的或倒挂 → `enable='between(t,a,b)'` 在 a>=b 时恒假，那条字幕永远
///   不显示；与其产出一个「有的句子莫名其妙不出来」的片段，不如整段不烧、明确告诉
///   用户没有字幕。
bool canBurnClipCues(List<ClipBurnCue> cues) {
  if (cues.isEmpty || cues.length > kMaxClipBurnCues) return false;
  for (final ClipBurnCue cue in cues) {
    if (cue.endMs <= cue.startMs) return false;
    if (cue.startMs < 0) return false;
    if (cue.pngPath.isEmpty) return false;
  }
  return true;
}
