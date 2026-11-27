import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/adaptive/fushi_page_backdrop.dart';
import 'package:fushi/src/utils/adaptive/fushi_page_transitions.dart';
import 'package:fushi/src/utils/adaptive/predictive_back_page_transitions.dart';

/// Apple 设计系统：全平台 Cupertino 推入转场（右侧滑入、旧页视差左移 + 压暗，
/// 边缘侧滑返回跟手），与 iOS 26 / macOS 26 的导航栈同一套运动。
/// Android 不再挂预测返回 builder：Cupertino 转场不接平台预测返回事件，
/// 系统返回键 / 手势照常 pop，也就不存在那套手势计数失配的口子。
/// 系统「减弱动态效果」下 [FushiCupertinoPageTransitionsBuilder] 退化成原地
/// 线性淡入（无推入视差），边缘侧滑返回仍装着（见该类注释）。
///
/// 同样套 [FushiBackdropPageTransitionsBuilder]：用户自选的背景图片在 Apple
/// 下也要画（设置页提示「自定义图片所有设计都显示」）。形状类预设在 Apple
/// 下由 `LibraryShapeBackdrop.enabledFor` 判为不画，那时背景层不改底色、
/// 不画装饰，与不套等价。
///
/// 是 const 单例：[FushiMaterialTransitionPageRoute] 靠 `identical` 认出「当前是
/// Apple 设计系统的转场」。
const PageTransitionsTheme fushiApplePageTransitionsTheme =
    PageTransitionsTheme(
      builders: <TargetPlatform, PageTransitionsBuilder>{
        TargetPlatform.android: FushiBackdropPageTransitionsBuilder(
          FushiCupertinoPageTransitionsBuilder(),
        ),
        TargetPlatform.iOS: FushiBackdropPageTransitionsBuilder(
          FushiCupertinoPageTransitionsBuilder(),
        ),
        TargetPlatform.macOS: FushiBackdropPageTransitionsBuilder(
          FushiCupertinoPageTransitionsBuilder(),
        ),
        TargetPlatform.windows: FushiBackdropPageTransitionsBuilder(
          FushiCupertinoPageTransitionsBuilder(),
        ),
        TargetPlatform.linux: FushiBackdropPageTransitionsBuilder(
          FushiCupertinoPageTransitionsBuilder(),
        ),
        TargetPlatform.fuchsia: FushiBackdropPageTransitionsBuilder(
          FushiCupertinoPageTransitionsBuilder(),
        ),
      },
    );

/// Material（M3E）设计系统的页面转场。
///
/// Android 侧滑返回改走自带手势记账的转场：Flutter 自带实现把平台事件直接
/// 转成 navigator 的手势计数增减，平台重发起始事件 / 手势中途路由被 pop 都
/// 会让计数失配，而计数一旦卡住，每层路由都被 IgnorePointer——画面正常但整个
/// app 点不动（见 [FushiPredictiveBackPageTransitionsBuilder] 类注释）。
/// 其余平台必须逐个列出：PageTransitionsTheme 的 builders 是全量替换，漏一个
/// 平台它就回落到 ZoomPageTransitionsBuilder（iOS/macOS 会因此丢掉 Cupertino
/// 的边缘滑动返回）。
///
/// 每个 builder 外面套一层 [FushiBackdropPageTransitionsBuilder]：每页垫
/// 页面底色 + 角落 M3E 形状背景（2026-10-25 用户拍板「整个应用都加」）。
const PageTransitionsTheme fushiMaterialPageTransitionsTheme =
    PageTransitionsTheme(
      builders: <TargetPlatform, PageTransitionsBuilder>{
        TargetPlatform.android: FushiBackdropPageTransitionsBuilder(
          FushiPredictiveBackPageTransitionsBuilder(),
        ),
        TargetPlatform.iOS: FushiBackdropPageTransitionsBuilder(
          FushiNativeCupertinoPageTransitionsBuilder(),
        ),
        TargetPlatform.macOS: FushiBackdropPageTransitionsBuilder(
          FushiNativeCupertinoPageTransitionsBuilder(),
        ),
        // 桌面：原地淡入、不位移（2026-10 动效重做）。Zoom 的整窗缩放位移
        // 随窗口尺寸线性增长，大屏上很重，见该 builder 类注释。
        TargetPlatform.windows: FushiBackdropPageTransitionsBuilder(
          FushiSharedAxisPageTransitionsBuilder(),
        ),
        TargetPlatform.linux: FushiBackdropPageTransitionsBuilder(
          FushiSharedAxisPageTransitionsBuilder(),
        ),
        TargetPlatform.fuchsia: FushiBackdropPageTransitionsBuilder(
          FushiSharedAxisPageTransitionsBuilder(),
        ),
      },
    );

/// 不论当前是哪套设计系统，都按 **Material 设计系统** 的转场进出的页面路由。
///
/// 给小说阅读器用（用户 2026-11-27：小说进入 / 退出 Material 与 Cupertino 不一致，
/// Cupertino 下会闪一下，以 Material 那种为准）。阅读器整页是 WebView 平台视图，
/// Apple 设计系统的横向推入 + 旧页视差在桌面 / Android 上要把整块 WebView 跟着
/// 平移合成，进出时闪；Material 那套（桌面原地淡入上滑、Android 预测返回的
/// fade-forwards、iOS / macOS 原生 Cupertino）不闪。
///
/// 只在当前主题是 [fushiApplePageTransitionsTheme] 时换成
/// [fushiMaterialPageTransitionsTheme]；Material 与墨水屏主题原样沿用（墨水屏要一帧
/// 换页），所以 Material 设计系统下与普通 [MaterialPageRoute] 逐帧相同。换的不止
/// 本页转场：时长、以及**被盖住那页**的配合动画（[delegatedTransition]）也取
/// Material 那套，底下的页不会还按 Cupertino 视差左移。
///
/// 与设计系统控件外观无关（纯动效层），不分 M3E / Cupertino 两支。
class FushiMaterialTransitionPageRoute<T> extends MaterialPageRoute<T> {
  FushiMaterialTransitionPageRoute({
    required super.builder,
    super.settings,
    super.fullscreenDialog,
  });

  static bool _isAppleTheme(BuildContext context) => identical(
    Theme.of(context).pageTransitionsTheme,
    fushiApplePageTransitionsTheme,
  );

  static PageTransitionsTheme _effectiveTheme(BuildContext context) =>
      _isAppleTheme(context)
      ? fushiMaterialPageTransitionsTheme
      : Theme.of(context).pageTransitionsTheme;

  /// Apple 主题下换成的 Material builder；不换时为 null（走父类的主题查找）。
  PageTransitionsBuilder? _swappedBuilder() {
    final NavigatorState? nav = navigator;
    if (nav == null || !_isAppleTheme(nav.context)) return null;
    return fushiMaterialPageTransitionsTheme.builders[Theme.of(
      nav.context,
    ).platform];
  }

  @override
  Duration get transitionDuration =>
      _swappedBuilder()?.transitionDuration ?? super.transitionDuration;

  @override
  Duration get reverseTransitionDuration =>
      _swappedBuilder()?.reverseTransitionDuration ??
      super.reverseTransitionDuration;

  @override
  DelegatedTransitionBuilder? get delegatedTransition {
    final PageTransitionsBuilder? swapped = _swappedBuilder();
    // 不换时必须原样返回父类的那个静态函数：同一函数 = 下层路由不收委托、照常用
    // 自己的 secondaryAnimation，与普通 MaterialPageRoute 完全一致。
    if (swapped == null) return super.delegatedTransition;
    return swapped.delegatedTransition;
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return _effectiveTheme(
      context,
    ).buildTransitions<T>(this, context, animation, secondaryAnimation, child);
  }
}
