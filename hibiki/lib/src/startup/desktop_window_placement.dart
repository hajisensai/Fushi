import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

/// Desktop main-window sizing and placement policy.
///
/// This intentionally lives outside [AppModel]: the window needs to be placed
/// before the first Flutter frame, while the Drift-backed app preferences are
/// only available after startup initialisation.
class DesktopWindowPlacement {
  DesktopWindowPlacement._();

  // BUG-401: the desktop minimum window WIDTH was 960, so the window could
  // never be dragged narrow enough for the real-width breakpoint to fall
  // into the compact (phone / bottom-bar) layout. Relaxed to 480 so users
  // who want the phone layout on desktop can resize down to it. Height kept
  // at 640 (vertical real estate is not the constraint for the layout class).
  static const Size minimumSize = Size(480, 640);
  static const Size _maximumDefaultSize = Size(1440, 960);
  static const double _defaultWidthFraction = 0.82;
  static const double _defaultHeightFraction = 0.86;

  static const String _xKey = 'desktop_main_window_x';
  static const String _yKey = 'desktop_main_window_y';
  static const String _widthKey = 'desktop_main_window_width';
  static const String _heightKey = 'desktop_main_window_height';

  static Timer? _saveTimer;
  static Rect? _lastSavedBounds;

  static bool get _isDesktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  static Future<void> applyInitialPlacement() async {
    if (!_isDesktop) return;

    try {
      final Rect? currentBounds = await _tryGetCurrentBounds();
      final Rect? savedBounds = await _readSavedBounds();
      final Rect? placementAnchor = savedBounds ?? currentBounds;
      final List<Rect> workAreas = await _loadWorkAreas(placementAnchor);
      final Rect workArea = selectInitialWorkArea(
        workAreas: workAreas,
        savedBounds: savedBounds,
        currentBounds: currentBounds,
      );
      final Rect initialBounds = resolveInitialBounds(
        workArea: workArea,
        savedBounds: savedBounds,
      );

      await windowManager.setMinimumSize(minimumSizeForWorkArea(workArea));
      await windowManager.setBounds(initialBounds);
    } catch (e) {
      debugPrint('[Hibiki] desktop window placement skipped: $e');
    }
  }

  static void rememberCurrentBounds({
    Duration debounce = const Duration(milliseconds: 500),
  }) {
    if (!_isDesktop) return;

    _saveTimer?.cancel();
    _saveTimer = Timer(debounce, () {
      unawaited(saveCurrentBoundsNow());
    });
  }

  static Future<void> saveCurrentBoundsNow() async {
    if (!_isDesktop) return;

    _saveTimer?.cancel();
    _saveTimer = null;
    try {
      if (await windowManager.isMinimized() ||
          await windowManager.isMaximized() ||
          await windowManager.isFullScreen()) {
        return;
      }

      final Rect bounds = await windowManager.getBounds();
      if (!_isUsableRect(bounds) || bounds == _lastSavedBounds) return;

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await Future.wait(<Future<bool>>[
        prefs.setDouble(_xKey, bounds.left),
        prefs.setDouble(_yKey, bounds.top),
        prefs.setDouble(_widthKey, bounds.width),
        prefs.setDouble(_heightKey, bounds.height),
      ]);
      _lastSavedBounds = bounds;
    } catch (e) {
      debugPrint('[Hibiki] desktop window placement save skipped: $e');
    }
  }

  static Rect resolveInitialBounds({
    required Rect workArea,
    Rect? savedBounds,
  }) {
    final Rect candidate = _isUsableRect(savedBounds)
        ? savedBounds!
        : _defaultBoundsForWorkArea(workArea);
    return clampBoundsToWorkArea(bounds: candidate, workArea: workArea);
  }

  static Rect clampBoundsToWorkArea({
    required Rect bounds,
    required Rect workArea,
  }) {
    final Size effectiveMinimum = minimumSizeForWorkArea(workArea);
    final double width = _clampDouble(
      bounds.width,
      effectiveMinimum.width,
      math.max(1, workArea.width),
    );
    final double height = _clampDouble(
      bounds.height,
      effectiveMinimum.height,
      math.max(1, workArea.height),
    );
    final double left = _clampDouble(
      bounds.left,
      workArea.left,
      workArea.right - width,
    );
    final double top = _clampDouble(
      bounds.top,
      workArea.top,
      workArea.bottom - height,
    );

    return Rect.fromLTWH(left, top, width, height);
  }

  static Size minimumSizeForWorkArea(Rect workArea) {
    return Size(
      math.max(1, math.min(minimumSize.width, workArea.width)),
      math.max(1, math.min(minimumSize.height, workArea.height)),
    );
  }

  static Rect selectInitialWorkArea({
    required List<Rect> workAreas,
    Rect? savedBounds,
    Rect? currentBounds,
  }) {
    return selectWorkArea(
      workAreas: workAreas,
      currentBounds: _isUsableRect(savedBounds) ? savedBounds : currentBounds,
    );
  }

  static Rect selectWorkArea({
    required List<Rect> workAreas,
    Rect? currentBounds,
  }) {
    final List<Rect> usableAreas =
        workAreas.where((Rect area) => _isUsableRect(area)).toList();
    if (usableAreas.isEmpty) {
      return const Rect.fromLTWH(0, 0, 1280, 720);
    }
    if (!_isUsableRect(currentBounds)) {
      return usableAreas.first;
    }

    final Offset center = currentBounds!.center;
    for (final Rect area in usableAreas) {
      if (area.contains(center)) return area;
    }

    Rect bestArea = usableAreas.first;
    double bestIntersection = -1;
    for (final Rect area in usableAreas) {
      final double intersection = _intersectionArea(area, currentBounds);
      if (intersection > bestIntersection) {
        bestIntersection = intersection;
        bestArea = area;
      }
    }
    return bestArea;
  }

  static Rect _defaultBoundsForWorkArea(Rect workArea) {
    final Size effectiveMinimum = minimumSizeForWorkArea(workArea);
    final double maxWidth = math.min(_maximumDefaultSize.width, workArea.width);
    final double maxHeight =
        math.min(_maximumDefaultSize.height, workArea.height);
    final Size size = Size(
      _clampDouble(
        workArea.width * _defaultWidthFraction,
        effectiveMinimum.width,
        maxWidth,
      ),
      _clampDouble(
        workArea.height * _defaultHeightFraction,
        effectiveMinimum.height,
        maxHeight,
      ),
    );

    return Rect.fromLTWH(
      workArea.left + (workArea.width - size.width) / 2,
      workArea.top + (workArea.height - size.height) / 2,
      size.width,
      size.height,
    );
  }

  static Future<Rect?> _tryGetCurrentBounds() async {
    try {
      final Rect bounds = await windowManager.getBounds();
      return _isUsableRect(bounds) ? bounds : null;
    } catch (_) {
      return null;
    }
  }

  static Future<List<Rect>> _loadWorkAreas(Rect? fallbackBounds) async {
    try {
      final List<Display> displays = await screenRetriever.getAllDisplays();
      final List<Rect> workAreas =
          displays.map(_workAreaFromDisplay).whereType<Rect>().toList();
      if (workAreas.isNotEmpty) return workAreas;
    } catch (e) {
      debugPrint('[Hibiki] screen work areas unavailable: $e');
    }

    if (_isUsableRect(fallbackBounds)) {
      return <Rect>[fallbackBounds!];
    }
    return const <Rect>[Rect.fromLTWH(0, 0, 1280, 720)];
  }

  static Rect? _workAreaFromDisplay(Display display) {
    final Offset position = display.visiblePosition ?? Offset.zero;
    final Size size = display.visibleSize ?? display.size;
    final Rect area = Rect.fromLTWH(
      position.dx,
      position.dy,
      size.width,
      size.height,
    );
    return _isUsableRect(area) ? area : null;
  }

  static Future<Rect?> _readSavedBounds() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final double? x = prefs.getDouble(_xKey);
      final double? y = prefs.getDouble(_yKey);
      final double? width = prefs.getDouble(_widthKey);
      final double? height = prefs.getDouble(_heightKey);
      if (x == null || y == null || width == null || height == null) {
        return null;
      }

      final Rect bounds = Rect.fromLTWH(x, y, width, height);
      return _isUsableRect(bounds) ? bounds : null;
    } catch (e) {
      debugPrint('[Hibiki] desktop window placement read skipped: $e');
      return null;
    }
  }

  static bool _isUsableRect(Rect? rect) {
    return rect != null &&
        rect.left.isFinite &&
        rect.top.isFinite &&
        rect.width.isFinite &&
        rect.height.isFinite &&
        rect.width > 0 &&
        rect.height > 0;
  }

  static double _intersectionArea(Rect a, Rect b) {
    final double left = math.max(a.left, b.left);
    final double top = math.max(a.top, b.top);
    final double right = math.min(a.right, b.right);
    final double bottom = math.min(a.bottom, b.bottom);
    if (right <= left || bottom <= top) return 0;
    return (right - left) * (bottom - top);
  }

  static double _clampDouble(
      double value, double lowerLimit, double upperLimit) {
    final double lower = math.min(lowerLimit, upperLimit);
    final double upper = math.max(lowerLimit, upperLimit);
    return value.clamp(lower, upper).toDouble();
  }
}
