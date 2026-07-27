import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:hibiki/src/media/video/audio_energy_probe.dart'
    show downsampleEnergyEnvelope;
import 'package:hibiki/src/media/video/subtitle_waveform_painter.dart'
    show SubtitleWaveformPainter;
import 'package:hibiki/src/mining/galgame_audio_encode.dart' show pcmDurationMs;
import 'package:hibiki/src/mining/galgame_audio_source.dart' show GalAudioSlice;
import 'package:hibiki/src/mining/galgame_waveform.dart'
    show kGalWaveformWindowMs, pcmToEnergyEnvelope;
import 'package:hibiki/src/mining/galgame_waveform_select.dart';
import 'package:hibiki/utils.dart';

/// galgame 一键制卡（docs/specs/galgame-mining）波形选区对话框。
///
/// 画 [GalAudioSlice] 的波形（复用视频对轴的 [SubtitleWaveformPainter] 渲染层），
/// VAD（[defaultVadRange]）给默认框，用户拖左右边界或整体拖动微调，「确定」返回
/// 选区、「取消」返回 null。几何换算全部走 `galgame_waveform_select.dart` 的纯函数。

/// 弹出波形选区对话框：画 [slice] 的波形、用户拖一个范围、返回选区；取消返回 null。
Future<GalWaveformRange?> showGalWaveformSelectDialog(
  BuildContext context, {
  required GalAudioSlice slice,
}) {
  return showAppDialog<GalWaveformRange>(
    context: context,
    builder: (BuildContext ctx) => _GalWaveformSelectDialog(slice: slice),
  );
}

/// 拖动模式：左边界 / 右边界 / 整体平移。
enum _GalDragMode { left, right, move }

class _GalWaveformSelectDialog extends StatefulWidget {
  const _GalWaveformSelectDialog({required this.slice});

  final GalAudioSlice slice;

  @override
  State<_GalWaveformSelectDialog> createState() =>
      _GalWaveformSelectDialogState();
}

class _GalWaveformSelectDialogState extends State<_GalWaveformSelectDialog> {
  /// 边界手柄的命中容差（逻辑像素）。
  static const double _kEdgeHitTolerancePx = 16.0;

  late final int _totalMs;
  late final List<double> _dbFrames;
  late GalWaveformRange _range;

  /// 波形显示区最近一次布局宽度（拖动换算用）。
  double _lastWidth = 0.0;

  /// 降采样桶缓存：宽度不变时不重跑 O(n) 降采样。
  int _cachedBucketCount = -1;
  List<double> _cachedBuckets = const <double>[];

  /// 当前拖动模式；null = 未在拖。
  _GalDragMode? _dragMode;

  /// move 模式下按下点相对选区起点的毫秒偏移（保持选区跟手不跳）。
  int _moveGrabOffsetMs = 0;

  @override
  void initState() {
    super.initState();
    _totalMs =
        pcmDurationMs(widget.slice.pcm.length, widget.slice.format.byteRate);
    _dbFrames = pcmToEnergyEnvelope(widget.slice.pcm, widget.slice.format);
    _range = defaultVadRange(
      _dbFrames,
      windowMs: kGalWaveformWindowMs,
      totalDurationMs: _totalMs,
    );
  }

  /// 取 [targetBuckets] 个 0..1 波形桶（带缓存）。
  List<double> _bucketsFor(int targetBuckets) {
    if (targetBuckets == _cachedBucketCount) {
      return _cachedBuckets;
    }
    _cachedBucketCount = targetBuckets;
    _cachedBuckets = downsampleEnergyEnvelope(_dbFrames, targetBuckets);
    return _cachedBuckets;
  }

  void _onDragStart(DragStartDetails details) {
    if (_lastWidth <= 0 || _totalMs <= 0) {
      return;
    }
    final double x = details.localPosition.dx;
    final double startX = msToPixel(_range.startMs, _lastWidth, _totalMs);
    final double endX = msToPixel(_range.endMs, _lastWidth, _totalMs);
    if ((x - startX).abs() <= _kEdgeHitTolerancePx &&
        (x - startX).abs() <= (x - endX).abs()) {
      _dragMode = _GalDragMode.left;
    } else if ((x - endX).abs() <= _kEdgeHitTolerancePx) {
      _dragMode = _GalDragMode.right;
    } else if (x > startX && x < endX) {
      _dragMode = _GalDragMode.move;
      _moveGrabOffsetMs = pixelToMs(x, _lastWidth, _totalMs) - _range.startMs;
    } else {
      // 选区外按下：就近拖一条边界过去（比无响应直观）。
      _dragMode = x < startX ? _GalDragMode.left : _GalDragMode.right;
      _applyDrag(x);
    }
  }

  void _onDragUpdate(DragUpdateDetails details) {
    _applyDrag(details.localPosition.dx);
  }

  void _onDragEnd(DragEndDetails details) {
    _dragMode = null;
  }

  /// 按当前 [_dragMode] 把指针 x 换算成毫秒并更新选区（各方向 clamp）。
  void _applyDrag(double x) {
    final _GalDragMode? mode = _dragMode;
    if (mode == null || _lastWidth <= 0 || _totalMs <= 0) {
      return;
    }
    final int ms = pixelToMs(x, _lastWidth, _totalMs);
    setState(() {
      switch (mode) {
        case _GalDragMode.left:
          _range = GalWaveformRange(
            startMs: math.min(ms, _range.endMs),
            endMs: _range.endMs,
          );
        case _GalDragMode.right:
          _range = GalWaveformRange(
            startMs: _range.startMs,
            endMs: math.max(ms, _range.startMs),
          );
        case _GalDragMode.move:
          final int duration = _range.durationMs;
          final int start =
              (ms - _moveGrabOffsetMs).clamp(0, _totalMs - duration);
          _range = GalWaveformRange(startMs: start, endMs: start + duration);
      }
    });
  }

  /// 毫秒 → 「1.23s」样式的时长文案。
  String _fmtSeconds(int ms) => '${(ms / 1000).toStringAsFixed(2)}s';

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    final String rangeLabel = t.game_waveform_range_label(
      start: _fmtSeconds(_range.startMs),
      end: _fmtSeconds(_range.endMs),
      duration: _fmtSeconds(_range.durationMs),
      total: _fmtSeconds(_totalMs),
    );
    return HibikiDialogFrame(
      maxWidth: 520,
      scrollable: false,
      child: HibikiModalSheetFrame(
        title: t.game_waveform_select_title,
        scrollable: true,
        bodyPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          0,
          tokens.spacing.card,
          tokens.spacing.gap,
        ),
        footerPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          tokens.spacing.gap,
          tokens.spacing.card,
          tokens.spacing.card,
        ),
        body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            SizedBox(
              height: 140,
              child: ClipRRect(
                borderRadius: tokens.radii.controlRadius,
                child: LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints constraints) {
                    final double width = constraints.maxWidth.isFinite
                        ? constraints.maxWidth
                        : 480.0;
                    _lastWidth = width;
                    final int targetBuckets = math.max(1, width ~/ 2);
                    final List<double> buckets = _bucketsFor(targetBuckets);
                    return GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onHorizontalDragStart: _onDragStart,
                      onHorizontalDragUpdate: _onDragUpdate,
                      onHorizontalDragEnd: _onDragEnd,
                      child: Stack(
                        fit: StackFit.expand,
                        children: <Widget>[
                          RepaintBoundary(
                            child: CustomPaint(
                              painter: SubtitleWaveformPainter(
                                buckets: buckets,
                                windowStartMs: 0,
                                windowEndMs: _totalMs,
                                cueBoundariesMs: const <int>[],
                                previewDelayMs: 0,
                                currentPositionMs: 0,
                                waveColor: cs.primary.withValues(alpha: 0.55),
                                cueLineColor: cs.secondary,
                                playheadColor: cs.tertiary,
                                centerLineColor: cs.outlineVariant,
                              ),
                            ),
                          ),
                          CustomPaint(
                            painter: _GalSelectionOverlayPainter(
                              startMs: _range.startMs,
                              endMs: _range.endMs,
                              totalMs: _totalMs,
                              fillColor: cs.primary.withValues(alpha: 0.16),
                              edgeColor: cs.primary,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
            SizedBox(height: tokens.spacing.gap),
            Text(
              rangeLabel,
              style: tokens.type.listSubtitle,
              textAlign: TextAlign.center,
            ),
          ],
        ),
        footer: Wrap(
          alignment: WrapAlignment.end,
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: <Widget>[
            adaptiveDialogAction(
              context: context,
              onPressed: () => Navigator.of(context).pop(),
              child: Text(t.dialog_cancel),
            ),
            adaptiveDialogAction(
              context: context,
              isDefaultAction: true,
              onPressed: () => Navigator.of(context).pop(_range),
              child: Text(t.dialog_ok),
            ),
          ],
        ),
      ),
    );
  }
}

/// 选区遮罩 painter：选区高亮矩形 + 左右两条边界线（几何走 [msToPixel] 纯函数）。
class _GalSelectionOverlayPainter extends CustomPainter {
  _GalSelectionOverlayPainter({
    required this.startMs,
    required this.endMs,
    required this.totalMs,
    required this.fillColor,
    required this.edgeColor,
  });

  final int startMs;
  final int endMs;
  final int totalMs;
  final Color fillColor;
  final Color edgeColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0 || totalMs <= 0) {
      return;
    }
    final double x1 = msToPixel(startMs, size.width, totalMs);
    final double x2 = msToPixel(endMs, size.width, totalMs);

    // 选区高亮。
    final Paint fill = Paint()..color = fillColor;
    canvas.drawRect(Rect.fromLTRB(x1, 0, x2, size.height), fill);

    // 左右边界线。
    final Paint edge = Paint()
      ..color = edgeColor
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(x1, 0), Offset(x1, size.height), edge);
    canvas.drawLine(Offset(x2, 0), Offset(x2, size.height), edge);

    // 边界中部小手柄（提示可拖）。
    final Paint grip = Paint()..color = edgeColor;
    const double gripW = 6.0;
    const double gripH = 24.0;
    final double gripTop = (size.height - gripH) / 2;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(x1 - gripW / 2, gripTop, gripW, gripH),
        const Radius.circular(3),
      ),
      grip,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(x2 - gripW / 2, gripTop, gripW, gripH),
        const Radius.circular(3),
      ),
      grip,
    );
  }

  @override
  bool shouldRepaint(_GalSelectionOverlayPainter old) =>
      old.startMs != startMs ||
      old.endMs != endMs ||
      old.totalMs != totalMs ||
      old.fillColor != fillColor ||
      old.edgeColor != edgeColor;
}
