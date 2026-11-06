import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart' show StandardMessageCodec;
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/system_transparency.dart';

/// 原生系统材质平台视图的 viewType（`fushi/apple/FushiNativeMaterialView.swift`
/// 在 macOS / iOS runner 里以同名注册）。
const String kFushiNativeMaterialViewType = 'app.fushi/native_material';

/// 宿主进程是否真能挂原生材质视图（真 macOS / iOS 进程）。测试可覆盖。
///
/// 与 `Theme.platform` 分开判：widget 测试常把 theme 平台改成 iOS / macOS 跑在
/// Windows 宿主上，那里没有原生工厂，挂上 [UiKitView] / [AppKitView] 只会抛。
@visibleForTesting
bool Function() debugNativeMaterialHostSupported = () =>
    !kIsWeb && (Platform.isMacOS || Platform.isIOS);

/// 查词浮层（装原生 WebView 的 [FushiPopupSurface]）能否用**原生系统材质**做
/// 真模糊。
///
/// iOS / macOS 上阅读器 / 视频 / 漫画正文本身是另一个原生平台视图（WKWebView），
/// Flutter 的 [BackdropFilter] 与玻璃着色器都采不到它，只能画不透明面板。改在弹窗
/// WebView 下方垫一层原生 `NSVisualEffectView`（`.withinWindow`）/
/// `UIVisualEffectView`：模糊由系统合成器在窗口内做，采得到背后任何视图。
///
/// 条件与 Flutter 真模糊同口径：非墨水屏、非系统高对比度，且透明度被允许——
/// 玻璃设计系统问材质档（[FushiGlassTheme.material] 已扣除系统「降低透明度」）；
/// MD3 的材质档恒为 off（查词浮层在 MD3 下也是玻璃），直接问系统「降低透明度」
/// （[SystemTransparency]，macOS `accessibilityDisplayShouldReduceTransparency` /
/// iOS `isReduceTransparencyEnabled`）。
bool fushiNativePopupMaterialAvailable({
  required ThemeData theme,
  required bool highContrast,
}) {
  if (!fushiNativePopupBackdropHostAvailable(theme)) return false;
  if (theme.extension<FushiEinkTheme>()?.einkMode ?? false) return false;
  if (highContrast) return false;
  final FushiGlassTheme? glass = theme.extension<FushiGlassTheme>();
  if (glass?.glassDesign ?? false) {
    return glass!.material != FushiGlassMaterial.off;
  }
  return !SystemTransparency.reduceTransparency.value;
}

/// 查词浮层的背衬能否做成**原生平台视图**（[FushiNativeMaterialBackdrop]）：主题
/// 平台是 iOS / macOS，且宿主进程真能挂原生视图（[debugNativeMaterialHostSupported]）。
///
/// 与「能不能真模糊」（[fushiNativePopupMaterialAvailable]）分开：透明度不被允许时
/// 面板改画实底，但这块实底在这两端也必须是原生视图（[FushiNativeMaterialBackdrop]
/// 的 `solidColor`），不能由 Flutter 画（反馈 hQpYQyWJNQ；iOS 26.5 模拟器上用最小
/// 复现实测）。
///
/// iOS 合成规则（Flutter 3.47.6 engine）：查词 WebView 被 [FushiPopupSurface] 的圆角
/// `Clip.antiAlias`（以及描边内缩的 `ClipRRect`）裁剪，平台视图带上非矩形裁剪
/// mutator（kClipRRect），`FlutterPlatformViewsController.mm` 的
/// `HasNonRectClipForUnderlayCutout` 为真。于是**紧跟在这个 WebView 之后**绘制的那段
/// Flutter 内容：overlay 层被 `ApplyNonRectClipToOverlayCanvas` 裁成 WebView 的圆角
/// 形状；`view_slicer.cc` 的 `preserve_underlay` 分支又不在底层画布上挖掉它，这段内容
/// 在形状外的部分只画进**所有平台视图之下**的底层画布，被阅读器 WKWebView 整块盖住。
/// 判据是「前一个平台视图带非矩形裁剪」，不是「与哪个视图相不相交」（`SliceViews`
/// 会拿每段内容和它之前的所有平台视图求交）。
///
/// 所以嵌套层在父层 WebView 之后、自己的原生背衬之前**不许画任何 Flutter 内容**：
/// 原生背衬没有非矩形裁剪，排在它之后的本层内容（外侧投影、描边、顶栏）照常合成。
/// `_ApplePopupGlassBackdrop._buildNativeMaterial` 因此把原生背衬排在 Stack 第一个。
bool fushiNativePopupBackdropHostAvailable(ThemeData theme) {
  final TargetPlatform platform = theme.platform;
  if (platform != TargetPlatform.iOS && platform != TargetPlatform.macOS) {
    return false;
  }
  return debugNativeMaterialHostSupported();
}

/// [fushiNativePopupMaterialAvailable] 的 BuildContext 版。
bool fushiNativePopupMaterialAvailableOf(BuildContext context) {
  return fushiNativePopupMaterialAvailable(
    theme: Theme.of(context),
    highContrast: MediaQuery.maybeHighContrastOf(context) ?? false,
  );
}

/// 原生系统材质背衬：macOS `NSVisualEffectView`（`.withinWindow` + `.active`）/
/// iOS `UIVisualEffectView`（`systemThinMaterial` / `systemMaterial`）。
///
/// 只作**背景槽**用（放在装 WebView 的子树之下的 Stack 兄弟层），永不接收指针：
/// Flutter 侧 [IgnorePointer]，原生侧 macOS `hitTest` 返回 nil、iOS
/// `isUserInteractionEnabled = false`。
///
/// 圆角在原生侧裁（macOS `maskImage`、iOS `layer.cornerRadius`），**不要**在外面
/// 包 [ClipRRect]：平台视图的 clip mutator 会给原生视图的祖先挂 layer mask，
/// 系统材质（backdrop layer）在被 mask 的祖先下会失去模糊。
///
/// [tint] 是叠在材质上的低 alpha 色层（MD3 用主色淡染的面板色；Apple 不传 =
/// 纯系统材质）。参数变化时整视图重建（key 随参数变），平台视图本身很轻。
///
/// [solidColor] 非 null 时不挂系统材质，原生侧只画一块同圆角的实色面板（透明度不被
/// 允许时的实底，见 [fushiNativePopupBackdropHostAvailable] 为何必须是原生视图）。
class FushiNativeMaterialBackdrop extends StatelessWidget {
  const FushiNativeMaterialBackdrop({
    required this.dark,
    required this.borderRadius,
    super.key,
    this.tint,
    this.continuousCorners = false,
    this.solidColor,
  });

  final bool dark;
  final double borderRadius;
  final Color? tint;

  /// 实色面板（不透明）；null = 系统材质。
  final Color? solidColor;

  /// Apple 设计系统用连续曲率圆角（superellipse），MD3 用普通圆弧。
  final bool continuousCorners;

  Map<String, Object?> get _params => <String, Object?>{
    'dark': dark,
    'cornerRadius': borderRadius,
    'continuousCorners': continuousCorners,
    if (tint != null) 'tint': tint!.toARGB32(),
    if (solidColor != null) 'solid': solidColor!.toARGB32(),
  };

  @override
  Widget build(BuildContext context) {
    final Map<String, Object?> params = _params;
    final Key viewKey = ValueKey<String>(
      'native-material:$dark:$borderRadius:$continuousCorners:'
      '${tint?.toARGB32()}:${solidColor?.toARGB32()}',
    );
    final Widget view = Theme.of(context).platform == TargetPlatform.macOS
        ? AppKitView(
            key: viewKey,
            viewType: kFushiNativeMaterialViewType,
            creationParams: params,
            creationParamsCodec: const StandardMessageCodec(),
          )
        : UiKitView(
            key: viewKey,
            viewType: kFushiNativeMaterialViewType,
            creationParams: params,
            creationParamsCodec: const StandardMessageCodec(),
          );
    return IgnorePointer(child: view);
  }
}
