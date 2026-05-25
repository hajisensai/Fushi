import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki/models.dart';

/// Settings that are persisted for the blur widget used in the player.
class BlurOptions {
  BlurOptions({
    required this.width,
    required this.height,
    required this.left,
    required this.top,
    required this.color,
    required this.blurRadius,
    required this.visible,
  });

  double width;
  double height;
  double left;
  double top;
  Color color;
  double blurRadius;
  bool visible;
}

Rect defaultBlurRect(Size screen) {
  const double defaultSize = 150;
  return Rect.fromLTWH(
    screen.width / 2 - defaultSize / 2,
    screen.height / 4 - defaultSize / 2,
    defaultSize,
    defaultSize,
  );
}

class _BlurGeometry {
  _BlurGeometry({
    required this.width,
    required this.height,
    required this.top,
    required this.left,
  });

  final double width;
  final double height;
  final double top;
  final double left;

  _BlurGeometry copyWith({
    double? width,
    double? height,
    double? top,
    double? left,
  }) =>
      _BlurGeometry(
        width: width ?? this.width,
        height: height ?? this.height,
        top: top ?? this.top,
        left: left ?? this.left,
      );
}

class ResizeableWidget extends ConsumerStatefulWidget {
  const ResizeableWidget({
    required this.notifier,
    super.key,
  });

  final ValueNotifier<BlurOptions> notifier;

  @override
  ConsumerState<ResizeableWidget> createState() => _ResizeableWidgetState();
}

class _ResizeableWidgetState extends ConsumerState<ResizeableWidget> {
  late final ValueNotifier<_BlurGeometry> _geo;
  final ValueNotifier<bool> _visibleBallsNotifier = ValueNotifier<bool>(false);
  Timer? _hideTimer;

  static const double ballDiameter = 28;

  @override
  void initState() {
    super.initState();
    final o = widget.notifier.value;
    _geo = ValueNotifier(_BlurGeometry(
      width: o.width,
      height: o.height,
      top: o.top,
      left: o.left,
    ));
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _geo.dispose();
    _visibleBallsNotifier.dispose();
    super.dispose();
  }

  void _updateGeo({
    double? width,
    double? height,
    double? top,
    double? left,
  }) {
    final g = _geo.value;
    _geo.value = g.copyWith(
      width: width != null ? (width > 0 ? width : 0) : null,
      height: height != null ? (height > 0 ? height : 0) : null,
      top: top,
      left: left,
    );
  }

  void _showAndHide() {
    _hideTimer?.cancel();
    _visibleBallsNotifier.value = true;
    _hideTimer = Timer(const Duration(seconds: 3), () {
      _visibleBallsNotifier.value = false;
      _persistGeometry();
    });
  }

  void _persistGeometry() {
    final AppModel appModel = ref.read(appProvider);
    final g = _geo.value;
    final BlurOptions blurWidgetOptions = appModel.blurOptions;
    blurWidgetOptions.height = g.height;
    blurWidgetOptions.width = g.width;
    blurWidgetOptions.top = g.top;
    blurWidgetOptions.left = g.left;

    widget.notifier.value = blurWidgetOptions;
    appModel.setBlurOptions(blurWidgetOptions);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<BlurOptions>(
      valueListenable: widget.notifier,
      builder: (context, options, _) {
        if (!options.visible) return const SizedBox.shrink();

        if (options.top == -1 || options.left == -1) {
          final Rect defaultRect = defaultBlurRect(MediaQuery.sizeOf(context));
          _geo.value = _BlurGeometry(
            height: defaultRect.height,
            width: defaultRect.width,
            top: defaultRect.top,
            left: defaultRect.left,
          );
        }

        final Color color = options.color;
        final double blurRadius = options.blurRadius;

        return ValueListenableBuilder<_BlurGeometry>(
          valueListenable: _geo,
          builder: (context, g, _) {
            return Stack(
              children: <Widget>[
                Positioned(
                  top: g.top,
                  left: g.left,
                  child: GestureDetector(
                    onTap: _showAndHide,
                    child: ClipRect(
                      child: BackdropFilter(
                        filter: ImageFilter.blur(
                          sigmaX: blurRadius,
                          sigmaY: blurRadius,
                        ),
                        child: Container(
                          height: g.height,
                          width: g.width,
                          color: color,
                        ),
                      ),
                    ),
                  ),
                ),
                // top left
                Positioned(
                  top: g.top - ballDiameter / 2,
                  left: g.left - ballDiameter / 2,
                  child: ManipulatingBall(
                    notifier: _visibleBallsNotifier,
                    showAndHide: _showAndHide,
                    onDrag: (dx, dy) {
                      final mid = (dx + dy) / 2;
                      final og = _geo.value;
                      _updateGeo(
                        height: og.height - 2 * mid,
                        width: og.width - 2 * mid,
                        top: og.top + mid,
                        left: og.left + mid,
                      );
                    },
                  ),
                ),
                // top middle
                Positioned(
                  top: g.top - ballDiameter / 2,
                  left: g.left + g.width / 2 - ballDiameter / 2,
                  child: ManipulatingBall(
                    notifier: _visibleBallsNotifier,
                    showAndHide: _showAndHide,
                    onDrag: (dx, dy) {
                      final og = _geo.value;
                      _updateGeo(
                        height: og.height - dy,
                        top: og.top + dy,
                      );
                    },
                  ),
                ),
                // top right
                Positioned(
                  top: g.top - ballDiameter / 2,
                  left: g.left + g.width - ballDiameter / 2,
                  child: ManipulatingBall(
                    notifier: _visibleBallsNotifier,
                    showAndHide: _showAndHide,
                    onDrag: (dx, dy) {
                      final mid = (dx + (dy * -1)) / 2;
                      final og = _geo.value;
                      _updateGeo(
                        height: og.height + 2 * mid,
                        width: og.width + 2 * mid,
                        top: og.top - mid,
                        left: og.left - mid,
                      );
                    },
                  ),
                ),
                // center right
                Positioned(
                  top: g.top + g.height / 2 - ballDiameter / 2,
                  left: g.left + g.width - ballDiameter / 2,
                  child: ManipulatingBall(
                    notifier: _visibleBallsNotifier,
                    showAndHide: _showAndHide,
                    onDrag: (dx, dy) {
                      final og = _geo.value;
                      _updateGeo(width: og.width + dx);
                    },
                  ),
                ),
                // bottom right
                Positioned(
                  top: g.top + g.height - ballDiameter / 2,
                  left: g.left + g.width - ballDiameter / 2,
                  child: ManipulatingBall(
                    notifier: _visibleBallsNotifier,
                    showAndHide: _showAndHide,
                    onDrag: (dx, dy) {
                      final mid = (dx + dy) / 2;
                      final og = _geo.value;
                      _updateGeo(
                        height: og.height + 2 * mid,
                        width: og.width + 2 * mid,
                        top: og.top - mid,
                        left: og.left - mid,
                      );
                    },
                  ),
                ),
                // bottom center
                Positioned(
                  top: g.top + g.height - ballDiameter / 2,
                  left: g.left + g.width / 2 - ballDiameter / 2,
                  child: ManipulatingBall(
                    notifier: _visibleBallsNotifier,
                    showAndHide: _showAndHide,
                    onDrag: (dx, dy) {
                      final og = _geo.value;
                      _updateGeo(height: og.height + dy);
                    },
                  ),
                ),
                // bottom left
                Positioned(
                  top: g.top + g.height - ballDiameter / 2,
                  left: g.left - ballDiameter / 2,
                  child: ManipulatingBall(
                    notifier: _visibleBallsNotifier,
                    showAndHide: _showAndHide,
                    onDrag: (dx, dy) {
                      final mid = ((dx * -1) + dy) / 2;
                      final og = _geo.value;
                      _updateGeo(
                        height: og.height + 2 * mid,
                        width: og.width + 2 * mid,
                        top: og.top - mid,
                        left: og.left - mid,
                      );
                    },
                  ),
                ),
                // left center
                Positioned(
                  top: g.top + g.height / 2 - ballDiameter / 2,
                  left: g.left - ballDiameter / 2,
                  child: ManipulatingBall(
                    notifier: _visibleBallsNotifier,
                    showAndHide: _showAndHide,
                    onDrag: (dx, dy) {
                      final og = _geo.value;
                      _updateGeo(
                        width: og.width - dx,
                        left: og.left + dx,
                      );
                    },
                  ),
                ),
                // center center (move)
                Positioned(
                  top: g.top + g.height / 2 - ballDiameter / 2,
                  left: g.left + g.width / 2 - ballDiameter / 2,
                  child: ManipulatingBall(
                    notifier: _visibleBallsNotifier,
                    showAndHide: _showAndHide,
                    onDrag: (dx, dy) {
                      final og = _geo.value;
                      _updateGeo(
                        top: og.top + dy,
                        left: og.left + dx,
                      );
                    },
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class ManipulatingBall extends StatefulWidget {
  const ManipulatingBall({
    required this.onDrag,
    required this.showAndHide,
    required this.notifier,
    super.key,
  });

  final Function(double, double) onDrag;
  final VoidCallback showAndHide;
  final ValueNotifier<bool> notifier;

  @override
  State<ManipulatingBall> createState() => _ManipulatingBallState();
}

class _ManipulatingBallState extends State<ManipulatingBall> {
  late double _x;
  late double _y;

  static const double ballDiameter = 28;

  void _handleDrag(DragStartDetails details) {
    _x = details.globalPosition.dx;
    _y = details.globalPosition.dy;
    widget.showAndHide();
  }

  void _handleUpdate(DragUpdateDetails details) {
    final dx = details.globalPosition.dx - _x;
    final dy = details.globalPosition.dy - _y;
    _x = details.globalPosition.dx;
    _y = details.globalPosition.dy;
    widget.onDrag(dx, dy);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: widget.notifier,
      builder: (context, visible, _) {
        return GestureDetector(
          onPanStart: _handleDrag,
          onPanUpdate: _handleUpdate,
          child: Container(
            width: ballDiameter,
            height: ballDiameter,
            decoration: BoxDecoration(
              color: visible
                  ? Colors.red.withValues(alpha: 0.5)
                  : Colors.transparent,
              shape: BoxShape.circle,
            ),
          ),
        );
      },
    );
  }
}
