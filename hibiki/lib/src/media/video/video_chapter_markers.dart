import 'package:flutter/material.dart';

import 'package:hibiki/src/media/video/video_player_controller.dart';

/// 进度条（seek bar）上的章节刻度（TODO-432）。
///
/// TODO-424 已加章节列表面板 + 跳转，但用户还想要「进度条上每章一个刻度」（普通播放器
/// 在 seek bar 上画的章节分隔标记）。media_kit 的 [MaterialSeekBar] / [MaterialDesktopSeekBar]
/// 自身没有暴露注入自定义子层的钩子（其 build 是写死的 Stack：轨道 + 缓冲 + 进度 + 滑块），
/// 故本刻度层只能作为 controls Stack 里独立的 [Positioned] 兄弟层叠在 seek bar 同一几何上。
///
/// 几何对齐契约（与 media_kit + [_mobileControlsTheme] / [_desktopControlsTheme] 同源）：
/// - 轨道**水平**范围：seek bar 左右各留 16px margin（桌面默认 `seekBarMargin
///   horizontal:16`、移动端显式 `left:16,right:16`），故轨道宽 = 控件区宽 - 32，position
///   百分比线性映射到这段宽度（见 media_kit `MaterialSeekBar` 的 `constraints.maxWidth`）。
///   刻度 x = `fraction * trackWidth`，与进度填充用同一坐标系。
/// - 轨道**竖直**位置：由页面按平台真实控制条几何算出 `bottom`（移动端进度条被抬到按钮条
///   上方、桌面骑在按钮行上沿），由本层的父 [Positioned] 决定，本 widget 只在自己的盒子里
///   把刻度画在竖直中线。

/// 纯函数：把章节起点换算成 seek bar 上的刻度比例 `[0,1)`（TODO-432）。
///
/// [chapters] 为 [VideoChapter] 升序列表（[VideoPlayerController.chapters]）；[durationMs]
/// 为视频总时长毫秒。规则（消除特殊情况，调用方拿到的就是「可直接画的比例」）：
/// - [durationMs] <= 0（时长未知 / 媒体头未解析）：返回空列表（无刻度，等播放器就绪后再现）。
/// - 每章 `start / duration`，clamp 到 `[0, 1]`；
/// - 丢弃 `>= 1.0` 的刻度（起点等于 / 超过总时长，画在轨道最右端无意义）；
/// - 升序去重（同一比例只留一条，多章同起点 / 浮点同值不画重叠竖线）。
///
/// 返回的比例**包含** 0.0（首章常在 0；画在轨道最左端是惯例，与列表面板首章对齐）。
List<double> chapterMarkerFractions({
  required List<VideoChapter> chapters,
  required int durationMs,
}) {
  if (durationMs <= 0) return const <double>[];
  final List<double> fractions = <double>[];
  double? last;
  for (final VideoChapter chapter in chapters) {
    final double raw = chapter.start.inMilliseconds / durationMs;
    final double fraction = raw.clamp(0.0, 1.0).toDouble();
    if (fraction >= 1.0) continue; // 起点 >= 总时长：轨道最右端，不画。
    if (last != null && fraction == last) continue; // 升序去重。
    fractions.add(fraction);
    last = fraction;
  }
  return fractions;
}

/// seek bar 章节刻度层（TODO-432）：在自己的盒子里把每个章节起点画成一条竖线。
///
/// 本 widget 不负责定位——父级（[VideoHibikiPage] 的 controls Stack）用一个 [Positioned]
/// 把它放到与 seek bar 轨道重合的水平段与竖直带上（左右各内缩 16px 对齐 `seekBarMargin`）。
/// 本 widget 只把传入的 `[0,1)` 比例（[chapterMarkerFractions]）映射到自身宽度画竖线。
///
/// 随 [controller] 重绘：章节列表 / 总时长（媒体头解析）就绪后 controller `notifyListeners`，
/// [AnimatedBuilder] 驱动重绘，刻度即时出现 / 更新（换集同理）。无章节 / 时长未知时画空。
class VideoChapterMarkers extends StatelessWidget {
  const VideoChapterMarkers({
    super.key,
    required this.controller,
    required this.color,
    this.thickness = 2.0,
  });

  final VideoPlayerController controller;

  /// 刻度颜色（页面传控制条强调色派生的高对比色）。
  final Color color;

  /// 刻度线宽（逻辑像素，随界面缩放由页面传入）。
  final double thickness;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (BuildContext _, __) {
        final List<double> fractions = chapterMarkerFractions(
          chapters: controller.chapters,
          durationMs: controller.durationMs ?? 0,
        );
        if (fractions.isEmpty) return const SizedBox.shrink();
        return IgnorePointer(
          // 纯视觉层：不拦指针，seek bar 的拖动 / 点击照常下探到 media_kit。
          child: CustomPaint(
            size: Size.infinite,
            painter: _ChapterMarkerPainter(
              fractions: fractions,
              color: color,
              thickness: thickness,
            ),
          ),
        );
      },
    );
  }
}

/// 把 `[0,1)` 比例映射到画布宽度，逐条画与轨道等高的竖线（TODO-432）。
class _ChapterMarkerPainter extends CustomPainter {
  _ChapterMarkerPainter({
    required this.fractions,
    required this.color,
    required this.thickness,
  });

  final List<double> fractions;
  final Color color;
  final double thickness;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final Paint paint = Paint()
      ..color = color
      ..strokeWidth = thickness
      ..strokeCap = StrokeCap.round;
    final double half = thickness / 2;
    for (final double fraction in fractions) {
      // 把线宽 clamp 进盒子，首尾刻度不被裁掉半条（fraction=0 顶到最左、=1 顶到最右）。
      final double x = (fraction * size.width).clamp(half, size.width - half);
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
  }

  @override
  bool shouldRepaint(_ChapterMarkerPainter old) =>
      old.color != color ||
      old.thickness != thickness ||
      !_sameFractions(old.fractions, fractions);

  static bool _sameFractions(List<double> a, List<double> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
