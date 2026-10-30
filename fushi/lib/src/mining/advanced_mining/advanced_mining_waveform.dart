import 'dart:async';
import 'dart:math' as math;

import 'package:fushi/src/media/video/subtitle_waveform_painter.dart'
    show timeToX, waveformBucketRect;
import 'package:fushi/src/mining/advanced_mining/advanced_mining_capabilities.dart';
import 'package:fushi/src/mining/advanced_mining/advanced_mining_controller.dart';
import 'package:fushi/utils.dart';
import 'package:material_ui/material_ui.dart';

/// 高级制卡「句子音频」的可拖波形选区：画区间周围一段音频的能量波形，用户直接拖起点 /
/// 终点 / 整段，结果经 [AdvancedMiningController.setAudioWindow] 并进与微调按钮同一对
/// 偏移，所以试听、区间条、写卡都不用另算。
///
/// 拖动几何（命中哪根边、拖动后的区间）抽成纯函数（[pickWaveformDragMode] /
/// [applyWaveformDrag]），不依赖 Flutter，可直接单测。

/// 拖动模式：起点 / 终点 / 整段平移。
enum WaveformDragMode { start, end, move }

/// 波形两侧各多画多少毫秒（相对原区间，不是相对当前区间）：给「想把区间拉长」留出
/// 能拖到的余地。硬字幕默认窗口只有几秒，左右各留 8 秒够扩到一整句。
const int kAdvancedMiningWaveformMarginMs = 8000;

/// 波形柱数。20ms 一帧的包络压到这个数量：对话框宽度下每根柱 2–4 像素，语音节奏与句间
/// 静音清楚，又不至于逐帧画几千根。
const int kAdvancedMiningWaveformBuckets = 240;

/// **纯函数**：按下点 [x] 命中哪种拖动。
///
/// 起点 / 终点手柄各有 [edgeTolerancePx] 的命中范围（两根都够得着取近的）；落在选区
/// 内部 = 整段平移；落在选区外 = 就近拖一根边过去（比点了没反应直观）。
WaveformDragMode pickWaveformDragMode({
  required double x,
  required double startX,
  required double endX,
  double edgeTolerancePx = 16,
}) {
  final double toStart = (x - startX).abs();
  final double toEnd = (x - endX).abs();
  if (toStart <= edgeTolerancePx && toStart <= toEnd) {
    return WaveformDragMode.start;
  }
  if (toEnd <= edgeTolerancePx) return WaveformDragMode.end;
  if (x > startX && x < endX) return WaveformDragMode.move;
  return x < startX ? WaveformDragMode.start : WaveformDragMode.end;
}

/// **纯函数**：指针在 [pointerMs]（波形域毫秒）时，[mode] 下的新区间。
///
/// * [WaveformDragMode.start] / [WaveformDragMode.end]：只动那一根，夹在波形域内且与另一根
///   至少隔 [minWindowMs]。
/// * [WaveformDragMode.move]：保持时长平移，[grabOffsetMs] 是按下点相对区间起点的偏移
///   （选区跟手不跳），夹在波形域内。
({int startMs, int endMs}) applyWaveformDrag({
  required WaveformDragMode mode,
  required int pointerMs,
  required int grabOffsetMs,
  required int startMs,
  required int endMs,
  required int domainStartMs,
  required int domainEndMs,
  int minWindowMs = AdvancedMiningController.kMinAudioWindowMs,
}) {
  switch (mode) {
    case WaveformDragMode.start:
      final int hi = math.max(domainStartMs, endMs - minWindowMs);
      return (startMs: pointerMs.clamp(domainStartMs, hi), endMs: endMs);
    case WaveformDragMode.end:
      final int lo = math.min(domainEndMs, startMs + minWindowMs);
      return (startMs: startMs, endMs: pointerMs.clamp(lo, domainEndMs));
    case WaveformDragMode.move:
      final int duration = endMs - startMs;
      final int hi = math.max(domainStartMs, domainEndMs - duration);
      final int newStart = (pointerMs - grabOffsetMs).clamp(domainStartMs, hi);
      return (startMs: newStart, endMs: newStart + duration);
  }
}

/// 像素 x → 波形域毫秒（线性，夹在域内）。宽度或域非法返回域起点。
int waveformPixelToMs({
  required double x,
  required double width,
  required int domainStartMs,
  required int domainEndMs,
}) {
  final int span = domainEndMs - domainStartMs;
  if (width <= 0 || span <= 0) return domainStartMs;
  final int ms = domainStartMs + (x / width * span).round();
  return ms.clamp(domainStartMs, domainEndMs);
}

/// 可拖波形选区。波形还在抽 / 抽不出时显示 [fallback]（区间条），不留空白也不报错。
class AdvancedMiningWaveformSelector extends StatefulWidget {
  const AdvancedMiningWaveformSelector({
    super.key,
    required this.controller,
    required this.fallback,
    this.height = 64,
  });

  final AdvancedMiningController controller;

  /// 没有波形可画时代替它显示的区间条。
  final Widget fallback;
  final double height;

  @override
  State<AdvancedMiningWaveformSelector> createState() =>
      _AdvancedMiningWaveformSelectorState();
}

class _AdvancedMiningWaveformSelectorState
    extends State<AdvancedMiningWaveformSelector> {
  static const double _kEdgeHitTolerancePx = 16;

  late final int _domainStartMs;
  late final int _domainEndMs;
  AdvancedMiningWaveform? _wave;

  WaveformDragMode? _dragMode;
  int _grabOffsetMs = 0;
  double _width = 0;

  @override
  void initState() {
    super.initState();
    final AdvancedMiningController c = widget.controller;
    final AdvancedMiningAudioWindow w = c.audioWindow!;
    // 域跟着「未偏移的原区间」走、不跟着当前区间走：拖动时波形不会跟着滚，起止标记才
    // 真的在波形上移动。
    final int baseStart = w.startMs - c.audioStartDeltaMs;
    final int baseEnd = w.endMs - c.audioEndDeltaMs;
    _domainStartMs = math.max(0, baseStart - kAdvancedMiningWaveformMarginMs);
    _domainEndMs = baseEnd + kAdvancedMiningWaveformMarginMs;
    unawaited(_load());
  }

  Future<void> _load() async {
    final Future<AdvancedMiningWaveform?> Function(int, int)? loader =
        widget.controller.audioSection?.loadWaveform;
    if (loader == null) return;
    AdvancedMiningWaveform? wave;
    try {
      wave = await loader(_domainStartMs, _domainEndMs);
    } catch (_) {
      wave = null;
    }
    if (!mounted) return;
    if (wave != null && wave.isUsable) setState(() => _wave = wave);
  }

  void _apply(double x) {
    final AdvancedMiningAudioWindow? w = widget.controller.audioWindow;
    final WaveformDragMode? mode = _dragMode;
    if (w == null || mode == null) return;
    final ({int startMs, int endMs}) next = applyWaveformDrag(
      mode: mode,
      pointerMs: waveformPixelToMs(
        x: x,
        width: _width,
        domainStartMs: _domainStartMs,
        domainEndMs: _domainEndMs,
      ),
      grabOffsetMs: _grabOffsetMs,
      startMs: w.startMs,
      endMs: w.endMs,
      domainStartMs: _domainStartMs,
      domainEndMs: _domainEndMs,
    );
    widget.controller.setAudioWindow(startMs: next.startMs, endMs: next.endMs);
  }

  void _onDragStart(DragStartDetails details) {
    final AdvancedMiningAudioWindow? w = widget.controller.audioWindow;
    if (w == null || _width <= 0) return;
    final double x = details.localPosition.dx;
    final double startX = timeToX(
      timeMs: w.startMs,
      windowStartMs: _domainStartMs,
      windowEndMs: _domainEndMs,
      width: _width,
    );
    final double endX = timeToX(
      timeMs: w.endMs,
      windowStartMs: _domainStartMs,
      windowEndMs: _domainEndMs,
      width: _width,
    );
    _dragMode = pickWaveformDragMode(
      x: x,
      startX: startX,
      endX: endX,
      edgeTolerancePx: _kEdgeHitTolerancePx,
    );
    _grabOffsetMs =
        waveformPixelToMs(
          x: x,
          width: _width,
          domainStartMs: _domainStartMs,
          domainEndMs: _domainEndMs,
        ) -
        w.startMs;
    _apply(x);
  }

  @override
  Widget build(BuildContext context) {
    final AdvancedMiningWaveform? wave = _wave;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: widget.height,
      child: AnimatedSwitcher(
        duration: fushiMotionDuration(context, FushiMotion.short),
        switchInCurve: FushiMotion.enter,
        switchOutCurve: FushiMotion.exit,
        child: wave == null
            ? KeyedSubtree(
                key: const ValueKey<String>('range-bar'),
                child: widget.fallback,
              )
            : ListenableBuilder(
                key: const ValueKey<String>('waveform'),
                listenable: widget.controller,
                builder: (BuildContext context, Widget? _) {
                  final AdvancedMiningAudioWindow? w =
                      widget.controller.audioWindow;
                  return LayoutBuilder(
                    builder: (BuildContext context, BoxConstraints box) {
                      _width = box.maxWidth;
                      return GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onHorizontalDragStart: widget.controller.locked
                            ? null
                            : _onDragStart,
                        onHorizontalDragUpdate: widget.controller.locked
                            ? null
                            : (DragUpdateDetails d) =>
                                  _apply(d.localPosition.dx),
                        onHorizontalDragEnd: (_) => _dragMode = null,
                        onHorizontalDragCancel: () => _dragMode = null,
                        child: CustomPaint(
                          size: Size(box.maxWidth, widget.height),
                          painter: _WaveformPainter(
                            buckets: wave.buckets,
                            domainStartMs: _domainStartMs,
                            domainEndMs: _domainEndMs,
                            startMs: w?.startMs ?? _domainStartMs,
                            endMs: w?.endMs ?? _domainStartMs,
                            bar: scheme.outlineVariant,
                            barSelected: scheme.primary,
                            fill: scheme.primary.withValues(alpha: 0.12),
                            handle: scheme.primary,
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
      ),
    );
  }
}

class _WaveformPainter extends CustomPainter {
  const _WaveformPainter({
    required this.buckets,
    required this.domainStartMs,
    required this.domainEndMs,
    required this.startMs,
    required this.endMs,
    required this.bar,
    required this.barSelected,
    required this.fill,
    required this.handle,
  });

  final List<double> buckets;
  final int domainStartMs;
  final int domainEndMs;
  final int startMs;
  final int endMs;
  final Color bar;
  final Color barSelected;
  final Color fill;
  final Color handle;

  @override
  void paint(Canvas canvas, Size size) {
    final int n = buckets.length;
    if (n == 0 || size.width <= 0 || size.height <= 0) return;
    final double centerY = size.height / 2;
    final int span = domainEndMs - domainStartMs;
    final Paint paint = Paint();
    for (int i = 0; i < n; i++) {
      Rect rect = waveformBucketRect(
        bucketIndex: i,
        bucketCount: n,
        value: buckets[i],
        size: size,
        centerY: centerY,
        verticalPadding: 4,
      );
      if (rect == Rect.zero) continue;
      // 静音也留一条细线，波形才连得起来、选区里也看得出有柱。
      if (rect.height < 2) {
        rect = Rect.fromCenter(
          center: rect.center,
          width: rect.width,
          height: 2,
        );
      }
      final int centerMs = domainStartMs + ((i + 0.5) / n * span).round();
      final bool selected = centerMs >= startMs && centerMs <= endMs;
      canvas.drawRect(rect, paint..color = selected ? barSelected : bar);
    }
    final double x0 = timeToX(
      timeMs: startMs,
      windowStartMs: domainStartMs,
      windowEndMs: domainEndMs,
      width: size.width,
    );
    final double x1 = timeToX(
      timeMs: endMs,
      windowStartMs: domainStartMs,
      windowEndMs: domainEndMs,
      width: size.width,
    );
    if (x0.isNaN || x1.isNaN) return;
    canvas.drawRect(
      Rect.fromLTRB(x0, 0, math.max(x0, x1), size.height),
      paint..color = fill,
    );
    final Paint line = Paint()
      ..color = handle
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(x0, 2), Offset(x0, size.height - 2), line);
    canvas.drawLine(Offset(x1, 2), Offset(x1, size.height - 2), line);
    // 手柄的抓取点：圆头，提示这两根线能拖。
    canvas.drawCircle(Offset(x0, centerY), 6, paint..color = handle);
    canvas.drawCircle(Offset(x1, centerY), 6, paint..color = handle);
  }

  @override
  bool shouldRepaint(_WaveformPainter old) =>
      old.buckets != buckets ||
      old.domainStartMs != domainStartMs ||
      old.domainEndMs != domainEndMs ||
      old.startMs != startMs ||
      old.endMs != endMs ||
      old.bar != bar ||
      old.barSelected != barSelected ||
      old.fill != fill ||
      old.handle != handle;
}
