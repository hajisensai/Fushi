import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'package:fushi/src/utils/window_caption_channel.dart';

/// Desktop main-window sizing and placement policy.
///
/// This intentionally lives outside [AppModel]: the window needs to be placed
/// before the first Flutter frame, while the Drift-backed app preferences are
/// only available after startup initialisation.
class DesktopWindowPlacement {
  DesktopWindowPlacement._();

  // BUG-401 relaxed the minimum window width 960 -> 480 so the window could
  // reach the compact (phone / bottom-bar) layout. TODO-1377 relaxes it
  // further to a phone-class floor of 360x480 ("cannot shrink the window any
  // further"): 360 is the common Android baseline logical width, so every
  // surface already has to lay out at this width on phones. Note 480 is also
  // the dictionary dialog's compact breakpoint (width < 480), so widths below
  // it take the phone branch there — verified against the real Windows app in
  // integration_test/min_window_size_surfaces_itest.dart (no RenderFlex
  // overflow across shelf / video / lookup / settings / dictionary dialog).
  static const Size minimumSize = Size(360, 480);
  static const Size _maximumDefaultSize = Size(1440, 960);
  static const double _defaultWidthFraction = 0.82;
  static const double _defaultHeightFraction = 0.86;

  static const String _xKey = 'desktop_main_window_x';
  static const String _yKey = 'desktop_main_window_y';
  static const String _widthKey = 'desktop_main_window_width';
  static const String _heightKey = 'desktop_main_window_height';

  /// 「上次是最大化关掉的」。与 [_xKey] 等四个 restore 键**正交**：最大化时窗口的
  /// 真实 bounds 是整个工作区，存进去会让「取消最大化」后的还原尺寸永久丢失，所以
  /// 最大化态只翻这个 flag，四个 restore 键保持上一次普通窗口的几何不动。
  static const String _maximizedKey = 'desktop_main_window_maximized';

  static Timer? _saveTimer;
  static Rect? _lastSavedBounds;
  static bool? _lastSavedMaximized;

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
      // 最大化必须在 setBounds **之后**：先落还原几何，再请求最大化，这样用户按
      // 「向下还原」拿回的是上次的普通窗口尺寸，而不是模板默认的 1280x720。
      if (await _readSavedMaximized()) {
        await windowManager.maximize();
      }
    } catch (e) {
      debugPrint('[Fushi] desktop window placement skipped: $e');
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
      // 三个窗口状态查询各是一次 platform-channel 往返。它们互不依赖，串行 await
      // 会把退出路径的第一步拖成三个事件循环轮次 —— 一次并发取回。
      //
      // BUG-1933：Windows 全屏由 runner 自有实现拥有（WindowCaptionChannel），
      // window_manager.isFullScreen 在 Windows 上恒 false——不加第四问就会把
      // 「客户区盖满显示器」的巨窗矩形当普通 bounds 存盘，下次启动整窗贴屏。
      final List<bool> flags = await Future.wait(<Future<bool>>[
        windowManager.isMinimized(),
        windowManager.isMaximized(),
        windowManager.isFullScreen(),
        WindowCaptionChannel.isFullscreen(),
      ]);
      final bool minimized = flags[0];
      final bool maximized = flags[1];
      final bool fullScreen = flags[2] || flags[3];

      // 最小化没有可用几何；全屏是播放器的临时态（下次冷启动直接全屏会挡住书架）。
      // 两者都保持上一次的记忆原样不动。
      if (minimized || fullScreen) return;

      if (maximized) {
        // 只翻 flag：最大化时 getBounds 返回的是整个工作区，写进 restore 键会让
        // 「向下还原」永久丢掉用户真正的窗口尺寸。
        await _writeMaximized(true);
        return;
      }

      final Rect bounds = await windowManager.getBounds();
      if (!_isUsableRect(bounds)) return;
      if (bounds == _lastSavedBounds && _lastSavedMaximized == false) return;

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await Future.wait(<Future<bool>>[
        prefs.setDouble(_xKey, bounds.left),
        prefs.setDouble(_yKey, bounds.top),
        prefs.setDouble(_widthKey, bounds.width),
        prefs.setDouble(_heightKey, bounds.height),
        prefs.setBool(_maximizedKey, false),
      ]);
      _lastSavedBounds = bounds;
      _lastSavedMaximized = false;
    } catch (e) {
      debugPrint('[Fushi] desktop window placement save skipped: $e');
    }
  }

  /// 最大化/还原事件的直连入口：Windows 上最大化不一定伴随 `onWindowResized`，
  /// 只靠 resize 去抖会漏记这个状态。
  static Future<void> rememberMaximized(bool maximized) async {
    if (!_isDesktop) return;
    try {
      await _writeMaximized(maximized);
    } catch (e) {
      debugPrint('[Fushi] desktop window maximized save skipped: $e');
    }
  }

  /// 清掉「上次写过什么」的进程内缓存。生产不用（进程生命周期内缓存本就该保留，它
  /// 是为了省掉重复的 prefs 写），但测试之间必须复位——否则前一个用例写过的值会让
  /// 后一个用例的写入被短路成 no-op。
  @visibleForTesting
  static void resetSaveCacheForTesting() {
    _saveTimer?.cancel();
    _saveTimer = null;
    _lastSavedBounds = null;
    _lastSavedMaximized = null;
  }

  static Future<void> _writeMaximized(bool maximized) async {
    if (_lastSavedMaximized == maximized) return;
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_maximizedKey, maximized);
    _lastSavedMaximized = maximized;
  }

  static Future<bool> _readSavedMaximized() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_maximizedKey) ?? false;
    } catch (e) {
      debugPrint('[Fushi] desktop window maximized read skipped: $e');
      return false;
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
    final double maxHeight = math.min(
      _maximumDefaultSize.height,
      workArea.height,
    );
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
      debugPrint('[Fushi] screen work areas unavailable: $e');
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
      debugPrint('[Fushi] desktop window placement read skipped: $e');
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
    double value,
    double lowerLimit,
    double upperLimit,
  ) {
    final double lower = math.min(lowerLimit, upperLimit);
    final double upper = math.max(lowerLimit, upperLimit);
    return value.clamp(lower, upper).toDouble();
  }
}
