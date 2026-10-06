import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:flutter/material.dart';
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
  final TargetPlatform platform = theme.platform;
  if (platform != TargetPlatform.iOS && platform != TargetPlatform.macOS) {
    return false;
  }
  if (!debugNativeMaterialHostSupported()) return false;
  if (theme.extension<FushiEinkTheme>()?.einkMode ?? false) return false;
  if (highContrast) return false;
  final FushiGlassTheme? glass = theme.extension<FushiGlassTheme>();
  if (glass?.glassDesign ?? false) {
    return glass!.material != FushiGlassMaterial.off;
  }
  return !SystemTransparency.reduceTransparency.value;
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
class FushiNativeMaterialBackdrop extends StatelessWidget {
  const FushiNativeMaterialBackdrop({
    required this.dark,
    required this.borderRadius,
    super.key,
    this.tint,
    this.continuousCorners = false,
  });

  final bool dark;
  final double borderRadius;
  final Color? tint;

  /// Apple 设计系统用连续曲率圆角（superellipse），MD3 用普通圆弧。
  final bool continuousCorners;

  Map<String, Object?> get _params => <String, Object?>{
    'dark': dark,
    'cornerRadius': borderRadius,
    'continuousCorners': continuousCorners,
    if (tint != null) 'tint': tint!.toARGB32(),
  };

  @override
  Widget build(BuildContext context) {
    final Map<String, Object?> params = _params;
    final Key viewKey = ValueKey<String>(
      'native-material:$dark:$borderRadius:$continuousCorners:'
      '${tint?.toARGB32()}',
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
