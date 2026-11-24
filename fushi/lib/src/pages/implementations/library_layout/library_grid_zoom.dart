import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_toggles.dart'
    show FushiSlider;
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/section_visibility.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

// 库页网格「缩放调每行个数」（2026-11-24 用户拍板：Cupertino 库页取方案 C 的
// 双指缩放）。触屏双指捏合 / 触控板捏合、⌘+ ⌘−（Windows / Linux 是 Ctrl）逐档
// 改每行个数，macOS 档工具栏另有一条滑杆。值写回既有的「每行数量」偏好
// （`library_grid_columns`，按库 × 窗口尺寸档存，见 library_grid_columns.dart）
// ——与「显示」菜单里的「每行数量」是同一份真相，不另立偏好键。
//
// 只在 Apple 设计系统（`isGlassDesign`）下接手势与快捷键；M3E 原样返回子树。

/// 捏合放大到这个比例换下一档（更少列、封面更大）。
const double kLibraryGridZoomInRatio = 1.22;

/// 捏合缩小到这个比例换下一档（更多列、封面更小）。
const double kLibraryGridZoomOutRatio = 1 / kLibraryGridZoomInRatio;

/// 从 [current] 列往 [zoomIn]（放大 = 更少列）方向走一档后的列数；[choices]
/// 是本尺寸档可选的固定列数（升序）。[current] 是此刻实际列数（「自动」时是
/// 自动算出的列数，未必在 [choices] 里）。到头了返回 null。
int? libraryGridZoomStep({
  required int current,
  required List<int> choices,
  required bool zoomIn,
}) {
  if (choices.isEmpty) return null;
  final List<int> sorted = List<int>.of(choices)..sort();
  if (zoomIn) {
    for (int i = sorted.length - 1; i >= 0; i--) {
      if (sorted[i] < current) return sorted[i];
    }
    return null;
  }
  for (final int c in sorted) {
    if (c > current) return c;
  }
  return null;
}

/// 一个视图对外暴露的网格缩放口（macOS 档工具栏滑杆读它）。
@immutable
class LibraryGridZoomPort {
  const LibraryGridZoomPort({
    required this.columns,
    required this.choices,
    required this.onColumnsChanged,
  });

  /// 此刻实际列数。
  final int columns;

  /// 本尺寸档可选的固定列数（升序）。
  final List<int> choices;
  final ValueChanged<int> onColumnsChanged;

  bool sameLook(LibraryGridZoomPort other) =>
      columns == other.columns && listEquals(choices, other.choices);
}

/// 库页外壳持有的缩放口登记处：当前可见视图里的 [LibraryGridZoom] 登记自己，
/// 外壳的滑杆据此出现 / 消失。通知推迟到帧末（登记发生在构建期）。
class LibraryGridZoomHub extends ChangeNotifier {
  Object? _owner;
  LibraryGridZoomPort? _port;
  bool _scheduled = false;
  bool _disposed = false;

  LibraryGridZoomPort? get port => _port;

  void register(Object owner, LibraryGridZoomPort port) {
    final LibraryGridZoomPort? old = _port;
    final bool same = _owner == owner && old != null && old.sameLook(port);
    _owner = owner;
    _port = port;
    if (!same) _schedule();
  }

  void unregister(Object owner) {
    if (_owner != owner) return;
    _owner = null;
    _port = null;
    _schedule();
  }

  void _schedule() {
    if (_scheduled || _disposed) return;
    _scheduled = true;
    SchedulerBinding.instance
      ..addPostFrameCallback((_) {
        _scheduled = false;
        if (!_disposed) notifyListeners();
      })
      ..ensureVisualUpdate();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// 向库页视图下发 [LibraryGridZoomHub]（Apple 库页外壳挂）。纯数据通道。
class LibraryGridZoomHubScope extends InheritedWidget {
  const LibraryGridZoomHubScope({
    required this.hub,
    required super.child,
    super.key,
  });

  final LibraryGridZoomHub hub;

  static LibraryGridZoomHub? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<LibraryGridZoomHubScope>()?.hub;

  @override
  bool updateShouldNotify(LibraryGridZoomHubScope oldWidget) =>
      hub != oldWidget.hub;
}

/// 包住一个库页网格视图：Apple 设计系统下接双指 / 触控板捏合与 ⌘+ ⌘− 改每行
/// 个数，换档时整块内容从旧比例缩放淡入到新版面（时长 [FushiMotion.medium]）；
/// 捏合过程中内容跟手轻微缩放（夹在换档阈值内）。M3E 原样返回 [child]。
///
/// [columns] 是此刻实际列数，[choices] 是本尺寸档可选的固定列数；换档经
/// [onColumnsChanged] 交回（调用方写偏好并重建）。
class LibraryGridZoom extends StatefulWidget {
  const LibraryGridZoom({
    required this.columns,
    required this.choices,
    required this.onColumnsChanged,
    required this.child,
    super.key,
  });

  final int columns;
  final List<int> choices;
  final ValueChanged<int> onColumnsChanged;
  final Widget child;

  @override
  State<LibraryGridZoom> createState() => _LibraryGridZoomState();
}

class _LibraryGridZoomState extends State<LibraryGridZoom>
    with SingleTickerProviderStateMixin {
  /// 正在屏幕上的触点（位置按全局坐标）。
  final Map<int, Offset> _pointers = <int, Offset>{};

  /// 本次捏合的基准两指距离；换档后重置为当前距离。
  double? _baseDistance;

  /// 跟手的缩放（只在捏合过程中不为 1）。
  double _liveScale = 1;

  /// 换档动画：从旧列数对应的比例回到 1。
  late final AnimationController _settle = AnimationController(
    vsync: this,
    value: 1,
  );
  double _settleFrom = 1;

  LibraryGridZoomHub? _hub;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final LibraryGridZoomHub? hub = LibraryGridZoomHubScope.maybeOf(context);
    if (hub != _hub) {
      _hub?.unregister(this);
      _hub = hub;
    }
  }

  @override
  void didUpdateWidget(LibraryGridZoom oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.columns != widget.columns && oldWidget.columns > 0) {
      // 列数变了（捏合 / 快捷键 / 滑杆 / 显示菜单）：内容从旧比例过渡到新版面。
      _settleFrom = (widget.columns / oldWidget.columns).clamp(0.8, 1.25);
      final Duration duration = fushiMotionDuration(
        context,
        FushiMotion.medium,
      );
      if (duration == Duration.zero) {
        _settle.value = 1;
      } else {
        _settle
          ..duration = duration
          ..forward(from: 0);
      }
    }
  }

  @override
  void dispose() {
    _hub?.unregister(this);
    _settle.dispose();
    super.dispose();
  }

  void _step({required bool zoomIn}) {
    final int? next = libraryGridZoomStep(
      current: widget.columns,
      choices: widget.choices,
      zoomIn: zoomIn,
    );
    if (next != null) widget.onColumnsChanged(next);
  }

  double? _pinchDistance() {
    if (_pointers.length < 2) return null;
    final List<Offset> p = _pointers.values.take(2).toList(growable: false);
    return (p[0] - p[1]).distance;
  }

  void _onScaleRatio(double ratio) {
    if (ratio >= kLibraryGridZoomInRatio) {
      _step(zoomIn: true);
      _rebase();
    } else if (ratio <= kLibraryGridZoomOutRatio) {
      _step(zoomIn: false);
      _rebase();
    } else {
      setState(() => _liveScale = ratio);
    }
  }

  void _rebase() {
    _baseDistance = _pinchDistance();
    _panZoomBase = _lastPanZoomScale;
    setState(() => _liveScale = 1);
  }

  void _onPointerDown(PointerDownEvent event) {
    if (event.kind != PointerDeviceKind.touch) return;
    _pointers[event.pointer] = event.position;
    if (_pointers.length == 2) _baseDistance = _pinchDistance();
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (!_pointers.containsKey(event.pointer)) return;
    _pointers[event.pointer] = event.position;
    final double? base = _baseDistance;
    final double? now = _pinchDistance();
    if (base == null || now == null || base <= 0) return;
    _onScaleRatio(now / base);
  }

  void _onPointerEnd(PointerEvent event) {
    if (_pointers.remove(event.pointer) == null) return;
    if (_pointers.length < 2) {
      _baseDistance = null;
      if (_liveScale != 1) setState(() => _liveScale = 1);
    }
  }

  // 触控板捏合（macOS / Windows 精确触控板）：事件自带累计缩放。
  double _panZoomBase = 1;
  double _lastPanZoomScale = 1;

  void _onPanZoomStart(PointerPanZoomStartEvent event) {
    _panZoomBase = 1;
    _lastPanZoomScale = 1;
  }

  void _onPanZoomUpdate(PointerPanZoomUpdateEvent event) {
    _lastPanZoomScale = event.scale;
    if (_panZoomBase <= 0) return;
    _onScaleRatio(event.scale / _panZoomBase);
  }

  void _onPanZoomEnd(PointerPanZoomEndEvent event) {
    _panZoomBase = 1;
    _lastPanZoomScale = 1;
    if (_liveScale != 1) setState(() => _liveScale = 1);
  }

  @override
  Widget build(BuildContext context) {
    if (!isGlassDesign(context)) return widget.child;
    final LibraryGridZoomHub? hub = _hub;
    if (hub != null) {
      if (SectionVisibility.of(context)) {
        hub.register(
          this,
          LibraryGridZoomPort(
            columns: widget.columns,
            choices: widget.choices,
            onColumnsChanged: widget.onColumnsChanged,
          ),
        );
      } else {
        hub.unregister(this);
      }
    }
    // 修饰键跟真实操作系统走（Mac / iPad 键盘是 ⌘，其余 Ctrl），与设计系统无关。
    final bool apple =
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.iOS;
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        SingleActivator(
          LogicalKeyboardKey.equal,
          meta: apple,
          control: !apple,
        ): () =>
            _step(zoomIn: true),
        SingleActivator(
          LogicalKeyboardKey.numpadAdd,
          meta: apple,
          control: !apple,
        ): () =>
            _step(zoomIn: true),
        SingleActivator(
          LogicalKeyboardKey.minus,
          meta: apple,
          control: !apple,
        ): () =>
            _step(zoomIn: false),
        SingleActivator(
          LogicalKeyboardKey.numpadSubtract,
          meta: apple,
          control: !apple,
        ): () =>
            _step(zoomIn: false),
      },
      child: Listener(
        onPointerDown: _onPointerDown,
        onPointerMove: _onPointerMove,
        onPointerUp: _onPointerEnd,
        onPointerCancel: _onPointerEnd,
        onPointerPanZoomStart: _onPanZoomStart,
        onPointerPanZoomUpdate: _onPanZoomUpdate,
        onPointerPanZoomEnd: _onPanZoomEnd,
        child: AnimatedBuilder(
          animation: _settle,
          builder: (BuildContext context, Widget? child) {
            final double t = FushiMotion.standard.transform(_settle.value);
            final double settle = _settleFrom + (1 - _settleFrom) * t;
            final double scale = settle * _liveScale;
            if (scale == 1 && t >= 1) return child!;
            return Opacity(
              opacity: 0.6 + 0.4 * t,
              child: Transform.scale(
                scale: scale,
                alignment: Alignment.topCenter,
                child: child,
              ),
            );
          },
          child: widget.child,
        ),
      ),
    );
  }
}

/// macOS 档工具栏的缩放滑杆（Photos 式）：左端小图标 = 更多列（封面更小），
/// 右端大图标 = 更少列。滑到哪一档即时写回。只在 Apple 外壳里出现。
class LibraryGridZoomSlider extends StatelessWidget {
  const LibraryGridZoomSlider({required this.port, super.key});

  final LibraryGridZoomPort port;

  @override
  Widget build(BuildContext context) {
    final List<int> sorted = List<int>.of(port.choices)..sort();
    if (sorted.length < 2) return const SizedBox.shrink();
    // 滑杆位置：右端 = 最少列。实际列数不在可选档里（自动）时取最近的一档。
    int nearest = 0;
    for (int i = 0; i < sorted.length; i++) {
      if ((sorted[i] - port.columns).abs() <
          (sorted[nearest] - port.columns).abs()) {
        nearest = i;
      }
    }
    final int last = sorted.length - 1;
    final double position = (last - nearest).toDouble();
    final Color tint = appleColorsOf(context).secondaryLabel;
    return Row(
      key: const ValueKey<String>('library-grid-zoom-slider'),
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        FushiIcon(FushiIcons.gridView, size: 13, color: tint),
        SizedBox(
          width: 96,
          child: FushiSlider(
            value: position,
            min: 0,
            max: last.toDouble(),
            divisions: last,
            onChanged: (double value) {
              final int columns = sorted[last - value.round()];
              if (columns != port.columns) port.onColumnsChanged(columns);
            },
          ),
        ),
        FushiIcon(FushiIcons.gridView, size: 18, color: tint),
      ],
    );
  }
}
