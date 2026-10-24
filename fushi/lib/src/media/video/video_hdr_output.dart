import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:fushi_engine/media/video/video_dynamic_range.dart';

/// Windows HDR / 10-bit 输出（`docs/specs/2026-10-06-hdr-in-flutter-compositor.md`）。
///
/// 视频始终是 Flutter 里的一张纹理（`vo=libmpv` → ANGLE 共享纹理）。HDR 输出时打了
/// `ci/patches/flutter-engine` 补丁的引擎把自己的交换链切成 FP16 scRGB，视频纹理切成
/// RGBA16F 线性光，界面与视频在同一张画布、同一次 present 里合成；不输出 HDR 时就是
/// 普通 8-bit 纹理，HDR 片源由 mpv 色调映射到 SDR。
///
/// 早先另有一条「宿主窗直通」：libmpv 的 `vo=gpu-next` 画进钉在主窗正后方的独立顶层
/// 窗口，主窗挖洞透出它。两个窗口在全屏切换 / 移动 / 层级变化时会错位（BUG-2964），
/// 合成器内 HDR 落地后它只剩杜比视界 P5 与引擎不支持时的退路；Windows 随包 libmpv
/// 打上 `mpv-gl-dovi-p5.patch` 后连这条退路也不需要了，整套宿主窗已删除。
///
/// 模式切换不重建 Player：字幕轨、进度、着色器全部保留。
enum VideoHdrOutputMode {
  /// 显示器处于 HDR 模式且片源是 HDR（bt.2020 + PQ/HLG）时输出 HDR，否则 SDR。
  auto('auto'),

  /// 只要在 Windows 就输出 HDR / 10-bit（SDR 片源也受益于更高位深）。
  always('always'),

  /// 永远 SDR 输出。
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
/// 成薄壳是因为 HDR 输出判据只关心一个 bool，且调用点/单测都以这个名字为准；语义与归一后的
/// [dynamicRangeFromMpv] 逐位等价。
bool isHdrVideoParams({required String? primaries, required String? gamma}) =>
    dynamicRangeFromMpv(primaries: primaries, gamma: gamma).isHdr;

/// 片源是否带杜比视界 RPU：libmpv `video-params/colormatrix` 报 `dolbyvision`。
///
/// 实测命中两类（`tool/bluray/verify_dovi_p5.py`）：不带兼容基础层的 Profile 5
/// （IPTPQc2 色彩空间，流媒体 WEB-DL 常见），以及 RPU `disable_residual_flag=1` 的
/// Profile 8.1——后者的基础层本身就是 HDR10。P5 的像素不是 YCbCr，不经 RPU 重整
/// 直接按普通 PQ 解就是整片紫/绿「反色」（BUG-2691，先发五虎 S01E01，DoviProfile50）；
/// 纹理渲染器 gl_video 靠 `mpv-gl-dovi-p5.patch` 做重整（见
/// [textureRendererReshapesDolbyVision]），P8.1 则由补丁原样放过、显示 HDR10 基础层。
bool requiresDolbyVisionReshape(String? colormatrix) =>
    colormatrix == 'dolbyvision';

/// 要不要输出 HDR（合成器内 HDR，见文件头）。唯一判据。
///
/// 杜比视界不参与：纹理路径自己会重整（[textureRendererReshapesDolbyVision]），按普通
/// HDR 片源走同一条判据即可。off 永远 SDR——那是用户的显式选择。
bool shouldUseHdrOutput({
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

/// 随包 libmpv 的纹理路径渲染器（gl_video）是否自带 DV Profile 5 重整。
///
/// 四个平台的随包 libmpv 都打了 `tool/bluray/platforms/patches/mpv-gl-dovi-p5.patch`：
/// gl_video 读帧上的 `AV_FRAME_DATA_DOVI_METADATA`，移植 libplacebo 的重整 +
/// IPT→LMS→RGB 解码（BUG-2691）。Windows 是 `third_party/media_kit_libs_windows_video`
/// 的 `-dovi1` 归档（d3d11va 零拷贝 / 拷回 / 软解实测与 libplacebo 同色），macOS / iOS /
/// Android 是各自插件 `native/` 下的产物。Linux 用系统 libmpv，能力未知。Android 另有一个
/// 前提：帧上要有 DV 元数据，而默认的 mediacodec 硬解不解析 RPU——见
/// [shouldForceSoftwareDecodeForDolbyVision]；Windows 的 d3d11va 是 FFmpeg 自己的 hevc
/// 解码器加硬件加速，RPU 照常挂到帧上。
///
/// 随包 libmpv 的产物名由守卫测试钉住（`dolby_vision_bundled_libmpv_guard_test.dart`），
/// 换回没打补丁的构建时这里必须同步改回 false。
bool textureRendererReshapesDolbyVision({
  required bool isWindows,
  required bool isApple,
  required bool isAndroid,
}) => isWindows || isApple || isAndroid;

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

/// DV P5 片源在当前平台上是否**画不对**，据此提示用户：只有纹理渲染器不会重整的平台
/// （Linux 系统 libmpv）为 true。
bool dolbyVisionColorsUnsupported({
  bool isWindows = false,
  bool isApple = false,
  bool isAndroid = false,
  required bool sourceDolbyVision,
}) {
  if (!sourceDolbyVision) return false;
  return !textureRendererReshapesDolbyVision(
    isWindows: isWindows,
    isApple: isApple,
    isAndroid: isAndroid,
  );
}

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

/// 合成器内 HDR 某一步没成时该怎么退：失败的**层级**决定记忆的范围。三种都留在 SDR
/// 纹理路径上（HDR 片源由 mpv 色调映射），不存在别的输出窗口可退。
enum CompositorHdrFallback {
  /// 引擎没开成（原版引擎 / 引擎产物缺 Impeller 路径补丁 / ANGLE 缺扩展）：进程内不会变，记成「不支持」。
  engineUnsupported,

  /// 视频纹理还没建好：先保持 SDR，纹理就绪后重判，不记任何失败。
  awaitTexture,

  /// 这一路纹理拒绝切 HDR：只对当前 Player 记住，换片后再试。
  textureRefused,
}

/// 合成器内 HDR 进入失败时的分流（[engineOn]：引擎交换链切成功；[textureReady]：
/// 视频纹理已建好；[textureOn]：纹理切成功）。都成功返回 null。
///
/// 早先任何一步失败都把整个进程记成「不支持」，一次偶发（纹理晚一帧建好）就让 HDR
/// 一直不可用直到重启 app。
CompositorHdrFallback? compositorHdrFallback({
  required bool engineOn,
  required bool textureReady,
  required bool textureOn,
}) {
  if (!engineOn) return CompositorHdrFallback.engineUnsupported;
  if (!textureReady) return CompositorHdrFallback.awaitTexture;
  if (!textureOn) return CompositorHdrFallback.textureRefused;
  return null;
}

/// HDR 输出里图形（字幕 / 弹幕）白的亮度：BT.2408 graphics white，也是 libplacebo
/// 的 `PL_COLOR_SDR_WHITE` 与 mpv `sub-hdr-peak` 的默认值——mpv 自己画字幕时就把它
/// 放在这个亮度，片源里的参考白（漫散白）也在这里。
const double kHdrGraphicsWhiteNits = 203;

/// 叠在 HDR 视频上的 Flutter 图形层（字幕 / 弹幕）该乘的**线性**亮度系数。
///
/// HDR 输出时视频与界面各有一个亮度基准：mpv 把片源参考白放在
/// [kHdrGraphicsWhiteNits]，而 Flutter 界面的白落在用户的「SDR 内容亮度」
/// （[HdrDisplayInfo.sdrWhiteNits]，常见 200～480 尼特）。不归一时字幕比画面里的白亮出
/// 一截、像一层贴上去的发光白（用户 2026-10-05 报「HDR 下字幕颜色怪怪的」，实测该机
/// SDR 白 280 尼特；BUG-2951）。归一后与 mpv 原生字幕同一亮度。
///
/// 只在 HDR 输出激活且显示器真处于 HDR 时 < 1：SDR 输出 / SDR 显示器上视频与 Flutter
/// 同在 SDR 基准里，无需换算。SDR 白低于 203 时界面无法更亮，取 1。
double hdrGraphicsWhiteScale({
  required bool outputActive,
  required HdrDisplayInfo display,
}) {
  if (!outputActive || !display.isHdr || display.sdrWhiteNits <= 0) return 1;
  final double scale = kHdrGraphicsWhiteNits / display.sdrWhiteNits;
  return scale >= 1 ? 1 : scale;
}

/// 线性亮度系数 → sRGB 编码域的乘数。
///
/// Flutter 在编码域混色，所以要让纯白落在 `scale` 倍线性亮度，编码值得是
/// sRGB OETF(scale)；其余颜色按幂律近似同比。
double hdrGraphicsEncodedGain(double linearScale) {
  if (linearScale >= 1) return 1;
  if (linearScale <= 0) return 0;
  if (linearScale <= 0.0031308) return 12.92 * linearScale;
  return 1.055 * math.pow(linearScale, 1 / 2.4) - 0.055;
}

/// 把 [child]（字幕 / 弹幕这类画在视频平面上的图形）的亮度按 [linearScale] 压到 HDR
/// 图形白（[hdrGraphicsWhiteScale]）。系数为 1 时不套滤镜（不引入 saveLayer）；进出
/// HDR 输出时子树经 [GlobalKey] 换父节点，字幕层的 State（悬停 / 选词光标 / 拖拽）不重建。
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

/// `app.fushi/hdr_output` 通道：runner 侧显示器 HDR 查询与合成器 HDR 开关的 Dart 面。
///
/// 非 Windows 平台一切调用都是 no-op。[channel] 可注入以便单测。
class HdrOutputChannel {
  HdrOutputChannel({MethodChannel? channel, bool? isWindows})
    : _channel = channel ?? const MethodChannel(channelName),
      _isWindows = isWindows ?? Platform.isWindows {
    if (_isWindows) {
      _channel.setMethodCallHandler(_handleNativeCall);
    }
  }

  static const String channelName = 'app.fushi/hdr_output';

  final MethodChannel _channel;
  final bool _isWindows;

  /// 显示器状态变化（`WM_DISPLAYCHANGE`：切 HDR、换显示器、改分辨率；HDR 输出开着时
  /// 主窗重新激活也算——「SDR 内容亮度」滑块改了不发任何窗口消息）。
  VoidCallback? onDisplayChanged;

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    if (call.method == 'onDisplayChanged') {
      onDisplayChanged?.call();
    }
    return null;
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
