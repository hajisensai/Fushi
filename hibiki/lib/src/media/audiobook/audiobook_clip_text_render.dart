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

/// 片段分享文本图的布局规格（纯数据）。竖屏 720×1280（D3），沿用阅读主题色（D2）。
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
}

/// 纯函数：按选中文本长度 + 阅读设置算出文本图布局。
///
/// - [textLength]：选中文本字符数，用于自适应缩小字号（长选区不溢出/不被截断）。
/// - [baseFontSize]：阅读器正文字号（`ReaderSettings.fontSize`，逻辑 px）。
/// - [vertical] / [lineHeight] / [background] / [foreground]：沿用阅读主题（D2）。
/// - [width] / [height]：输出分辨率（默认竖屏 720×1280，D3）。
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
  int width = 720,
  int height = 1280,
  double minFontSize = 18,
  double maxFontSize = 96,
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

  final Widget card = _AudiobookClipTextCard(
    boundaryKey: boundaryKey,
    text: text,
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

/// 离屏文本卡片：`RepaintBoundary` 包一个按阅读主题着色 + 竖/横排的居中文本块。
class _AudiobookClipTextCard extends StatefulWidget {
  const _AudiobookClipTextCard({
    required this.boundaryKey,
    required this.text,
    required this.layout,
    required this.onFirstFrame,
  });

  final GlobalKey boundaryKey;
  final String text;
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
    final TextStyle textStyle = TextStyle(
      color: layout.foreground,
      fontSize: layout.fontSize,
      height: layout.lineHeight,
    );

    final Widget body = Text(
      widget.text,
      style: textStyle,
      textAlign: TextAlign.center,
    );

    // 竖排：用 RotatedBox 把整段文本块旋转。简化实现 —— 真竖排（每字直排）需 WebView
    // 渲染，此处用整块旋转近似「竖排分享卡片」观感（D2 沿用阅读方向，不追求逐字直排）。
    final Widget oriented = layout.vertical
        ? RotatedBox(
            quarterTurns: 1,
            child: body,
          )
        : body;

    return RepaintBoundary(
      key: widget.boundaryKey,
      child: Container(
        width: layout.width.toDouble(),
        height: layout.height.toDouble(),
        color: layout.background,
        alignment: Alignment.center,
        padding: EdgeInsets.all(layout.padding),
        child: oriented,
      ),
    );
  }
}
