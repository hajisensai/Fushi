import 'dart:async';
import 'dart:io';

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:fushi/src/models/preferences_repository.dart' show VideoFitMode;

/// Windows HDR 直通 / 10-bit 输出（计划 `docs/plans/2026-08-30-video-hdr-passthrough.md`）。
///
/// 纹理路径（`vo=libmpv` → ANGLE 8-bit 共享纹理 → Flutter 8-bit 交换链）在三层上都是
/// SDR，HDR 信号无处可出。直通模式让 libmpv 拿到 runner 提供的**独立顶层宿主窗口**
/// （`HdrVideoHostWindow`，钉在主窗正后方）自建 D3D11 交换链：`vo=gpu-next` +
/// `gpu-context=d3d11` + `wid=<宿主 HWND>` + `d3d11-output-format=rgb10_a2`（10-bit）+
/// `target-colorspace-hint=auto`（HDR 元数据交给交换链 / DWM）。Flutter 侧只做两件事：
/// 把 [Video] 的纹理隐藏成透明洞（主窗已 blur-behind，洞透出后方宿主窗；Phase 0 实测
/// `.codex-test/hdr-passthrough/RESULTS.md` 变体 6），并把 [Video] 的物理像素矩形喂给
/// 宿主窗（[HdrHostRectReporter]）。16 层控件 / 查词弹窗照常叠在洞上。
///
/// 模式切换只切 `vo`（mpv 运行时支持），不重建 Player：字幕轨、进度、着色器全部保留。
enum VideoHdrOutputMode {
  /// 显示器处于 HDR 模式且片源是 HDR（bt.2020 + PQ/HLG）时直通，否则纹理路径。
  auto('auto'),

  /// 只要在 Windows 就走宿主窗（10-bit 输出，SDR 片源也受益于 10-bit 抖动）。
  always('always'),

  /// 永远纹理路径（现状）。
  off('off');

  const VideoHdrOutputMode(this.storageValue);

  final String storageValue;

  static VideoHdrOutputMode fromStorage(String? value) {
    for (final VideoHdrOutputMode m in values) {
      if (m.storageValue == value) return m;
    }
    return VideoHdrOutputMode.auto;
  }
}

/// 偏好键（Drift `preferences`）。
const String kVideoHdrOutputPref = 'video_hdr_output';

/// 进程级「宿主窗模式激活中」信号。
///
/// 视频洞要一路透到 DWM，**每一层**盖在视频矩形上的祖先都得不画底色——视频页自己的
/// Scaffold 由 `VideoPlayerController.hdrHostActive` 管，但 Windows 自绘标题栏外壳
/// （`FushiWindowsTitleBar` 的 `ColoredBox(surface)`）包着整个 Navigator、拿不到页面级
/// 控制器，只能听这个全局位。同一时刻只有一个播放器，所以单个进程级 notifier 够用；
/// 由 `VideoPlayerController` 在进入 / 退出 / dispose 时写，其它地方只读。
final ValueNotifier<bool> hdrHostActiveGlobal = ValueNotifier<bool>(false);

/// `DXGI_COLOR_SPACE_RGB_FULL_G2084_NONE_P2020`：Windows HDR 模式打开时输出的色彩空间。
const int kDxgiColorSpaceHdr10 = 12;

/// `DXGI_COLOR_SPACE_RGB_FULL_G22_NONE_P709`：普通 SDR 桌面。
const int kDxgiColorSpaceSdr = 0;

/// runner 回报的显示器信息（`IDXGIOutput6::GetDesc1`）。
@immutable
class HdrDisplayInfo {
  const HdrDisplayInfo({
    required this.colorSpace,
    required this.maxLuminance,
    required this.bitsPerColor,
  });

  static const HdrDisplayInfo unknown = HdrDisplayInfo(
    colorSpace: -1,
    maxLuminance: 0,
    bitsPerColor: 0,
  );

  final int colorSpace;
  final double maxLuminance;
  final int bitsPerColor;

  /// 显示器当前是否以 HDR10 输出（判据只看当前 colorspace，不看面板能力——
  /// 面板支持 HDR 但 Windows 没开时仍是 SDR）。
  bool get isHdr => colorSpace == kDxgiColorSpaceHdr10;

  @override
  bool operator ==(Object other) =>
      other is HdrDisplayInfo &&
      other.colorSpace == colorSpace &&
      other.maxLuminance == maxLuminance &&
      other.bitsPerColor == bitsPerColor;

  @override
  int get hashCode => Object.hash(colorSpace, maxLuminance, bitsPerColor);

  @override
  String toString() =>
      'HdrDisplayInfo(colorSpace: $colorSpace, maxLuminance: $maxLuminance, '
      'bitsPerColor: $bitsPerColor)';
}

/// 片源是否 HDR：libmpv `video-params/primaries` 为 bt.2020 且 `gamma` 为 PQ / HLG。
bool isHdrVideoParams({required String? primaries, required String? gamma}) {
  return primaries == 'bt.2020' && (gamma == 'pq' || gamma == 'hlg');
}

/// 唯一的模式判据（计划 §4.4）——所有「要不要走宿主窗」都只问这里。
bool shouldUseHdrHostWindow({
  required bool isWindows,
  required VideoHdrOutputMode mode,
  required bool displayHdr,
  required bool sourceHdr,
}) {
  if (!isWindows) return false;
  switch (mode) {
    case VideoHdrOutputMode.off:
      return false;
    case VideoHdrOutputMode.always:
      return true;
    case VideoHdrOutputMode.auto:
      return displayHdr && sourceHdr;
  }
}

/// 进入宿主窗模式时按**顺序**下发的 mpv 属性。`wid` / `gpu-context` /
/// `d3d11-output-format` 只在下一次 VO 创建时生效，所以 `vo` 必须放最后。
Map<String, String> hdrHostMpvProperties(int hostWindowHandle) {
  return <String, String>{
    'gpu-context': 'd3d11',
    'wid': hostWindowHandle.toString(),
    'd3d11-output-format': 'rgb10_a2',
    'target-colorspace-hint': 'auto',
    'vo': 'gpu-next',
  };
}

/// 退回纹理路径：只需把 VO 切回 libmpv render API。
const Map<String, String> kTextureMpvProperties = <String, String>{
  'vo': 'libmpv',
};

/// 宿主窗模式下画面 fit 由 mpv 自己算（宿主窗矩形 = [Video] 矩形）：
/// contain = 保比例留黑边；cover = 保比例裁切（`panscan=1`）；fill = 拉伸。
Map<String, String> hdrHostFitProperties(VideoFitMode fit) {
  switch (fit) {
    case VideoFitMode.contain:
      return const <String, String>{'keepaspect': 'yes', 'panscan': '0'};
    case VideoFitMode.cover:
      return const <String, String>{'keepaspect': 'yes', 'panscan': '1'};
    case VideoFitMode.fill:
      return const <String, String>{'keepaspect': 'no', 'panscan': '0'};
  }
}

/// `app.fushi/hdr_video_host` 通道：runner 侧 `HdrVideoHostWindow` 的 Dart 面。
///
/// 非 Windows 平台一切调用都是 no-op（[create] 返回 0）。[channel] 可注入以便单测。
class HdrVideoHostChannel {
  HdrVideoHostChannel({MethodChannel? channel, bool? isWindows})
    : _channel = channel ?? const MethodChannel(channelName),
      _isWindows = isWindows ?? Platform.isWindows {
    if (_isWindows) {
      _channel.setMethodCallHandler(_handleNativeCall);
    }
  }

  static const String channelName = 'app.fushi/hdr_video_host';

  final MethodChannel _channel;
  final bool _isWindows;

  /// 显示器状态变化（`WM_DISPLAYCHANGE`：切 HDR、换显示器、改分辨率）。
  VoidCallback? onDisplayChanged;

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    if (call.method == 'onDisplayChanged') {
      onDisplayChanged?.call();
    }
    return null;
  }

  /// 建宿主窗（幂等：已存在时返回同一句柄），返回 HWND；失败 / 非 Windows 返回 0。
  Future<int> create() async {
    if (!_isWindows) return 0;
    try {
      final dynamic value = await _channel.invokeMethod<dynamic>('create');
      return value is int ? value : 0;
    } on PlatformException {
      return 0;
    } on MissingPluginException {
      return 0;
    }
  }

  /// 宿主窗矩形：主窗**客户区**坐标系的物理像素（runner 自己加客户区屏幕原点）。
  Future<void> setRect(Rect physical) async {
    if (!_isWindows) return;
    try {
      await _channel.invokeMethod<void>('setRect', <String, int>{
        'x': physical.left.round(),
        'y': physical.top.round(),
        'width': physical.width.round(),
        'height': physical.height.round(),
      });
    } on PlatformException {
      // 宿主窗已销毁 / runner 不支持：静默。
    } on MissingPluginException {
      // 非 runner 宿主（单测 / 其它壳）。
    }
  }

  /// 销毁宿主窗并还原主窗（blur-behind 关闭）。幂等。
  Future<void> destroy() async {
    if (!_isWindows) return;
    try {
      await _channel.invokeMethod<void>('destroy');
    } on PlatformException {
      // 已销毁。
    } on MissingPluginException {
      // 非 runner 宿主。
    }
  }

  /// 主窗所在显示器的当前输出色彩空间 / 峰值亮度。
  Future<HdrDisplayInfo> displayInfo() async {
    if (!_isWindows) return HdrDisplayInfo.unknown;
    try {
      final dynamic value = await _channel.invokeMethod<dynamic>('displayInfo');
      if (value is! Map) return HdrDisplayInfo.unknown;
      final Object? cs = value['colorSpace'];
      final Object? lum = value['maxLuminance'];
      final Object? bits = value['bitsPerColor'];
      return HdrDisplayInfo(
        colorSpace: cs is int ? cs : -1,
        maxLuminance: lum is num ? lum.toDouble() : 0,
        bitsPerColor: bits is int ? bits : 0,
      );
    } on PlatformException {
      return HdrDisplayInfo.unknown;
    } on MissingPluginException {
      return HdrDisplayInfo.unknown;
    }
  }
}

/// 把子树（[Video]）在 Flutter 视图里的矩形按物理像素回报给 [onRect]。
///
/// 在 `paint` 里取 `localToGlobal`（此时变换已就绪），只在矩形变化时回调，且推迟到
/// post-frame（回调里会走 MethodChannel，不能在 paint 期间做）。Flutter 视图 =
/// 主窗客户区（runner 把 Flutter 子窗铺满客户区），故这里的全局坐标就是主窗客户区
/// 坐标，runner 再加客户区屏幕原点即宿主窗屏幕位置。
class HdrHostRectReporter extends SingleChildRenderObjectWidget {
  const HdrHostRectReporter({
    super.key,
    required this.onRect,
    required super.child,
  });

  /// 物理像素矩形（主窗客户区坐标系）。
  final ValueChanged<Rect> onRect;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return RenderHdrHostRect(
      onRect: onRect,
      devicePixelRatio: View.of(context).devicePixelRatio,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    RenderHdrHostRect renderObject,
  ) {
    renderObject
      ..onRect = onRect
      ..devicePixelRatio = View.of(context).devicePixelRatio;
  }
}

/// [HdrHostRectReporter] 的 render object。
class RenderHdrHostRect extends RenderProxyBox {
  RenderHdrHostRect({
    required ValueChanged<Rect> onRect,
    required double devicePixelRatio,
  }) : _onRect = onRect,
       _devicePixelRatio = devicePixelRatio;

  ValueChanged<Rect> _onRect;
  set onRect(ValueChanged<Rect> value) => _onRect = value;

  double _devicePixelRatio;
  set devicePixelRatio(double value) {
    if (_devicePixelRatio == value) return;
    _devicePixelRatio = value;
    markNeedsPaint();
  }

  Rect? _lastReported;

  /// 上次回报的物理像素矩形（测试 / 调试用）。
  Rect? get lastReported => _lastReported;

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    final Offset origin = localToGlobal(Offset.zero);
    final Rect physical = Rect.fromLTWH(
      origin.dx * _devicePixelRatio,
      origin.dy * _devicePixelRatio,
      size.width * _devicePixelRatio,
      size.height * _devicePixelRatio,
    );
    if (_lastReported == physical) return;
    _lastReported = physical;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!attached) return;
      _onRect(physical);
    });
  }
}
