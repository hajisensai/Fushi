/// OCR 游戏模式的「框选台词区域」对话框：在游戏窗口的一帧截图上拖出台词框
/// （spec `docs/specs/2026-11-22-game-ocr-line-stream-design.md` §2）。
library;

import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/mining/gal_ocr_line_source.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_toggles.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';

/// 读 PNG 头（IHDR）里的宽高；不是 PNG 返回 null。
({int width, int height})? galOcrPngSize(Uint8List png) {
  const List<int> signature = <int>[0x89, 0x50, 0x4E, 0x47];
  if (png.length < 24) return null;
  for (int i = 0; i < signature.length; i++) {
    if (png[i] != signature[i]) return null;
  }
  final ByteData data = ByteData.sublistView(png);
  final int width = data.getUint32(16);
  final int height = data.getUint32(20);
  if (width == 0 || height == 0) return null;
  return (width: width, height: height);
}

/// 框选对话框的结果：台词框（客户区归一化）与「二值化」预处理开关。
typedef GalOcrRegionChoice = ({GalOcrRegion region, bool binarize});

/// 弹出框选对话框：[framePng] 是游戏窗口客户区的一帧截图，[initial] 是初始框，
/// [initialBinarize] 是二值化开关的初值（这个游戏上次的选择）。
/// 确认返回框与开关，取消返回 null；截图读不出尺寸直接返回 null。
Future<GalOcrRegionChoice?> showGalOcrRegionPicker(
  BuildContext context, {
  required Uint8List framePng,
  required GalOcrRegion initial,
  bool initialBinarize = false,
}) {
  final ({int width, int height})? size = galOcrPngSize(framePng);
  if (size == null) return Future<GalOcrRegionChoice?>.value();
  return showAppDialog<GalOcrRegionChoice>(
    context: context,
    builder: (BuildContext dialogContext) => GalOcrRegionDialog(
      framePng: framePng,
      aspectRatio: size.width / size.height,
      initial: initial,
      initialBinarize: initialBinarize,
    ),
  );
}

/// 框选对话框本体（[showGalOcrRegionPicker] 用；公开给 widget 测试）。
@visibleForTesting
class GalOcrRegionDialog extends StatefulWidget {
  const GalOcrRegionDialog({
    required this.framePng,
    required this.aspectRatio,
    required this.initial,
    this.initialBinarize = false,
    super.key,
  });

  final Uint8List framePng;
  final double aspectRatio;
  final GalOcrRegion initial;
  final bool initialBinarize;

  @override
  State<GalOcrRegionDialog> createState() => _GalOcrRegionDialogState();
}

class _GalOcrRegionDialogState extends State<GalOcrRegionDialog> {
  late GalOcrRegion _region = widget.initial;
  late bool _binarize = widget.initialBinarize;

  @override
  Widget build(BuildContext context) {
    return FushiAlertDialog(
      title: Text(t.game_ocr_region_title),
      content: SizedBox(
        width: 640,
        child: FushiEntranceScope(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              FushiStaggeredEntrance(
                index: 0,
                child: Text(t.game_ocr_region_hint),
              ),
              const SizedBox(height: 12),
              FushiStaggeredEntrance(
                index: 1,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 420),
                  child: GalOcrRegionSelector(
                    framePng: widget.framePng,
                    aspectRatio: widget.aspectRatio,
                    region: _region,
                    onChanged: (GalOcrRegion next) =>
                        setState(() => _region = next),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              FushiStaggeredEntrance(
                index: 2,
                child: FushiSwitchListTile(
                  key: const ValueKey<String>('gal-ocr-binarize'),
                  contentPadding: EdgeInsets.zero,
                  value: _binarize,
                  onChanged: (bool value) => setState(() => _binarize = value),
                  title: Text(t.game_ocr_binarize_title),
                  subtitle: Text(t.game_ocr_binarize_hint),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        FushiTextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.dialog_cancel),
        ),
        FushiFilledButton(
          key: const ValueKey<String>('gal-ocr-region-confirm'),
          // 焦点驱动：打开即落在确认上，回车直接按当前框开始识别。
          autofocus: true,
          onPressed: _region.isValid
              ? () => Navigator.of(context).pop<GalOcrRegionChoice>((
                  region: _region,
                  binarize: _binarize,
                ))
              : null,
          child: Text(t.game_ocr_region_confirm),
        ),
      ],
    );
  }
}

/// 截图 + 可拖拽的框。拖动 = 以按下点为一角重新拉框；框外压暗、框内描边。
class GalOcrRegionSelector extends StatefulWidget {
  const GalOcrRegionSelector({
    required this.framePng,
    required this.aspectRatio,
    required this.region,
    required this.onChanged,
    super.key,
  });

  final Uint8List framePng;

  /// 截图宽 / 高。
  final double aspectRatio;
  final GalOcrRegion region;
  final ValueChanged<GalOcrRegion> onChanged;

  @override
  State<GalOcrRegionSelector> createState() => _GalOcrRegionSelectorState();
}

class _GalOcrRegionSelectorState extends State<GalOcrRegionSelector> {
  Offset? _anchor;

  Offset _normalized(Offset local, Size size) => Offset(
    (local.dx / size.width).clamp(0.0, 1.0),
    (local.dy / size.height).clamp(0.0, 1.0),
  );

  void _update(Offset current) {
    final Offset? anchor = _anchor;
    if (anchor == null) return;
    widget.onChanged(
      GalOcrRegion.fromCorners(anchor.dx, anchor.dy, current.dx, current.dy),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return AspectRatio(
      aspectRatio: widget.aspectRatio,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints box) {
          final Size size = box.biggest;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (DragStartDetails d) {
              _anchor = _normalized(d.localPosition, size);
            },
            onPanUpdate: (DragUpdateDetails d) =>
                _update(_normalized(d.localPosition, size)),
            onPanEnd: (_) => _anchor = null,
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                Image.memory(
                  widget.framePng,
                  fit: BoxFit.fill,
                  gaplessPlayback: true,
                ),
                TweenAnimationBuilder<Rect?>(
                  // 拖动时跟手（时长极短）；初始框与外部改框时有一段过渡。
                  tween: RectTween(
                    end: Rect.fromLTWH(
                      widget.region.left,
                      widget.region.top,
                      widget.region.width,
                      widget.region.height,
                    ),
                  ),
                  duration: _anchor == null
                      ? context.fushiMotion.effectsDefault.duration
                      : Duration.zero,
                  curve: context.fushiMotion.effectsDefault.curve,
                  builder: (BuildContext context, Rect? rect, Widget? _) =>
                      CustomPaint(
                        painter: _RegionPainter(
                          rect: rect ?? Rect.zero,
                          scrim: cs.scrim.withValues(alpha: 0.45),
                          stroke: cs.primary,
                        ),
                      ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _RegionPainter extends CustomPainter {
  const _RegionPainter({
    required this.rect,
    required this.scrim,
    required this.stroke,
  });

  /// 归一化框。
  final Rect rect;
  final Color scrim;
  final Color stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect box = Rect.fromLTRB(
      rect.left * size.width,
      rect.top * size.height,
      rect.right * size.width,
      rect.bottom * size.height,
    );
    final Path outside = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRect(box);
    canvas.drawPath(outside, Paint()..color = scrim);
    canvas.drawRect(
      box,
      Paint()
        ..color = stroke
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_RegionPainter old) =>
      old.rect != rect || old.scrim != scrim || old.stroke != stroke;
}
