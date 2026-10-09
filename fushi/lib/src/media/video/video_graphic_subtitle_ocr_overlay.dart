/// 图形字幕查词覆盖层：暂停时截下当前帧（含 libmpv 自绘的字幕位图）做 OCR，
/// 在识别出的每个字上方铺一个透明可点区域，点字即查词。
///
/// 识别与 AI 重读见 `graphic_subtitle_ocr.dart`；本层只负责「何时识别」与「摆在哪」。
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/video/graphic_subtitle_ocr.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';

/// 识别触发的防抖：逐帧步进 / 连续 seek 时只识别停下来的那一帧。
const Duration kGraphicSubtitleOcrSettleDelay = Duration(milliseconds: 250);

/// 图形字幕 OCR 查词覆盖层。尺寸须与视频控件一致（挂在 controls 层里）。
class VideoGraphicSubtitleOcrOverlay extends StatefulWidget {
  const VideoGraphicSubtitleOcrOverlay({
    required this.controller,
    required this.fit,
    required this.prepare,
    required this.onCharTap,
    this.onUnavailable,
    this.onError,
    this.captureFrame,
    super.key,
  });

  final VideoPlayerController controller;

  /// 画面在控件里的摆放方式（与 Video 的 fit 同源）。
  final BoxFit fit;

  final GraphicSubtitleOcrPrepare prepare;

  /// 点中一个字：整句、句内字素下标、字在**全局**坐标系下的矩形。
  final void Function(String sentence, int graphemeIndex, Rect globalRect)
  onCharTap;

  /// 引擎不可用（每个会话只报一次）。
  final void Function(GraphicSubtitleOcrUnavailableReason reason)?
  onUnavailable;

  /// 截帧 / 识别 / AI 重读出错。
  final void Function(Object error, StackTrace stack)? onError;

  /// 截帧；默认走 [VideoPlayerController.captureFrameWithSubtitles]（测试注入用）。
  final Future<Uint8List?> Function()? captureFrame;

  @override
  State<VideoGraphicSubtitleOcrOverlay> createState() =>
      _VideoGraphicSubtitleOcrOverlayState();
}

/// 识别时刻的身份：位置与字幕轨都没变，画面上的字幕就没变。
typedef _FrameKey = ({int positionMs, String? trackId});

class _VideoGraphicSubtitleOcrOverlayState
    extends State<VideoGraphicSubtitleOcrOverlay> {
  GraphicSubtitleOcrSession? _session;
  GraphicSubtitleOcrFrame? _frame;
  _FrameKey? _key;
  Timer? _settle;
  int _generation = 0;
  bool _unavailableReported = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
    _onControllerChanged();
  }

  @override
  void didUpdateWidget(VideoGraphicSubtitleOcrOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.controller, widget.controller)) return;
    oldWidget.controller.removeListener(_onControllerChanged);
    widget.controller.addListener(_onControllerChanged);
    _reset();
    _onControllerChanged();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _settle?.cancel();
    _generation++;
    unawaited(_session?.close());
    _session = null;
    super.dispose();
  }

  _FrameKey? _currentKey() {
    final VideoPlayerController c = widget.controller;
    if (c.isPlaying || !c.isPlayerRenderedSubtitleActive || !c.hasFirstFrame) {
      return null;
    }
    final int? position = c.positionMs;
    if (position == null) return null;
    return (positionMs: position, trackId: c.activeSubtitleTrackId);
  }

  void _onControllerChanged() {
    final _FrameKey? key = _currentKey();
    if (key == _key) return;
    _reset();
    _key = key;
    if (key == null) return;
    _settle = Timer(kGraphicSubtitleOcrSettleDelay, _recognize);
  }

  /// 丢弃当前结果与在途识别（播放 / seek / 换轨）。
  void _reset() {
    _settle?.cancel();
    _settle = null;
    _generation++;
    if (_frame != null && mounted) setState(() => _frame = null);
    _frame = null;
  }

  Future<void> _recognize() async {
    final int generation = _generation;
    bool stale() => !mounted || generation != _generation;
    try {
      final Uint8List? bytes =
          await (widget.captureFrame ??
              widget.controller.captureFrameWithSubtitles)();
      if (bytes == null || stale()) return;
      final GraphicSubtitleOcrSession session = _session ??=
          GraphicSubtitleOcrSession(prepare: widget.prepare);
      final GraphicSubtitleOcrFrame? frame = await session.recognize(
        bytes,
        onRefined: (GraphicSubtitleOcrFrame refined) {
          if (!stale()) setState(() => _frame = refined);
        },
        onRefineError: (Object error, StackTrace stack) {
          if (!stale()) widget.onError?.call(error, stack);
        },
      );
      if (frame == null || stale()) return;
      setState(() => _frame = frame);
    } on GraphicSubtitleOcrUnavailable catch (e) {
      if (_unavailableReported || !mounted) return;
      _unavailableReported = true;
      widget.onUnavailable?.call(e.reason);
    } catch (error, stack) {
      if (mounted) widget.onError?.call(error, stack);
    }
  }

  @override
  Widget build(BuildContext context) {
    final GraphicSubtitleOcrFrame? frame = _frame;
    if (frame == null || frame.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final Size viewSize = constraints.biggest;
        final int? dw = widget.controller.videoWidth;
        final int? dh = widget.controller.videoHeight;
        final Size displaySize = dw != null && dh != null && dw > 0 && dh > 0
            ? Size(dw.toDouble(), dh.toDouble())
            : frame.imageSize;
        return Stack(
          children: <Widget>[
            for (final GraphicSubtitleOcrChar char in frame.chars)
              Positioned.fromRect(
                rect: graphicSubtitleImageRectToView(
                  imageRect: char.rect,
                  imageSize: frame.imageSize,
                  displaySize: displaySize,
                  viewSize: viewSize,
                  fit: widget.fit,
                ),
                child: _CharHitBox(char: char, onTap: widget.onCharTap),
              ),
          ],
        );
      },
    );
  }
}

class _CharHitBox extends StatelessWidget {
  const _CharHitBox({required this.char, required this.onTap});

  final GraphicSubtitleOcrChar char;
  final void Function(String sentence, int graphemeIndex, Rect globalRect)
  onTap;

  void _handleTap(BuildContext context) {
    final RenderBox? box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final Offset topLeft = box.localToGlobal(Offset.zero);
    final Offset bottomRight = box.localToGlobal(
      box.size.bottomRight(Offset.zero),
    );
    onTap(
      char.sentence,
      char.graphemeIndex,
      Rect.fromPoints(topLeft, bottomRight),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: Builder(
        builder: (BuildContext context) => GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _handleTap(context),
        ),
      ),
    );
  }
}
