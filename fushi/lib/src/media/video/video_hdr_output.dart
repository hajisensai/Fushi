import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:fushi_engine/media/video/video_dynamic_range.dart';
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
  /// 显示器处于 HDR 模式且片源是 HDR（bt.2020 + PQ/HLG）时直通，否则纹理路径；
  /// 例外是需要 Dolby Vision 重整的片源（见 [requiresDolbyVisionReshape]），不看
  /// 显示器、一律走宿主窗。
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
/// （`FushiDesktopTitleBar` 的 `ColoredBox(surface)`）包着整个 Navigator、拿不到页面级
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
    this.sdrWhiteNits = 0,
  });

  static const HdrDisplayInfo unknown = HdrDisplayInfo(
    colorSpace: -1,
    maxLuminance: 0,
    bitsPerColor: 0,
  );

  final int colorSpace;
  final double maxLuminance;
  final int bitsPerColor;

  /// Windows「SDR 内容亮度」滑块（`DISPLAYCONFIG_SDR_WHITE_LEVEL`，尼特）：HDR 模式下
  /// DWM 把每个 SDR 窗口（含叠在 HDR 视频上的 Flutter 主窗）的 sRGB 1.0 映射到这个
  /// 亮度。0 = 未知（查询失败 / 旧系统）。
  final double sdrWhiteNits;

  /// 显示器当前是否以 HDR10 输出（判据只看当前 colorspace，不看面板能力——
  /// 面板支持 HDR 但 Windows 没开时仍是 SDR）。
  bool get isHdr => colorSpace == kDxgiColorSpaceHdr10;

  @override
  bool operator ==(Object other) =>
      other is HdrDisplayInfo &&
      other.colorSpace == colorSpace &&
      other.maxLuminance == maxLuminance &&
      other.bitsPerColor == bitsPerColor &&
      other.sdrWhiteNits == sdrWhiteNits;

  @override
  int get hashCode =>
      Object.hash(colorSpace, maxLuminance, bitsPerColor, sdrWhiteNits);

  @override
  String toString() =>
      'HdrDisplayInfo(colorSpace: $colorSpace, maxLuminance: $maxLuminance, '
      'bitsPerColor: $bitsPerColor, sdrWhiteNits: $sdrWhiteNits)';
}

/// 片源是否 HDR：libmpv `video-params/primaries` 为 bt.2020 且 `gamma` 为 PQ / HLG。
///
/// 判据本体已收口到 [VideoDynamicRange]（`video_dynamic_range.dart`）——同一个「这片子
/// 是不是 HDR」原先在 mpv、ffprobe、种子标题三处各写一遍、字符串还各不相同。这里保留
/// 成薄壳是因为直通链路只关心一个 bool，且调用点/单测都以这个名字为准；语义与归一后的
/// [dynamicRangeFromMpv] 逐位等价。
bool isHdrVideoParams({required String? primaries, required String? gamma}) =>
    dynamicRangeFromMpv(primaries: primaries, gamma: gamma).isHdr;

/// 片源是否必须经 Dolby Vision RPU 重整才能出正确颜色：libmpv `video-params/colormatrix`
/// 报 `dolbyvision`。
///
/// 已实测命中的是**不带兼容基础层**的 DV（Profile 5，IPTPQc2 色彩空间，流媒体 WEB-DL
/// 常见）。Profile 7/8 的基础层本身是 HDR10 / HLG，但 mpv 只要 RPU 的
/// `disable_residual_flag=1`（P8.1 即是）就会把 repr 映射成 DOLBYVISION，因此 P8.1
/// **很可能同样命中**并走宿主窗（gpu-next 重整，画面正确但开销更高）——未拿 P8 样片
/// 实测，仅凭 colormatrix 区分不了 P5 与 P8。
/// P5 的像素不是 YCbCr，纹理路径的 `vo=libmpv`（gl_video 渲染器）不认 RPU，直接按
/// 普通 PQ 解就是整片紫/绿「反色」；只有 `vo=gpu-next`（libplacebo）做重整。实测
/// 同一帧 `vo=gpu` 肤色品红、`vo=gpu-next` 正常（先发五虎 S01E01，DoviProfile50）。
bool requiresDolbyVisionReshape(String? colormatrix) =>
    colormatrix == 'dolbyvision';

/// 唯一的模式判据（计划 §4.4）——所有「要不要走宿主窗」都只问这里。
///
/// [sourceDolbyVision]（见 [requiresDolbyVisionReshape]）在 auto 下**不看显示器**：
/// 宿主窗的 gpu-next 在 SDR 屏上照样重整 + 色调映射（与 always 在 SDR 屏上是同一条
/// 路径），而纹理路径对这类片源没有正确画面可出。off 仍然尊重用户：那是显式选择。
bool shouldUseHdrHostWindow({
  required bool isWindows,
  required VideoHdrOutputMode mode,
  required bool displayHdr,
  required bool sourceHdr,
  bool sourceDolbyVision = false,
}) {
  if (!isWindows) return false;
  switch (mode) {
    case VideoHdrOutputMode.off:
      return false;
    case VideoHdrOutputMode.always:
      return true;
    case VideoHdrOutputMode.auto:
      return sourceDolbyVision || (displayHdr && sourceHdr);
  }
}

/// 随包 libmpv 的纹理路径渲染器（gl_video）是否自带 DV Profile 5 重整。
///
/// macOS / iOS / Android 的 libmpv 由 hajisensai 的两个构建仓库出包（mpv 0.36 /
/// master 78d4374，都没编 libplacebo），打了 `mpv-gl-dovi-p5.patch`：gl_video 读帧上的
/// `AV_FRAME_DATA_DOVI_METADATA`，移植 libplacebo 的重整 + IPT→LMS→RGB 解码
/// （BUG-2691）。Windows 用 zhongfly 预编译、没有这个补丁，靠 gpu-next 宿主窗；Linux
/// 用系统 libmpv，能力未知。Android 另有一个前提：帧上要有 DV 元数据，而默认的
/// mediacodec 硬解不解析 RPU——见 [shouldForceSoftwareDecodeForDolbyVision]。
///
/// 随包 libmpv 的产物名由守卫测试钉住（`dolby_vision_bundled_libmpv_guard_test.dart`），
/// 换回没打补丁的构建时这里必须同步改回 false。
bool textureRendererReshapesDolbyVision({
  required bool isApple,
  required bool isAndroid,
}) => isApple || isAndroid;

/// Android 上 DV P5 片源（服务器元数据预先告知）要不要本次开片强制软解。
///
/// 默认 `mediacodec-copy` 硬解走的是独立解码器 `hevc_mediacodec`，不解析 RPU，帧上
/// 没有 DV 元数据，gl_video 的重整补丁就无从下手、照样紫绿；FFmpeg 的 hevc 软解会把
/// RPU 挂到帧上。代价是 4K 10-bit 软解在中低端机上可能掉帧——用户 2026-09-26 拍板
/// 颜色正确优先。
bool shouldForceSoftwareDecodeForDolbyVision({
  required bool isAndroid,
  required bool sourceDolbyVision,
}) => isAndroid && sourceDolbyVision;

/// DV P5 片源在当前平台 / 设置下是否**画不对**，据此提示用户。
///
/// - Windows：只有宿主窗（gpu-next）画得对，所以只有用户把 HDR 输出设成「关闭」时
///   为 true（提示可以打开它）。显示器状态与这个判断无关：DV P5 的宿主窗判据本就
///   不看显示器；
/// - macOS / iOS / Android：纹理路径自带重整（[textureRendererReshapesDolbyVision]；
///   Android 配合 [shouldForceSoftwareDecodeForDolbyVision] 软解），false；
/// - 其它（Linux 系统 libmpv）：true。
bool dolbyVisionColorsUnsupported({
  required bool isWindows,
  bool isApple = false,
  bool isAndroid = false,
  required VideoHdrOutputMode mode,
  required bool sourceDolbyVision,
}) {
  if (!sourceDolbyVision) return false;
  if (isWindows) {
    return !shouldUseHdrHostWindow(
      isWindows: true,
      mode: mode,
      displayHdr: false,
      sourceHdr: true,
      sourceDolbyVision: true,
    );
  }
  return !textureRendererReshapesDolbyVision(
    isApple: isApple,
    isAndroid: isAndroid,
  );
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

/// libmpv 的 HDR 参考白（`MP_REF_WHITE`）：线性输出里 1.0 对应的尼特数。
const double kMpvReferenceWhiteNits = 203;

/// scRGB 的 1.0 对应的尼特数（DWM 的约定）。
const double kScRgbWhiteNits = 80;

/// 合成器内 HDR（视频留在 `vo=libmpv` 纹理里、Flutter 交换链出 scRGB）的三个亮度
/// 参数，按显示器当前状态算一次，引擎与视频纹理各取所需。
@immutable
class CompositorHdrTarget {
  const CompositorHdrTarget({
    required this.engineSdrWhiteNits,
    required this.referenceWhiteNits,
    required this.targetPeakNits,
  });

  /// 交给引擎：Flutter 界面的白（sRGB 1.0）落到多少尼特。
  final double engineSdrWhiteNits;

  /// 交给视频纹理：libmpv 的 203 尼特参考白落到「界面白」的哪里——等于这个值时
  /// 参考白与界面白同亮。
  final double referenceWhiteNits;

  /// 交给 libmpv：色调映射的目标峰值（≤0 = 让 mpv 自己推断）。
  final double targetPeakNits;

  @override
  bool operator ==(Object other) =>
      other is CompositorHdrTarget &&
      other.engineSdrWhiteNits == engineSdrWhiteNits &&
      other.referenceWhiteNits == referenceWhiteNits &&
      other.targetPeakNits == targetPeakNits;

  @override
  int get hashCode =>
      Object.hash(engineSdrWhiteNits, referenceWhiteNits, targetPeakNits);

  @override
  String toString() =>
      'CompositorHdrTarget(engineSdrWhite: $engineSdrWhiteNits, '
      'referenceWhite: $referenceWhiteNits, peak: $targetPeakNits)';
}

/// 唯一的亮度换算判据。
///
/// - HDR 显示器：界面白 = Windows「SDR 内容亮度」；HDR 片源按绝对亮度出（参考白
///   就是 203 尼特，比界面白亮还是暗取决于用户那个滑块）；面板峰值以上才色调映射。
/// - SDR 显示器（「总是」模式）：scRGB 1.0 就是显示器白，DWM 会截掉更高的值，所以
///   参考白对齐界面白、峰值压到参考白——与 mpv 自己输出到 SDR 屏时的约定一致。
CompositorHdrTarget compositorHdrTarget(HdrDisplayInfo display) {
  if (!display.isHdr) {
    return const CompositorHdrTarget(
      engineSdrWhiteNits: kScRgbWhiteNits,
      referenceWhiteNits: kMpvReferenceWhiteNits,
      targetPeakNits: kMpvReferenceWhiteNits,
    );
  }
  final double white = display.sdrWhiteNits > 0
      ? display.sdrWhiteNits
      : kScRgbWhiteNits;
  return CompositorHdrTarget(
    engineSdrWhiteNits: white,
    referenceWhiteNits: white,
    targetPeakNits: display.maxLuminance,
  );
}

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

/// HDR 输出里图形（字幕 / 弹幕）白的亮度：BT.2408 graphics white，也是 libplacebo
/// 的 `PL_COLOR_SDR_WHITE` 与 mpv `sub-hdr-peak` 的默认值——mpv 自己画字幕时就把它
/// 放在这个亮度，片源里的参考白（漫散白）也在这里。
const double kHdrGraphicsWhiteNits = 203;

/// 叠在 HDR 视频上的 Flutter 图形层（字幕 / 弹幕）该乘的**线性**亮度系数。
///
/// 宿主窗模式下视频与图形各走一套亮度基准：mpv（gpu-next，HDR10）把参考白放在
/// [kHdrGraphicsWhiteNits]，而 Flutter 主窗是 SDR 窗口，DWM 把它的白映射到用户的
/// 「SDR 内容亮度」（[HdrDisplayInfo.sdrWhiteNits]，常见 200～480 尼特）。不归一时
/// 字幕比画面里的白亮出一截、像一层贴上去的发光白（用户 2026-10-05 报「HDR 下字幕
/// 颜色怪怪的」，实测该机 SDR 白 280 尼特）。归一后与 mpv 原生字幕同一亮度。
///
/// 只在宿主窗激活且显示器真处于 HDR 时 < 1：纹理路径 / SDR 显示器上视频与 Flutter
/// 同在 SDR 基准里，无需换算。SDR 白低于 203 时 8-bit SDR 窗口无法更亮，取 1。
double hdrGraphicsWhiteScale({
  required bool hostActive,
  required HdrDisplayInfo display,
}) {
  if (!hostActive || !display.isHdr || display.sdrWhiteNits <= 0) return 1;
  final double scale = kHdrGraphicsWhiteNits / display.sdrWhiteNits;
  return scale >= 1 ? 1 : scale;
}

/// 线性亮度系数 → sRGB 编码域的乘数。
///
/// Flutter 在编码域混色、DWM 按 sRGB EOTF 把 SDR 窗口解成线性再乘 SDR 白，所以要让
/// 纯白落在 `scale` 倍线性亮度，编码值得是 sRGB OETF(scale)；其余颜色按幂律近似同比。
double hdrGraphicsEncodedGain(double linearScale) {
  if (linearScale >= 1) return 1;
  if (linearScale <= 0) return 0;
  if (linearScale <= 0.0031308) return 12.92 * linearScale;
  return 1.055 * math.pow(linearScale, 1 / 2.4) - 0.055;
}

/// 把 [child]（字幕 / 弹幕这类画在视频平面上的图形）的亮度按 [linearScale] 压到 HDR
/// 图形白（[hdrGraphicsWhiteScale]）。系数为 1 时不套滤镜（不引入 saveLayer）；进出
/// 直通时子树经 [GlobalKey] 换父节点，字幕层的 State（悬停 / 选词光标 / 拖拽）不重建。
class HdrGraphicsWhiteLevel extends StatefulWidget {
  const HdrGraphicsWhiteLevel({
    super.key,
    required this.linearScale,
    required this.child,
  });

  final double linearScale;
  final Widget child;

  @override
  State<HdrGraphicsWhiteLevel> createState() => _HdrGraphicsWhiteLevelState();
}

class _HdrGraphicsWhiteLevelState extends State<HdrGraphicsWhiteLevel> {
  final GlobalKey _subtreeKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final Widget subtree = KeyedSubtree(key: _subtreeKey, child: widget.child);
    final double gain = hdrGraphicsEncodedGain(widget.linearScale);
    if (gain >= 1) return subtree;
    return ColorFiltered(
      colorFilter: ColorFilter.matrix(<double>[
        gain, 0, 0, 0, 0, //
        0, gain, 0, 0, 0, //
        0, 0, gain, 0, 0, //
        0, 0, 0, 1, 0, //
      ]),
      child: subtree,
    );
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

  /// 引擎是否带合成器内 HDR 输出（打过 `ci/patches/flutter-engine` 补丁、导出了
  /// `FlutterDesktopViewSetHdrOutput`）。原版引擎 / 非 Windows 恒 false。
  Future<bool> compositorHdrSupported() async {
    if (!_isWindows) return false;
    try {
      return await _channel.invokeMethod<bool>('compositorHdrSupported') ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 开 / 关 Flutter 自己交换链的 HDR 输出（FP16 scRGB）。[sdrWhiteNits] 是显示器
  /// 的「SDR 内容亮度」，UI 的白按它显示。返回调用后 HDR 输出是否开着（关闭或
  /// 引擎做不到时为 false）。
  Future<bool> setCompositorHdrOutput({
    required bool enabled,
    required double sdrWhiteNits,
  }) async {
    if (!_isWindows) return false;
    try {
      return await _channel.invokeMethod<bool>(
            'setCompositorHdrOutput',
            <String, Object>{'enabled': enabled, 'sdrWhiteNits': sdrWhiteNits},
          ) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
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
      final Object? white = value['sdrWhiteNits'];
      return HdrDisplayInfo(
        colorSpace: cs is int ? cs : -1,
        maxLuminance: lum is num ? lum.toDouble() : 0,
        bitsPerColor: bits is int ? bits : 0,
        sdrWhiteNits: white is num ? white.toDouble() : 0,
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
