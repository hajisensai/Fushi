/// 悬浮球的平台通道 `app.fushi.reader/floating_ball`（契约见
/// `docs/specs/2026-09-28-floating-ball.md`）。
///
/// Android：原生系统悬浮球服务 + MediaProjection 截屏 OCR；iOS：截自己的窗口 +
/// App Intent 查词入口；Windows / macOS：原生置顶窗口画的应用外悬浮球（只画与报
/// 事件，动作由 Dart 执行，契约见 `docs/specs/2026-09-30-desktop-system-floating-ball.md`）。
/// 其它平台原生侧没有实现，这里一律按「没有」处理，不抛错。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show AxisDirection;
import 'package:flutter/services.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 测试缝，与 `debugDesktopSystemBallPlatformOverride` 同形：「原生会不会上报传感器
/// 外壳（刘海 / 灵动岛）在哪条边」与外壳边 → 视口 / 推送回调这些 Dart 逻辑正交。
/// 不覆盖的话覆盖它的宿主测试只能在 iOS 上跑，桌面与 Linux CI 恒跳过。
@visibleForTesting
bool? debugSensorHousingEdgePlatformOverride;

/// 只有 iOS 上报外壳边：它横屏的左右安全区对称，Dart 自己分不出被挡的是哪一侧。
bool get floatingBallSensorHousingEdgeSupported =>
    debugSensorHousingEdgePlatformOverride ?? Platform.isIOS;

class FloatingBallChannel {
  FloatingBallChannel._();

  static const MethodChannel channel = MethodChannel(
    'app.fushi.reader/floating_ball',
  );

  static Future<T?> _invoke<T>(String method, [Object? arguments]) async {
    try {
      return await channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      return null;
    } on PlatformException catch (error, stack) {
      ErrorLogService.instance.log('floating_ball.$method', error, stack);
      return null;
    }
  }

  // ── Android ──────────────────────────────────────────────────────────

  static Future<bool> canDrawOverlays() async =>
      await _invoke<bool>('canDrawOverlays') ?? false;

  static Future<void> requestOverlayPermission() =>
      _invoke<void>('requestOverlayPermission');

  /// 启动系统悬浮球；没有悬浮窗权限时返回 false。[labels] 是按钮文案（原生侧
  /// 不维护多语言），键为动作 id 加 `open_app` / `close` / `notification` / `ball`。
  /// [icons] 是按钮 id → Material Icons 码位、[colors] 是 `surface` / `onSurface` /
  /// `primary` 的 ARGB：原生球据此画得和应用内球一样（BUG-2793）。
  ///
  /// 桌面额外要：[iconImages]（按钮 id → 已着色的图标 PNG，原生不加载字体）、
  /// [ballImage]（球面 PNG）、初始位置 [dock] / [fraction]（位置由 Dart 持久化）。
  static Future<bool> startSystemBall({
    required List<String> actions,
    required Map<String, String> labels,
    required Map<String, int> icons,
    required Map<String, int> colors,
    required String ocrLanguage,
    Map<String, Uint8List>? iconImages,
    Uint8List? ballImage,
    String? dock,
    double? fraction,
  }) async =>
      await _invoke<bool>('startSystemBall', <String, Object?>{
        'actions': actions,
        'labels': labels,
        'icons': icons,
        'colors': colors,
        'ocrLanguage': ocrLanguage,
        if (iconImages != null) 'iconImages': iconImages,
        if (ballImage != null) 'ballImage': ballImage,
        if (dock != null) 'dock': dock,
        if (fraction != null) 'fraction': fraction,
      }) ??
      false;

  static Future<void> stopSystemBall() => _invoke<void>('stopSystemBall');

  static Future<bool> isSystemBallRunning() async =>
      await _invoke<bool>('isSystemBallRunning') ?? false;

  /// Fushi 在前台时原生球隐藏（由 Flutter 球接管），退到后台再露出来。
  static Future<void> setAppForeground(bool foreground) => _invoke<void>(
    'setAppForeground',
    <String, Object?>{'foreground': foreground},
  );

  /// 走原生截屏 OCR 流程（系统同意框 → 截一帧 → 识别 → 点字查词）。返回流程
  /// 是否已启动；false 多半是缺悬浮窗权限。
  static Future<bool> startScreenOcr({
    required String language,
    required Map<String, String> labels,
  }) async =>
      await _invoke<bool>('startScreenOcr', <String, Object?>{
        'language': language,
        'labels': labels,
      }) ??
      false;

  /// 「应用外查词」：弹出独立查词窗（与系统「处理文本」、截屏识字同一个
  /// `PopupDictFlutterActivity`），只有搜索栏。
  static Future<void> openPopupLookup() => _invoke<void>('openPopupLookup');

  /// 取走（并清掉）原生系统球「查词」排队的「打开查词页」请求。主引擎不在时原生
  /// 只能先把 Fushi 拉起来，请求留在这里等 Dart 就绪后来取。
  static Future<bool> takePendingOpenLookupPage() async =>
      await _invoke<bool>('takePendingOpenLookupPage') ?? false;

  /// 取走（并清掉）原生系统球「拍照查词」排队的「开相机」请求（同
  /// [takePendingOpenLookupPage]：主引擎不在时原生先把 Fushi 拉起来再排队）。
  static Future<bool> takePendingCameraOcr() async =>
      await _invoke<bool>('takePendingCameraOcr') ?? false;

  /// 取走（并清掉）原生系统球「立即同步」排队的请求（同
  /// [takePendingOpenLookupPage]：主引擎不在时原生先把 Fushi 拉起来再排队）。
  static Future<bool> takePendingSync() async =>
      await _invoke<bool>('takePendingSync') ?? false;

  /// 取走（并清掉）截屏 OCR 报「模型未就绪」后排队的「打开系统 OCR 配置」请求
  /// （同 [takePendingOpenLookupPage]，BUG-2906）。
  static Future<bool> takePendingSystemOcrSetup() async =>
      await _invoke<bool>('takePendingSystemOcrSetup') ?? false;

  /// 取走（并清掉）「用户在系统球上点了关闭」标记。它落在原生偏好里：关闭时主
  /// 引擎可能不在，Dart 下次起来还要据此把「应用外」开关关掉，而不是把球又拉起来。
  static Future<bool> takeSystemBallClosedByUser() async =>
      await _invoke<bool>('takeSystemBallClosedByUser') ?? false;

  // ── 桌面（Windows / macOS）截屏识字 ────────────────────────────────

  /// 截球所在的那块显示器并立刻盖上冻结层（契约见
  /// `docs/specs/2026-09-30-desktop-system-floating-ball.md`「截屏识字」）。
  /// [anchor] 是球的屏幕矩形（物理像素、左上原点），null 取光标所在显示器。
  /// [labels] 键 `recognizing` / `hint` / `close`；[colors] 同 [startSystemBall]。
  /// 原生没实现 / 通道出错时返回 `capture_failed`。
  static Future<DesktopScreenOcrCapture> startScreenOcrCapture({
    required Rect? anchor,
    required Map<String, String> labels,
    required Map<String, int> colors,
  }) async {
    final Map<Object?, Object?>? raw = await _invoke<Map<Object?, Object?>>(
      'startScreenOcrCapture',
      <String, Object?>{
        'anchor': anchor == null
            ? null
            : <double>[anchor.left, anchor.top, anchor.right, anchor.bottom],
        'labels': labels,
        'colors': colors,
      },
    );
    return DesktopScreenOcrCapture.fromWire(raw);
  }

  /// 在冻结层上画识别出的行框（截图像素坐标）；[message] 非空时替换顶部提示
  /// （失败 / 没识别到字），null 时显示「点文字查词」。
  static Future<void> updateScreenOcrOverlay({
    List<Rect> lines = const <Rect>[],
    String? message,
  }) => _invoke<void>('updateScreenOcrOverlay', <String, Object?>{
    'lines': <List<double>>[
      for (final Rect r in lines) <double>[r.left, r.top, r.right, r.bottom],
    ],
    'message': message,
  });

  /// 关冻结层、恢复球（Dart 主动关，原生不回调 `screenOcrDismissed`）。
  static Future<void> stopScreenOcr() => _invoke<void>('stopScreenOcr');

  // ── iOS ─────────────────────────────────────────────────────────────

  /// 截 app 自己的窗口，返回物理像素 PNG；失败返回 null。
  static Future<Uint8List?> captureScreen() =>
      _invoke<Uint8List>('captureScreen');

  /// 刘海 / 灵动岛此刻在屏幕的哪条边（按界面方向换算）；不知道时 null。
  /// 只用于首次取值（及尺寸变化时的兜底）：界面方向一变，原生主动推
  /// `sensorHousingEdgeChanged`（见 [installHandler]）。
  static Future<AxisDirection?> sensorHousingEdge() async {
    if (!floatingBallSensorHousingEdgeSupported) return null;
    return sensorHousingEdgeFromWire(
      await _invoke<Object>('sensorHousingEdge'),
    );
  }

  /// 原生的外壳边字符串（查询回话与推送同一套）→ [AxisDirection]；
  /// 未知值 / null 一律当「不知道」（视口两侧都避让）。
  @visibleForTesting
  static AxisDirection? sensorHousingEdgeFromWire(Object? raw) => switch (raw) {
    'left' => AxisDirection.left,
    'top' => AxisDirection.up,
    'right' => AxisDirection.right,
    'bottom' => AxisDirection.down,
    _ => null,
  };

  // ── 原生 → Dart ─────────────────────────────────────────────────────

  static bool _handlerInstalled = false;

  /// 装原生回调：
  ///  - `lookupFromIntent {word}`（iOS App Intent「在 Fushi 中查词」）→ [onLookup]；
  ///  - `screenOcrFinished`（Android 截屏 OCR 已截到帧或已放弃）→ [onScreenOcrFinished]；
  ///  - `openLookupPage`（Android 系统球「查词」，Fushi 已被拉到前台）→ [onOpenLookupPage]；
  ///  - `openCameraOcr`（Android 系统球「拍照查词」，Fushi 已被拉到前台）→ [onOpenCameraOcr]；
  ///  - `openSync`（Android 系统球「立即同步」，Fushi 已被拉到前台）→ [onOpenSync]；
  ///  - `openSystemOcrSetup`（Android 截屏 OCR 报模型未就绪，Fushi 已被拉到前台）→
  ///    [onOpenSystemOcrSetup]；
  ///  - `systemBallClosedByUser`（系统球 / 常驻通知上点了关闭）→
  ///    [onSystemBallClosedByUser]；
  ///  - `systemBallAction {id, anchor}`（桌面系统球上点了某个动作；anchor 是球在
  ///    屏幕上的矩形，物理像素、左上原点）→ [onSystemBallAction]；
  ///  - `systemBallPositionChanged {dock, fraction}`（桌面系统球拖动吸附后）→
  ///    [onSystemBallPositionChanged]；
  ///  - `screenOcrTap {x, y}`（桌面冻结层上点了一下，截图像素坐标）→
  ///    [onScreenOcrTap]；
  ///  - `screenOcrDismissed`（桌面冻结层被 Esc / 右键 / 关闭钮关掉）→
  ///    [onScreenOcrDismissed]；
  ///  - `sensorHousingEdgeChanged 'left'|'top'|'right'|'bottom'|null`（iOS 界面方向
  ///    变了，含横屏左 ↔ 右翻转——那种翻转窗口尺寸与对称安全区都不变，宿主的
  ///    didChangeMetrics 不一定触发，只能靠原生推）→ [onSensorHousingEdgeChanged]。
  ///
  /// 必须先装 handler、再取冷启动时排队的那个词：iOS 原生侧把这次 take 当作
  /// 「Dart 已就绪」的信号，之后才会直接推送。Android 同理：主引擎不在时原生只
  /// 能排队，装好 handler 后再把排着的「打开查词页」「开相机」「同步」取走。
  static Future<void> installHandler({
    required void Function(String word) onLookup,
    required void Function() onScreenOcrFinished,
    void Function()? onOpenLookupPage,
    void Function()? onOpenCameraOcr,
    void Function()? onOpenSync,
    void Function()? onOpenSystemOcrSetup,
    void Function()? onSystemBallClosedByUser,
    void Function(String id, Rect? anchor)? onSystemBallAction,
    void Function(String dock, double fraction)? onSystemBallPositionChanged,
    void Function(Offset point)? onScreenOcrTap,
    void Function()? onScreenOcrDismissed,
    void Function(AxisDirection? edge)? onSensorHousingEdgeChanged,
  }) async {
    if (_handlerInstalled) return;
    _handlerInstalled = true;
    channel.setMethodCallHandler((MethodCall call) async {
      switch (call.method) {
        case 'lookupFromIntent':
          final Object? args = call.arguments;
          final Object? word = args is Map ? args['word'] : null;
          if (word is String && word.trim().isNotEmpty) onLookup(word.trim());
        case 'screenOcrFinished':
          onScreenOcrFinished();
        case 'openLookupPage':
          onOpenLookupPage?.call();
        case 'openCameraOcr':
          onOpenCameraOcr?.call();
        case 'openSync':
          onOpenSync?.call();
        case 'openSystemOcrSetup':
          onOpenSystemOcrSetup?.call();
        case 'systemBallClosedByUser':
          onSystemBallClosedByUser?.call();
        case 'systemBallAction':
          final Object? args = call.arguments;
          if (args is! Map) break;
          final Object? id = args['id'];
          if (id is String) onSystemBallAction?.call(id, _rect(args['anchor']));
        case 'systemBallPositionChanged':
          final Object? args = call.arguments;
          if (args is! Map) break;
          final Object? dock = args['dock'];
          final Object? fraction = args['fraction'];
          if (dock is String && fraction is num) {
            onSystemBallPositionChanged?.call(dock, fraction.toDouble());
          }
        case 'screenOcrTap':
          final Object? args = call.arguments;
          if (args is! Map) break;
          final Object? x = args['x'];
          final Object? y = args['y'];
          if (x is num && y is num) {
            onScreenOcrTap?.call(Offset(x.toDouble(), y.toDouble()));
          }
        case 'screenOcrDismissed':
          onScreenOcrDismissed?.call();
        case 'sensorHousingEdgeChanged':
          onSensorHousingEdgeChanged?.call(
            sensorHousingEdgeFromWire(call.arguments),
          );
      }
      return null;
    });
    if (Platform.isAndroid) {
      if (await takePendingOpenLookupPage()) onOpenLookupPage?.call();
      if (await takePendingCameraOcr()) onOpenCameraOcr?.call();
      if (await takePendingSync()) onOpenSync?.call();
      if (await takePendingSystemOcrSetup()) onOpenSystemOcrSetup?.call();
      return;
    }
    if (!Platform.isIOS) return;
    final String? pending = await _invoke<String>('takePendingIntentLookup');
    if (pending != null && pending.trim().isNotEmpty) {
      onLookup(pending.trim());
    }
  }

  /// `[left, top, right, bottom]` → Rect；形状不对返回 null。
  static Rect? _rect(Object? raw) {
    if (raw is! List || raw.length != 4) return null;
    final List<double> v = <double>[
      for (final Object? n in raw)
        if (n is num) n.toDouble(),
    ];
    if (v.length != 4) return null;
    return Rect.fromLTRB(v[0], v[1], v[2], v[3]);
  }

  @visibleForTesting
  static void debugResetHandler() {
    _handlerInstalled = false;
    channel.setMethodCallHandler(null);
  }
}

/// [FloatingBallChannel.startScreenOcrCapture] 的结果：成功带截图 PNG 与那块显示器
/// 的屏幕矩形（物理像素、左上原点），失败带 [error]。
class DesktopScreenOcrCapture {
  const DesktopScreenOcrCapture.success({
    required Uint8List this.png,
    required Rect this.screen,
  }) : error = null;

  const DesktopScreenOcrCapture.failure(String this.error)
    : png = null,
      screen = null;

  /// 原生回话 → 结果；形状不对一律当截屏失败。
  factory DesktopScreenOcrCapture.fromWire(Map<Object?, Object?>? raw) {
    if (raw == null) {
      return const DesktopScreenOcrCapture.failure(captureFailed);
    }
    final Object? error = raw['error'];
    if (error is String && error.isNotEmpty) {
      return DesktopScreenOcrCapture.failure(error);
    }
    final Object? png = raw['png'];
    final Rect? screen = FloatingBallChannel._rect(raw['screen']);
    if (png is! Uint8List || png.isEmpty || screen == null || screen.isEmpty) {
      return const DesktopScreenOcrCapture.failure(captureFailed);
    }
    return DesktopScreenOcrCapture.success(png: png, screen: screen);
  }

  /// 没有屏幕录制权限（macOS）：原生已弹系统授权请求。
  static const String permissionDenied = 'permission_denied';

  static const String captureFailed = 'capture_failed';

  final Uint8List? png;
  final Rect? screen;
  final String? error;
}
