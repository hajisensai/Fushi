import 'dart:async';

import 'package:flutter/material.dart';

import 'package:fushi/src/lookup/gal_hook_text_overlay_controller.dart';

/// 把主窗口当前主题实时转交给 Windows galgame Hook 台词浮窗。
///
/// 浮窗与它的独立工具条是 native D2D 分层窗口，拿不到 Flutter 的 [Theme]；配色
/// 只能由 Dart 算好 ARGB 下发（[galHookToolbarPalette]）。本组件挂在主窗口导航
/// 之上、依赖 [Theme.of]，所以预设 / 明暗 / 纯黑 / 自定义主题 / 设计系统一变就
/// 重建一次，把新主题交给控制器；配色真变了控制器才重推样式。自身不画任何东西。
class GalHookOverlayThemeSync extends StatelessWidget {
  const GalHookOverlayThemeSync({super.key});

  @override
  Widget build(BuildContext context) {
    if (GalHookTextOverlayController.isSupported) {
      final ThemeData theme = Theme.of(context);
      // build 里不直接发平台消息：排到本帧之后。
      scheduleMicrotask(
        () => GalHookTextOverlayController.instance.applyTheme(theme),
      );
    }
    return const SizedBox.shrink();
  }
}
