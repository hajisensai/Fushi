/// Android 系统画中画（Picture-in-Picture）的唯一 Dart 门面。
///
/// 原生实现在 `android/app/src/main/java/app/fushi/reader/PictureInPictureChannelHandler.java`，
/// 方法名与参数名是跨语言契约，改一边必须改另一边。
///
/// **三条真实陷阱**（原生侧同样写了一份，这里是给 Dart 调用方看的）：
///
/// 1. **版本门**：`PictureInPictureParams` 是 API 26 才有的，而本 app minSdk 24；
///    另外电视 / 部分定制 ROM 会整块关掉 PiP。所以「支不支持」只能问原生，不能
///    靠版本号在 Dart 侧猜。非 Android 平台恒 false，且**不发任何通道调用**——
///    那边压根没注册这条通道，发过去只会换来一个 MissingPluginException。
/// 2. **宽高比钳制**：系统只接受 `[1/2.39, 2.39]` 区间内的比例，越界时
///    `enterPictureInPictureMode` 抛 IllegalArgumentException。视频的真实比例
///    （竖屏短视频、超宽银幕片源）很容易越界，所以送进原生之前先过
///    [clampPictureInPictureAspectRatio]。
/// 3. **退出不走 enter()**：用户从小窗的关闭 / 还原按钮出来时不经过我们的
///    [AndroidPictureInPicture.enter]，只有原生回程 `onChanged` 能告诉我们。
///    因此 [AndroidPictureInPicture.isActive] 的进程内缓存必须由那条回程驱动，
///    不能只在 enter 成功时置位。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';

/// Android PiP 允许的最小宽高比（1:2.39，竖向极限）。
const double kPictureInPictureMinAspectRatio = 1 / 2.39;

/// Android PiP 允许的最大宽高比（2.39:1，横向极限）。
const double kPictureInPictureMaxAspectRatio = 2.39;

/// 拿不到可用比例时的兜底（16:9，落在允许区间内）。
const double kPictureInPictureDefaultAspectRatio = 16 / 9;

/// 把任意宽高比钳制进 Android PiP 允许的 `[1/2.39, 2.39]` 区间；
/// `<= 0` 或非有限值（NaN / ±Infinity）退回 16:9。
///
/// 抽成纯函数是为了让这条「越界就抛」的系统约束有一个可测的落点：视频真实比例
/// 来自解码器，竖屏短视频（9:16 ≈ 0.5625，尚在区间内）与极端裁切片源都可能落到
/// 区间外，而失败形态是原生抛 IllegalArgumentException——在真机上表现为「点了
/// 小窗没反应」，很难反查到比例上。
double clampPictureInPictureAspectRatio(double aspectRatio) {
  if (!aspectRatio.isFinite || aspectRatio <= 0) {
    return kPictureInPictureDefaultAspectRatio;
  }
  if (aspectRatio < kPictureInPictureMinAspectRatio) {
    return kPictureInPictureMinAspectRatio;
  }
  if (aspectRatio > kPictureInPictureMaxAspectRatio) {
    return kPictureInPictureMaxAspectRatio;
  }
  return aspectRatio;
}

/// Android 系统画中画的唯一 Dart 门面。
abstract final class AndroidPictureInPicture {
  static const String _methodIsSupported = 'isSupported';
  static const String _methodEnter = 'enter';
  static const String _methodIsActive = 'isActive';
  static const String _methodOnChanged = 'onChanged';
  static const String _argAspectRatio = 'aspectRatio';

  static final StreamController<bool> _modeChanges =
      StreamController<bool>.broadcast();

  /// 能力探测结果缓存：这个答案在一次进程生命周期里不会变（版本门 + 系统特性
  /// 都是安装期就定死的），没必要每次开视频都过一次通道。
  static bool? _supported;

  /// 是否已挂上原生回程的接收 handler。
  static bool _listening = false;

  /// 进程内的「当前在不在 PiP 里」。由原生回程 `onChanged` 与 [enter] 的成功
  /// 结果共同驱动；[refreshActive] 可向原生要一次真值兜底。
  static bool _active = false;

  static MethodChannel get _channel => FushiChannels.pictureInPicture;

  /// 本机是否支持（非 Android 恒 false；Android 上问原生）。结果缓存。
  static Future<bool> isSupported() async {
    final bool? cached = _supported;
    if (cached != null) {
      return cached;
    }
    if (defaultTargetPlatform != TargetPlatform.android) {
      // 其余四端没有这条通道的原生侧。直接定论，不发调用。
      return _supported = false;
    }
    _ensureListening();
    bool supported = false;
    try {
      supported =
          await _channel.invokeMethod<bool>(_methodIsSupported) ?? false;
    } on MissingPluginException {
      // 原生侧没注册（旧版本 app / 非 MainActivity 引擎入口，如弹窗词典）。
      // 「没有」是事实，不是错误。
      supported = false;
    } on PlatformException {
      supported = false;
    }
    return _supported = supported;
  }

  /// 请求进入 PiP。[aspectRatio] `<= 0`（或非有限值）时用 16:9。
  ///
  /// 返回是否**真的**进去了：原生侧任何异常都被吞成 false，调用方据此决定是否
  /// 保持原状 / 提示用户，而不是假定一定成功。
  static Future<bool> enter({required double aspectRatio}) async {
    if (!await isSupported()) {
      // 不支持就别发 enter：省一次无意义的通道往返，也避免在非 Android 上
      // 撞 MissingPluginException。
      return false;
    }
    final double clamped = clampPictureInPictureAspectRatio(aspectRatio);
    bool entered = false;
    try {
      entered =
          await _channel.invokeMethod<bool>(_methodEnter, <String, Object?>{
                _argAspectRatio: clamped,
              }) ??
              false;
    } on MissingPluginException {
      entered = false;
    } on PlatformException {
      entered = false;
    }
    if (entered && !_active) {
      // 原生的 onChanged 通常随后就到，但两者之间有一帧的窗口；先本地置位，
      // 免得调用方在这段窗口里读到过期的 false。重复事件由 _emit 去抖。
      _emit(true);
    }
    return entered;
  }

  /// PiP 模式变化流（true = 进入，false = 退出）。多订阅者安全（broadcast）。
  static Stream<bool> get modeChanges {
    _ensureListening();
    return _modeChanges.stream;
  }

  /// 当前是否在 PiP 中（进程内缓存；要向原生要真值用 [refreshActive]）。
  ///
  /// 同步 getter 是刻意的：调用点在 build / 手势回调这类不能 await 的地方。
  static bool get isActive => _active;

  /// 向原生问一次真值并更新缓存（原生兜底）。
  ///
  /// 缓存唯一可能失真的场景是「原生回程在引擎重建之类的边界上丢了一条」；
  /// 恢复前台之类的时机调一次即可对齐。
  static Future<bool> refreshActive() async {
    if (!await isSupported()) {
      if (_active) _emit(false);
      return false;
    }
    bool active = _active;
    try {
      active = await _channel.invokeMethod<bool>(_methodIsActive) ?? false;
    } on MissingPluginException {
      active = false;
    } on PlatformException {
      // 问不到就保持缓存：把它当成 false 会凭空发一条「退出 PiP」事件。
      return _active;
    }
    if (active != _active) {
      _emit(active);
    }
    return active;
  }

  /// 挂上原生 → Dart 的回程接收 handler（幂等）。
  static void _ensureListening() {
    if (_listening) return;
    _listening = true;
    _channel.setMethodCallHandler((MethodCall call) async {
      if (call.method != _methodOnChanged) return null;
      final Object? arguments = call.arguments;
      debugHandleModeChanged(arguments is bool && arguments);
      return null;
    });
  }

  static void _emit(bool active) {
    if (_active == active) return;
    _active = active;
    if (!_modeChanges.isClosed) {
      _modeChanges.add(active);
    }
  }

  /// 测试入口：模拟原生回程。生产路径也复用它，保证测的是同一条路。
  @visibleForTesting
  static void debugHandleModeChanged(bool active) => _emit(active);

  /// 测试入口：清掉能力缓存与 PiP 状态缓存。
  ///
  /// 不关 [modeChanges] 的 controller——它是 broadcast 且静态的，关掉之后同一
  /// 进程里的后续用例就再也发不出事件了。
  @visibleForTesting
  static void resetForTesting() {
    _supported = null;
    _active = false;
    _listening = false;
    _channel.setMethodCallHandler(null);
  }
}
