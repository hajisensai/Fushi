import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:hibiki/src/utils/misc/error_log_service.dart';

/// TODO-945 M3：把有声书片段分享所选文本离屏栅格化成 PNG。
///
/// 设计（D-RENDER = OverlayEntry 一帧挂载）：全 lib 无 `RepaintBoundary.toImage`
/// 先例，手搓 `PipelineOwner` 风险高，故把文本 widget 包 `RepaintBoundary` 临时插入
/// Overlay，等真实 pipeline 跑完一帧后 `boundary.toImage(pixelRatio)` →
/// `toByteData(png)` → 移除 entry。靠真实渲染管线，行为可预测。
///
/// 布局参数（尺寸/字号/内边距/竖排）抽成纯函数 [computeClipTextLayout] 便于守卫测试，
/// 渲染本身要 BuildContext + 真实 pipeline 不可纯单测（合成由真机验）。

/// 片段分享文本图的布局规格（纯数据）。竖屏 1080×1920（D3，TODO-1147 把栅格化+输出
/// 分辨率从 720×1280 提到 1080×1920 消除文字模糊），沿用阅读主题色（D2）。
@immutable
class AudiobookClipTextLayout {
  const AudiobookClipTextLayout({
    required this.width,
    required this.height,
    required this.padding,
    required this.fontSize,
    required this.lineHeight,
    required this.vertical,
    required this.background,
    required this.foreground,
    required this.highlight,
  });

  /// 输出图宽（px）。
  final int width;

  /// 输出图高（px）。
  final int height;

  /// 文本块四周留白（px，逻辑像素）。
  final double padding;

  /// 文本字号（逻辑像素）。已按文本长度自适应缩小，保证长选区不溢出。
  final double fontSize;

  /// 行高倍数。
  final double lineHeight;

  /// 是否竖排（vertical-rl / vertical-lr）。
  final bool vertical;

  /// 背景色（阅读主题 bg）。
  final Color background;

  /// 文字色（阅读主题 fg）。
  final Color foreground;

  /// 逐句高亮跟随色（阅读主题 sasayaki——有声书当前句跟读高亮的背景衬色）。
  /// 与阅读器正文里 `::highlight(hoshi-sasayaki)` 同一真相源（`ReaderThemeColors.sasayaki`），
  /// 导出卡片把它当整句背景衬底涂在 fg 文字之下，复刻「逐句高亮跟随」观感（TODO-1013）。
  final Color highlight;
}

/// 纯函数：按选中文本长度 + 阅读设置算出文本图布局。
///
/// - [textLength]：选中文本字符数，用于自适应缩小字号（长选区不溢出/不被截断）。
/// - [baseFontSize]：阅读器正文字号（`ReaderSettings.fontSize`，逻辑 px）。
/// - [vertical] / [lineHeight] / [background] / [foreground]：沿用阅读主题（D2）。
/// - [highlight]：逐句高亮跟随色（`ReaderThemeColors.sasayaki`，TODO-1013），作为整句
///   背景衬底涂在文字之下，复刻有声书当前句跟读高亮。
/// - [width] / [height]：输出分辨率（默认竖屏 1080×1920，D3；TODO-1147 提分辨率消模糊）。
///
/// 字号自适应规则（粗略但确定，避免巨图/截断）：以 [baseFontSize] 为上限，文本越长
/// 越往下收，最低 [minFontSize]。padding 取较小边的 8%，给文本留呼吸空间。
AudiobookClipTextLayout computeClipTextLayout({
  required int textLength,
  required double baseFontSize,
  required bool vertical,
  required double lineHeight,
  required Color background,
  required Color foreground,
  required Color highlight,
  int width = 1080,
  int height = 1920,
  double minFontSize = 18,
  double maxFontSize = 144,
}) {
  // 自适应字号：短句用接近正文 2 倍的大字（分享卡片观感），长句逐级收。
  final double base = baseFontSize <= 0 ? 22 : baseFontSize;
  final double desired = base * 2.0;
  final int safeLen = textLength <= 0 ? 1 : textLength;
  // 反比缩放：超过 12 字开始收，每多一截缩一点，夹在 [minFontSize, desired]。
  final double scaledByLength = safeLen <= 12
      ? desired
      : (desired * (12 / safeLen)).clamp(minFontSize, desired);
  final double fontSize = scaledByLength.clamp(minFontSize, maxFontSize);
  final double shorterEdge = (width < height ? width : height).toDouble();
  final double padding = (shorterEdge * 0.08).clamp(24.0, 96.0);
  return AudiobookClipTextLayout(
    width: width,
    height: height,
    padding: padding,
    fontSize: fontSize,
    lineHeight: lineHeight <= 0 ? 1.6 : lineHeight,
    vertical: vertical,
    background: background,
    foreground: foreground,
    highlight: highlight,
  );
}

/// 把 [text] 按 [layout] 离屏栅格化成 PNG 字节。
///
/// [overlay] 必须是当前页面可用的 Overlay（如 `Overlay.of(context)`）。本函数把一个
/// 不可见的 `RepaintBoundary` 临时插入该 overlay，等一帧布局/绘制完成后取图，再移除。
/// 失败（无 overlay 帧 / 取图异常）返回 null，调用方据此回退（只导音频或提示）。
///
/// [pixelRatio] 控制栅格密度：输出像素 = 逻辑尺寸 × pixelRatio。默认 1.0（layout 已是
/// 目标像素尺寸，1.0 即 1:1）。
Future<Uint8List?> renderAudiobookClipTextToPng({
  required OverlayState overlay,
  required String text,
  required AudiobookClipTextLayout layout,
  double pixelRatio = 1.0,
}) async {
  final GlobalKey boundaryKey = GlobalKey();
  final Completer<void> attached = Completer<void>();

  // 单句静态图：一段文本、该段高亮（highlightIndex 0），等价旧行为。
  final Widget card = _AudiobookClipTextCard(
    boundaryKey: boundaryKey,
    segments: <AudiobookClipTextSegment>[
      AudiobookClipTextSegment(text: text),
    ],
    highlightIndex: 0,
    layout: layout,
    onFirstFrame: () {
      if (!attached.isCompleted) attached.complete();
    },
  );

  // 离屏：放在屏幕外（Offset 远负），不可见但参与真实 pipeline，拿到 RepaintBoundary。
  final OverlayEntry entry = OverlayEntry(
    builder: (BuildContext context) => Positioned(
      left: -100000,
      top: -100000,
      child: Material(
        type: MaterialType.transparency,
        child: card,
      ),
    ),
  );

  overlay.insert(entry);
  try {
    // 等首帧绘制完成（_AudiobookClipTextCard 在 post-frame 回调里通知），再取图。
    // 超时不静默失败：拿不到首帧就早退（避免在未挂载的 boundary 上取图）。
    var gotFirstFrame = true;
    await attached.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        gotFirstFrame = false;
      },
    );
    if (!gotFirstFrame) {
      ErrorLogService.instance.log(
        'AudiobookClipTextRender.firstFrameTimeout',
        'offscreen clip text card never reported first frame within 5s '
            '(len=${text.runes.length})',
        StackTrace.current,
      );
      return null;
    }

    final RenderObject? renderObject =
        boundaryKey.currentContext?.findRenderObject();
    if (renderObject is! RenderRepaintBoundary) {
      ErrorLogService.instance.log(
        'AudiobookClipTextRender.noBoundary',
        'offscreen boundary render object missing or wrong type: '
            '${renderObject.runtimeType}',
        StackTrace.current,
      );
      return null;
    }

    // 尺寸守卫：0 尺寸交给 toImage 会抛，提前记日志并回退。
    final ui.Size boundarySize = renderObject.size;
    if (boundarySize.width <= 0 || boundarySize.height <= 0) {
      ErrorLogService.instance.log(
        'AudiobookClipTextRender.zeroSize',
        'offscreen boundary has non-positive size: $boundarySize '
            '(layout=${layout.width}x${layout.height})',
        StackTrace.current,
      );
      return null;
    }

    // 时序根因：首帧回调时 boundary 未必完成 paint（桌面离屏首帧栅格化尤其）。
    // debug 下循环等到 !debugNeedsPaint；release 下该 getter 不可靠（assert 守护），
    // 改为固定多等几帧。两者都先把 boundary 推进已 paint 状态再 toImage。
    await _waitForBoundaryPainted(renderObject);

    final ui.Image image = await renderObject.toImage(pixelRatio: pixelRatio);
    try {
      final ByteData? bytes =
          await image.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) {
        ErrorLogService.instance.log(
          'AudiobookClipTextRender.toByteDataNull',
          'image.toByteData(png) returned null '
              '(size=$boundarySize, pixelRatio=$pixelRatio)',
          StackTrace.current,
        );
        return null;
      }
      return bytes.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  } catch (e, st) {
    // 不再吞异常：toImage / toByteData 的真因写进 in-app 日志，调用方仍回退。
    ErrorLogService.instance.log(
      'AudiobookClipTextRender.clipToImageThrew',
      e,
      st,
    );
    return null;
  } finally {
    entry.remove();
  }
}

/// 把离屏 [boundary] 推进已完成 paint 的状态，再交给 `toImage`。
///
/// 时序根因（TODO-1071 / BUG-490）：首帧 post-frame 回调时 boundary 并未必完成
/// 首次 paint，直接 `toImage` 在桌面（Windows）离屏栅格化首帧时序下会抛。
///
/// - debug：`RenderObject.debugNeedsPaint` 可用，循环等到不再 needs-paint（上限 30 帧）。
/// - release：`debugNeedsPaint` 由 assert 守护不可靠，改为固定多等几帧确保首次 paint 完成。
Future<void> _waitForBoundaryPainted(RenderRepaintBoundary boundary) async {
  const int maxTries = 30;
  if (kDebugMode) {
    var tries = 0;
    while (boundary.debugNeedsPaint && tries < maxTries) {
      await _waitForNextFrame();
      tries++;
    }
    return;
  }
  // release 确保：多等几帧，给离屏 pipeline 充分时间完成首次 paint。
  for (var i = 0; i < 3; i++) {
    await _waitForNextFrame();
  }
}

Future<void> _waitForNextFrame() {
  final Completer<void> completer = Completer<void>();
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!completer.isCompleted) completer.complete();
  });
  // 主动调度一帧，离屏 entry 不一定触发新帧。
  WidgetsBinding.instance.scheduleFrame();
  return completer.future;
}

// ─────────────────────────────────────────────────────────────────────────
// TODO-1115 逐帧动态高亮：把「多句整段文本 + 指定高亮哪一句」批量离屏渲成 N 帧 PNG。
//
// 单图 D-RENDER（[renderAudiobookClipTextToPng]）只渲一句静态图；动态高亮跟随需要
// 每句一张「整段文本 + 该句高亮」的 PNG，ffmpeg 用 image2 序列帧拼成逐句跟随视频
// （见 buildFfmpegImageSeqAudioToVideoArgs）。这里复用同一套「离屏 RepaintBoundary +
// 等 paint 完成 + toImage(png)」时序（BUG-490 已修，对每帧都生效），只把单句 Text
// 换成多句段落、按 highlightCueIndex 给指定句涂 highlight 衬底、其余句常态 fg。
// ─────────────────────────────────────────────────────────────────────────

/// 多句整段文本的一段（一句 / 一个 cue 对应的文本 + 可选图片）。
@immutable
class AudiobookClipTextSegment {
  const AudiobookClipTextSegment({
    required this.text,
    this.imageBytes,
  });

  /// 该句文本（cue.text）。
  final String text;

  /// TODO-1127：该句区间内夹带的 EPUB 插图字节（PNG/JPEG，可空）。当前导出路径
  /// 尚未从 WebView 抽取插图字节，故常为 null——保留字段+渲染分支，owner 后续接
  /// 图片抽取时无需改渲染层。
  final Uint8List? imageBytes;
}

/// TODO-1167 流式渲染回调：渲染层每产出一帧就调一次。[highlightIndex] 是这一帧高亮的
/// 句下标（-1=无句高亮），[pngBytes] 是该帧 PNG（null=渲染失败）。调用方即时消费（后台
/// isolate 编码 + 落盘）后返回 true 继续渲下一帧、false 提前停止（如遇编码失败或只需单帧）。
///
/// 用回调而非返回 `List<Uint8List?>`：让每次内存里只驻留一帧 PNG，渲一帧→编码落盘→释放，
/// 避免把 N 帧 1080×1920 PNG（+ 竖排路径每帧 8.3MB native 位图）同时驻留导致 native OOM。
typedef AudiobookClipFrameSink = Future<bool> Function(
  int highlightIndex,
  Uint8List? pngBytes,
);

/// 批量把「多句整段文本」离屏渲成 [segments].length 张 PNG（每张高亮不同一句），逐帧
/// 经 [onFrame] 回调交给调用方即时消费（TODO-1167 流式，见 [AudiobookClipFrameSink]）。
///
/// 每帧是「整段文本、该句高亮」的 PNG 字节；某句渲染失败传 null（调用方据此回退单句
/// 静态）。复用 [renderAudiobookClipTextToPng] 的离屏时序（每帧等 paint 完成再 toImage），
/// 只是把单句卡片换成多句 + 高亮某句的卡片。onFrame 返回 false 即提前停止。
///
/// [highlightIndices] 指定要渲哪些高亮下标（通常 = 帧计划里出现过的去重 cue 下标，
/// 每句只渲一次）；未传时默认渲每一句（0..segments.length-1）。-1（gap 无高亮）也可传，
/// 渲成「整段文本、无句高亮」。
Future<void> renderAudiobookClipFrames({
  required OverlayState overlay,
  required List<AudiobookClipTextSegment> segments,
  required AudiobookClipTextLayout layout,
  required AudiobookClipFrameSink onFrame,
  List<int>? highlightIndices,
  double pixelRatio = 1.0,
}) async {
  final List<int> indices = highlightIndices ??
      List<int>.generate(segments.length, (int i) => i, growable: false);
  // 流式（TODO-1167）：渲一帧立刻交给 [onFrame] 消费，不再攒成 List<Uint8List?> 返回，
  // 避免 N 帧 PNG 同时驻留。onFrame 返回 false（编码失败/只需单帧）即提前停止。
  for (final int highlightIndex in indices) {
    final Uint8List? png = await _renderClipFramePng(
      overlay: overlay,
      segments: segments,
      highlightIndex: highlightIndex,
      layout: layout,
      pixelRatio: pixelRatio,
    );
    final bool keepGoing = await onFrame(highlightIndex, png);
    if (!keepGoing) return;
  }
}

/// 渲单帧：整段文本、第 [highlightIndex] 句高亮（-1 = 无句高亮）。镜像
/// [renderAudiobookClipTextToPng] 的离屏时序，只换卡片 widget。
Future<Uint8List?> _renderClipFramePng({
  required OverlayState overlay,
  required List<AudiobookClipTextSegment> segments,
  required int highlightIndex,
  required AudiobookClipTextLayout layout,
  double pixelRatio = 1.0,
}) async {
  final GlobalKey boundaryKey = GlobalKey();
  final Completer<void> attached = Completer<void>();

  final Widget card = _AudiobookClipTextCard(
    boundaryKey: boundaryKey,
    segments: segments,
    highlightIndex: highlightIndex,
    layout: layout,
    onFirstFrame: () {
      if (!attached.isCompleted) attached.complete();
    },
  );

  final OverlayEntry entry = OverlayEntry(
    builder: (BuildContext context) => Positioned(
      left: -100000,
      top: -100000,
      child: Material(
        type: MaterialType.transparency,
        child: card,
      ),
    ),
  );

  overlay.insert(entry);
  try {
    var gotFirstFrame = true;
    await attached.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        gotFirstFrame = false;
      },
    );
    if (!gotFirstFrame) {
      ErrorLogService.instance.log(
        'AudiobookClipTextRender.frameFirstFrameTimeout',
        'offscreen multi-cue frame never reported first frame within 5s '
            '(highlight=$highlightIndex, segments=${segments.length})',
        StackTrace.current,
      );
      return null;
    }

    final RenderObject? renderObject =
        boundaryKey.currentContext?.findRenderObject();
    if (renderObject is! RenderRepaintBoundary) {
      ErrorLogService.instance.log(
        'AudiobookClipTextRender.frameNoBoundary',
        'offscreen frame boundary missing or wrong type: '
            '${renderObject.runtimeType}',
        StackTrace.current,
      );
      return null;
    }

    final ui.Size boundarySize = renderObject.size;
    if (boundarySize.width <= 0 || boundarySize.height <= 0) {
      ErrorLogService.instance.log(
        'AudiobookClipTextRender.frameZeroSize',
        'offscreen frame boundary non-positive size: $boundarySize',
        StackTrace.current,
      );
      return null;
    }

    await _waitForBoundaryPainted(renderObject);

    final ui.Image image = await renderObject.toImage(pixelRatio: pixelRatio);
    try {
      final ByteData? bytes =
          await image.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) {
        ErrorLogService.instance.log(
          'AudiobookClipTextRender.frameToByteDataNull',
          'frame image.toByteData(png) returned null (highlight=$highlightIndex)',
          StackTrace.current,
        );
        return null;
      }
      return bytes.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  } catch (e, st) {
    ErrorLogService.instance.log(
      'AudiobookClipTextRender.frameToImageThrew',
      e,
      st,
    );
    return null;
  } finally {
    entry.remove();
  }
}

/// 离屏文本卡片：`RepaintBoundary` 包按阅读主题着色的多句整段文本块，指定句高亮。
///
/// [segments] 为单元素时等价旧单句静态卡片（never break userspace）；多元素时把每句
/// 依次排下来，第 [highlightIndex] 句涂 highlight 衬底（其余常态 fg）。
class _AudiobookClipTextCard extends StatefulWidget {
  const _AudiobookClipTextCard({
    required this.boundaryKey,
    required this.segments,
    required this.highlightIndex,
    required this.layout,
    required this.onFirstFrame,
  });

  final GlobalKey boundaryKey;
  final List<AudiobookClipTextSegment> segments;
  final int highlightIndex;
  final AudiobookClipTextLayout layout;
  final VoidCallback onFirstFrame;

  @override
  State<_AudiobookClipTextCard> createState() => _AudiobookClipTextCardState();
}

class _AudiobookClipTextCardState extends State<_AudiobookClipTextCard> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.onFirstFrame();
    });
  }

  @override
  Widget build(BuildContext context) {
    final AudiobookClipTextLayout layout = widget.layout;
    // TODO-1013：复刻有声书「逐句高亮跟随」——当前句用 sasayaki 色作整句背景衬底，
    // 文字保持 fg 并加粗（呼应歌词模式当前句 font-weight: 700）。
    final TextStyle textStyle = TextStyle(
      color: layout.foreground,
      fontSize: layout.fontSize,
      height: layout.lineHeight,
      fontWeight: FontWeight.w700,
    );

    final double highlightPadV = layout.fontSize * 0.14;
    final double highlightPadH = layout.fontSize * 0.28;
    final double radius = layout.fontSize * 0.18;

    // 多句整段：每句一段，第 highlightIndex 句涂 highlight 衬底，其余常态 fg。
    final List<Widget> lines = <Widget>[];
    for (int i = 0; i < widget.segments.length; i++) {
      final AudiobookClipTextSegment segment = widget.segments[i];
      final bool isHighlighted = i == widget.highlightIndex;
      // TODO-1127：句内夹带插图与文本同层渲进整段图。当前导出路径尚未抽取插图字节，
      // imageBytes 常为 null → 只渲文本；接上抽取后此分支自动生效，不改渲染层。
      final Widget lineText = Text(
        segment.text,
        style: textStyle,
        textAlign: TextAlign.center,
      );
      final Widget line = isHighlighted
          ? Container(
              decoration: BoxDecoration(
                color: layout.highlight,
                borderRadius: BorderRadius.circular(radius),
              ),
              padding: EdgeInsets.symmetric(
                vertical: highlightPadV,
                horizontal: highlightPadH,
              ),
              child: lineText,
            )
          : Padding(
              padding: EdgeInsets.symmetric(
                vertical: highlightPadV,
                horizontal: highlightPadH,
              ),
              child: lineText,
            );
      if (segment.imageBytes != null) {
        lines.add(
          Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              line,
              Padding(
                padding: EdgeInsets.only(top: highlightPadV),
                child: Image.memory(
                  segment.imageBytes!,
                  fit: BoxFit.contain,
                ),
              ),
            ],
          ),
        );
      } else {
        lines.add(line);
      }
    }

    // 内容宽度 = 卡片宽 - 两侧 padding。文本按此宽换行（与旧单句路径一致），Column 竖向
    // 堆叠多句；再用 FittedBox(scaleDown) 让整段（尤其小图/长内容）超高时等比缩小、永不
    // RenderFlex 溢出，单句时不放大（scaleDown 只缩不放），保留原单句观感。
    final double contentWidth =
        (layout.width - layout.padding * 2).clamp(1.0, layout.width.toDouble());
    final Widget body = FittedBox(
      fit: BoxFit.scaleDown,
      child: SizedBox(
        width: contentWidth,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: lines,
        ),
      ),
    );

    // TODO-1147 option A: vertical clip frames now render through the offscreen
    // WebView true-vertical path (audiobook_clip_webview_render.dart); this
    // Flutter raster path serves horizontal only (and is the readable horizontal
    // fallback if the WebView vertical render fails). No more quarter-turn block
    // rotation (rotated text lies on its side, unreadable) -- that was the bug.
    return RepaintBoundary(
      key: widget.boundaryKey,
      child: Container(
        width: layout.width.toDouble(),
        height: layout.height.toDouble(),
        color: layout.background,
        alignment: Alignment.center,
        padding: EdgeInsets.all(layout.padding),
        child: body,
      ),
    );
  }
}
