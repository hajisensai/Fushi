import 'dart:async';

import 'package:flutter_inappwebview_android/flutter_inappwebview_android.dart'
    show AndroidWebViewStaticLayer;

import 'package:fushi/src/utils/misc/platform_utils.dart';

/// 给某个 WebView（按 `InAppWebViewController.getViewId()`）开 / 关静态硬件层。
/// 返回是否真的生效（非 Hybrid Composition / 视图已销毁时 false）。
typedef WebViewStaticLayerSetter =
    Future<bool> Function(Object viewId, {required bool enabled});

/// 取宿主「正文 WebView」此刻的 viewId；正文还没建好 / 本页没有 WebView 正文返回 null。
typedef PopupBodyViewIdResolver = Object? Function();

/// 本平台的静态层开关：只有 Android（fork 的 `flutter_inappwebview_android` 在
/// Hybrid Composition 下默认不挂硬件层）才有；其它平台返回 null，闸门整体 no-op。
WebViewStaticLayerSetter? platformWebViewStaticLayerSetter() =>
    isAndroidPlatform ? AndroidWebViewStaticLayer.set : null;

/// 查词弹窗宿主上「正文 WebView」的提供方：阅读器 / 漫画 / 网页视频页的 State，
/// 以及复习卡面 / 浏览器标签页这类 [SrsCardLookupHost] 取词表面。
abstract interface class PopupBodyWebViewProvider {
  /// 正文 WebView 此刻的 viewId（`InAppWebViewController.getViewId()`）；没有返回 null。
  Object? get popupBodyWebViewId;
}

/// 查词弹窗打开期间给宿主正文 WebView 开静态硬件层的闸门（纯逻辑，可单测）。
///
/// fork 的 Android WebView 在 Hybrid Composition 下默认 `LAYER_TYPE_NONE`（滚动时每帧
/// 重画整屏离屏层太贵）。唯一吃亏的场景是正文静止、上面叠着的查词弹窗 WebView 在动
/// （滚动 / 开关动画）：没有层时弹窗每出一帧，窗口都要把正文的绘制再跑一遍（120Hz
/// 平板实测弹窗滚动 80 → 61 fps）。所以弹窗打开时给正文开层，全部关闭时关掉。正文在
/// 弹窗开着时自己滚动，最多退回到「一直开层」的旧现状，不必检测滚动。
///
/// 唯一收口点是 [DictionaryPopupController]：它在每次栈变化后调 [popupOpenChanged]；
/// 宿主只负责设 [resolveBody]，并在正文 WebView 新建 / 重建（`onWebViewCreated`）或
/// 切换正文时调 [bodyChanged]。新建的 WebView 默认没有层，闸门按 viewId 记账：
/// 换了 viewId 就先关旧的（已销毁的视图那边是 no-op）、再给新的开。
class PopupBodyStaticLayerGate {
  PopupBodyStaticLayerGate({WebViewStaticLayerSetter? setter})
    : _setter = setter;

  final WebViewStaticLayerSetter? _setter;

  /// 宿主注入：取正文 WebView 的 viewId。没设 = 本宿主没有 WebView 正文。
  PopupBodyViewIdResolver? resolveBody;

  bool _popupOpen = false;
  Object? _layeredViewId;

  /// 弹窗（含搜索期占位）此刻是否在屏上。
  bool get popupOpen => _popupOpen;

  /// 当前被开了层的正文 viewId（null = 没有开层的正文）。
  Object? get layeredViewId => _layeredViewId;

  /// 弹窗栈的「是否有弹窗在屏上」变化。同值重复调用是 no-op。
  void popupOpenChanged(bool open) {
    if (open == _popupOpen) return;
    _popupOpen = open;
    _sync();
  }

  /// 正文 WebView 新建 / 重建 / 换了一个：弹窗开着时把层挪到新的正文上。
  void bodyChanged() => _sync();

  /// 宿主销毁：关掉开着的层，之后不再调用。
  void dispose() {
    _popupOpen = false;
    _sync();
    resolveBody = null;
  }

  void _sync() {
    final WebViewStaticLayerSetter? setter = _setter;
    if (setter == null) return;
    final Object? target = _popupOpen ? resolveBody?.call() : null;
    final Object? previous = _layeredViewId;
    if (target == previous) return;
    _layeredViewId = target;
    if (previous != null) unawaited(setter(previous, enabled: false));
    if (target != null) unawaited(setter(target, enabled: true));
  }
}
