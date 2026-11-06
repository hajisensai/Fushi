/// 卡拉 OK 字幕页（音乐 P3，设计 §6.2 / §6.3 / §9.2）的纯判据与 mpv 指令计划。
///
/// 一页只有一个带纹理的 mpv 实例，画面、声音、字幕都由它出，三者天然同一时钟（不在 Dart
/// 里追帧）：
///
/// | 画面 | 主文件 | 附加 |
/// |---|---|---|
/// | MV | MV 视频 | 可选 `audio-add` 曲库音轨（见 `music_mv_page.dart`） |
/// | 画布（无视频） | 曲目音频（CUE 曲目是 EDL 段） | `video-add <画布.png> … albumart`：封面或纯色 |
/// | CD+G | 曲目音频 | `video-add <.cdg>`：FFmpeg `cdgraphics` 解码出画面 |
///
/// ASS「原样渲染」= `sub-add` 原文交给 libass 画进同一帧；结构化 = Flutter 侧
/// `KaraokeLyricsView` 叠在画面上。两者可切换，默认由 Rust 的特效检测（`hasEffects`）+
/// 设置项决定（[musicKaraokeDefaultOverlay]）。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;

/// 画面上叠什么字幕。
enum MusicKaraokeOverlay {
  /// ASS 原文交给 libass（字幕组特效原样保留）。
  original,

  /// 结构化逐字歌词（`KaraokeLyricsView`，可查词、统一主题）。
  structured,

  /// 不叠字幕（CD+G 自带歌词画面时的默认）。
  off,
}

/// 设置项「ASS 卡拉 OK 字幕默认显示」：自动（按特效检测）/ 总是原样 / 总是结构化。
enum MusicAssRenderPreference {
  auto('auto'),
  original('original'),
  structured('structured');

  const MusicAssRenderPreference(this.prefValue);

  /// `music_karaoke_ass_render` 偏好值。
  final String prefValue;

  static MusicAssRenderPreference fromPref(Object? value) {
    for (final MusicAssRenderPreference p in values) {
      if (p.prefValue == value) return p;
    }
    return auto;
  }
}

/// 卡拉 OK 字幕页的画面来源。
enum MusicKaraokePicture {
  /// 绑定的 MV。
  mv,

  /// 封面 / 纯色画布。
  canvas,

  /// 音频旁的 `.cdg`。
  cdg,
}

/// 打开时默认叠哪种字幕（纯函数）。
///
/// - 没有 ASS 原文：有时间轴走结构化，否则不叠；
/// - CD+G 画面本身就是歌词：默认不叠（用户仍可手动打开）；
/// - 有 ASS 原文：设置为「总是 …」时照办；「自动」时检测到特效（`hasEffects`）走原样，
///   纯 `\k` 系列走结构化（设计 §6.3）。
MusicKaraokeOverlay musicKaraokeDefaultOverlay({
  required bool hasRawAss,
  required bool hasEffects,
  required bool hasTimeline,
  required MusicAssRenderPreference preference,
  MusicKaraokePicture picture = MusicKaraokePicture.canvas,
}) {
  if (picture == MusicKaraokePicture.cdg) return MusicKaraokeOverlay.off;
  if (!hasRawAss) {
    return hasTimeline
        ? MusicKaraokeOverlay.structured
        : MusicKaraokeOverlay.off;
  }
  switch (preference) {
    case MusicAssRenderPreference.original:
      return MusicKaraokeOverlay.original;
    case MusicAssRenderPreference.structured:
      return MusicKaraokeOverlay.structured;
    case MusicAssRenderPreference.auto:
      return hasEffects
          ? MusicKaraokeOverlay.original
          : MusicKaraokeOverlay.structured;
  }
}

/// 页上可选的字幕方式（纯函数）：没有 ASS 原文就没有「原样」，没有时间轴就没有「结构化」。
List<MusicKaraokeOverlay> musicKaraokeAvailableOverlays({
  required bool hasRawAss,
  required bool hasTimeline,
}) => <MusicKaraokeOverlay>[
  if (hasRawAss) MusicKaraokeOverlay.original,
  if (hasTimeline) MusicKaraokeOverlay.structured,
  MusicKaraokeOverlay.off,
];

/// 原样渲染下发给 mpv 的字幕属性（纯函数）。
///
/// media_kit 的 `PlayerConfiguration.libass` 默认 false，会把 `sub-ass` / `sub-visibility`
/// 关掉（ASS 退化成无样式纯文本、甚至不画）；这里显式打开，其余与 mpv 默认一致——原样渲染
/// 的验收标准就是与「mpv 单独播放这份 ASS」逐帧一致（`music_karaoke_stage_real_test.dart`），
/// 任何偏离默认的字幕选项都会破坏这一点：
/// - `sub-ass-override=no`：不让 `sub-scale` / 用户样式改写 ASS 自带样式；
/// - `sub-auto=no`：只用显式 `sub-add` 的这一份，不去同目录自动挂别的字幕。
Map<String, String> musicKaraokeSubtitleProperties({required bool visible}) =>
    <String, String>{
      'sub-ass': 'yes',
      'sub-visibility': visible ? 'yes' : 'no',
      'sub-ass-override': 'no',
      'sub-auto': 'no',
    };

/// ASS 原样渲染的 `sub-delay`（秒，纯函数）。
///
/// 时间轴语义：歌词显示时间 = 音频位置 + [lyricsOffsetMs]（正 = 歌词提前，与
/// `music_lyrics.offset_ms` 同号）；MV 时间 = 音频位置 + [mvOffsetMs]（MV 有前奏为正）。
/// 脚本时刻 T 的事件要在 MV / 画面时刻 `T − lyricsOffset + mvOffset` 出现，所以
/// `sub-delay = mvOffset − lyricsOffset`。画布 / CD+G 画面就是音频时间，`mvOffsetMs = 0`。
double musicKaraokeSubDelaySeconds({
  int mvOffsetMs = 0,
  required int lyricsOffsetMs,
}) => (mvOffsetMs - lyricsOffsetMs) / 1000;

/// 画布（封面 / 纯色）作为封面轨挂进来：`albumart` 让 mpv 按静态封面处理（只解一帧、
/// 整首常驻），时长、位置仍以主文件（音频）为准。
List<String> musicKaraokeCanvasCommand(String canvasPath) => <String>[
  'video-add',
  canvasPath,
  'select',
  'canvas',
  'und',
  'yes',
];

/// CD+G 图形轨挂进来（普通视频轨，与音频同从 0 开始）。
List<String> musicKaraokeCdgCommand(String cdgPath) => <String>[
  'video-add',
  cdgPath,
  'select',
];

/// CD+G 实例要先下发的属性（纯函数）。
///
/// libavformat 的 `cdg` 探测只数开头几个包是不是图形指令；真实 `.cdg` 前奏常是成片的
/// 空包，探测分只有个位数（实测 4），低于 mpv 默认 `demuxer-lavf-probescore=26`，`video-add`
/// 静默加不上轨。CD+G 本来就是按扩展名配对来的，这个实例只放一首音频 + 这一份 `.cdg`，
/// 把门槛降到 1 只影响「接不接受」，不影响多个格式之间谁胜出。
Map<String, String> musicKaraokeCdgProperties() => <String, String>{
  'demuxer-lavf-probescore': '1',
};

/// ASS 原文挂进来并选中。
List<String> musicKaraokeAssCommand(String assPath) => <String>[
  'sub-add',
  assPath,
  'select',
];

/// 画布高度（像素）。画布只决定画面比例与封面清晰度：libass 在实际显示时按纹理（输出）
/// 分辨率排字，不按画布分辨率。
const int kMusicKaraokeCanvasHeight = 720;

/// 画布背景色（无封面 / 封面留边）。
const int kMusicKaraokeCanvasColor = 0xFF101010;

/// 画布尺寸（纯函数）：比例取 ASS 的 `PlayResX:PlayResY`（libass 按它把脚本坐标映射到
/// 画面，比例不一致字会被横向拉伸），高 [kMusicKaraokeCanvasHeight]，宽取偶数。没有 ASS
/// （只叠结构化歌词）时 16:9。
({int width, int height}) musicKaraokeCanvasSize({
  int? playResX,
  int? playResY,
}) {
  final double aspect =
      (playResX != null && playResY != null && playResX > 0 && playResY > 0)
      ? playResX / playResY
      : 16 / 9;
  final double clamped = aspect.clamp(0.25, 4.0);
  int w = (kMusicKaraokeCanvasHeight * clamped).round();
  if (w.isOdd) w += 1;
  return (width: w, height: kMusicKaraokeCanvasHeight);
}

/// 画出画布 PNG（纯计算，放后台 isolate 跑）：纯色底，封面按 contain 居中。封面解不出来
/// 时只出纯色。
Uint8List renderMusicKaraokeCanvasPng({
  required int width,
  required int height,
  Uint8List? coverBytes,
  int color = kMusicKaraokeCanvasColor,
}) {
  final img.Image canvas = img.Image(width: width, height: height);
  img.fill(
    canvas,
    color: img.ColorRgb8(
      (color >> 16) & 0xFF,
      (color >> 8) & 0xFF,
      color & 0xFF,
    ),
  );
  final img.Image? cover = coverBytes == null ? null : _decodeCover(coverBytes);
  if (cover != null && cover.width > 0 && cover.height > 0) {
    final double scale = (width / cover.width) < (height / cover.height)
        ? width / cover.width
        : height / cover.height;
    final int cw = (cover.width * scale).round().clamp(1, width);
    final int ch = (cover.height * scale).round().clamp(1, height);
    final img.Image resized = img.copyResize(
      cover,
      width: cw,
      height: ch,
      interpolation: img.Interpolation.average,
    );
    img.compositeImage(
      canvas,
      resized,
      dstX: (width - cw) ~/ 2,
      dstY: (height - ch) ~/ 2,
    );
  }
  return img.encodePng(canvas, level: 1);
}

/// 封面文件是外部输入：`package:image` 遇到截断 / 非图片字节会直接抛（RangeError 等），
/// 解不出就当没有封面（画布只出纯色），不让整页打不开。
img.Image? _decodeCover(Uint8List bytes) {
  try {
    return img.decodeImage(bytes);
  } on Object {
    return null;
  }
}

/// 画布 / ASS 落盘位置：系统临时目录下按内容哈希命名，同一份内容只写一次。
String musicKaraokeCacheFile(String dir, List<int> content, String ext) =>
    '$dir${Platform.pathSeparator}${sha1.convert(content)}.$ext';
