/// 把一个查词输入框和「查词输入法语言」偏好绑起来。
///
/// 两端的时序要求不一样，所以这里同时做页面级和焦点级：
///
/// - **页面级**（[attach] / [detach]）是 iOS 的刚需：`textInputMode` 在输入框成为
///   第一响应者**之前**就被读，等焦点事件再去通知原生可能已经晚了。页面 mount 远
///   早于任何聚焦，稳。
/// - **焦点级**（focus 监听）是桌面要的精度：Windows/macOS 上切的是**系统全局**
///   输入法，焦点离开查词框就该还原，不能等整页关闭。
///
/// 两者叠加的净效果：进页面就设上（iOS 赶得上），焦点离开就还原（桌面不外溢），
/// 再聚焦再设上。
library;

import 'package:flutter/widgets.dart';
import 'package:fushi/src/lookup/lookup_ime_channel.dart';

class LookupImeBinding {
  LookupImeBinding({required this.languageOf});

  /// 取当前应该用的语言（BCP-47；null = 未设置）。每次同步都重新取——用户可能在
  /// 查词页面还开着的时候改了设置。
  final String? Function() languageOf;

  FocusNode? _focusNode;

  /// 页面 mount 时调。[focusNode] 给了就同时接焦点级同步。
  void attach({FocusNode? focusNode}) {
    _focusNode = focusNode;
    focusNode?.addListener(_syncFromFocus);
    LookupImeChannel.request(this, languageOf());
  }

  /// 页面 dispose 时调。**必须**调：桌面端不还原就会把用户的系统输入法留在我们
  /// 切过去的语言上。
  void detach() {
    _focusNode?.removeListener(_syncFromFocus);
    _focusNode = null;
    // release 而不是 setLanguage(null)：另一个查词入口可能还开着并且还要着日语
    // （桌面上词典主页搜索框聚焦时打开再关掉弹窗词典就是这个情形）。
    LookupImeChannel.release(this);
  }

  void _syncFromFocus() {
    final FocusNode? node = _focusNode;
    if (node == null) return;
    LookupImeChannel.request(this, node.hasFocus ? languageOf() : null);
  }
}
