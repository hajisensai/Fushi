import 'package:flutter/material.dart';

import 'package:fushi/src/pages/implementations/dictionary_popup_layer.dart'
    show computeFloatingLyricPopupRect;
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/startup/startup_splash_mark.dart' show DelayedReveal;
import 'package:fushi/src/utils/components/fushi_placeholder_message.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_controls.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 查词冷启动快于这个时长就什么都不画：弹窗直接以词卡出现，不先闪一个加载态。
const Duration kPopupLoadingRevealDelay = Duration(milliseconds: 280);

/// 加载胶囊的尺寸（逻辑像素）。
const Size kPopupLoadingPillSize = Size(148, 36);

/// 系统全局查词（PROCESS_TEXT / 悬浮字幕点字）冷启动、`AppModel` 尚未初始化时的占位。
///
/// 旧实现在透明全屏正中画一个大 [CircularProgressIndicator]，浮在别的 app 上很突兀，
/// 而且加载期间点外面关不掉。这里改成：
///   - 短于 [kPopupLoadingRevealDelay] 的冷启动什么都不显示；
///   - 慢了才在**词卡将要出现的位置**（无锚点贴顶居中；有锚点按词卡同一套避让算法
///     贴被查字）淡入一个带细进度条的小胶囊，词卡接手时不会从屏幕正中跳过去；
///   - 全程点卡片外即 [onDismiss]，与就绪后的「点外面关闭」一致。
class PopupDictionaryLoadingView extends StatelessWidget {
  const PopupDictionaryLoadingView({
    super.key,
    required this.colorScheme,
    required this.onDismiss,
    this.anchorRect,
    this.revealDelay = kPopupLoadingRevealDelay,
  });

  final ColorScheme colorScheme;
  final VoidCallback onDismiss;

  /// 已换算成逻辑像素的避让矩形（整条字幕窗或被查字）；null = 贴顶居中。
  final Rect? anchorRect;
  final Duration revealDelay;

  /// 与词卡同一个外边距（`FushiDesignTokens.spacing.gap` 默认值），起点才对得上。
  static const double _gap = 8;

  @override
  Widget build(BuildContext context) {
    final Widget pill = DelayedReveal(
      delay: revealDelay,
      child: PopupDictionaryLoadingPill(colorScheme: colorScheme),
    );
    final Rect? anchor = anchorRect;
    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onDismiss,
            child: const SizedBox.expand(),
          ),
        ),
        if (anchor == null)
          Align(
            alignment: Alignment.topCenter,
            child: Padding(
              padding: const EdgeInsets.all(_gap),
              child: pill,
            ),
          )
        else
          // Positioned 必须是 Stack 的直接子节点：LayoutBuilder 铺满量出屏幕尺寸后，
          // 在里面再起一层 Stack 放胶囊。
          Positioned.fill(
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                final Rect rect = computeFloatingLyricPopupRect(
                  glyphRect: anchor,
                  screen: Size(constraints.maxWidth, constraints.maxHeight),
                  maxWidth: kPopupLoadingPillSize.width,
                  maxHeight: kPopupLoadingPillSize.height,
                  gap: _gap,
                );
                return Stack(
                  children: <Widget>[
                    Positioned.fromRect(rect: rect, child: pill),
                  ],
                );
              },
            ),
          ),
      ],
    );
  }
}

/// 查词窗冷启动的加载胶囊本体（[kPopupLoadingPillSize]）：surface 胶囊 + 查词
/// 语义图标 + M3E 波浪进度。系统查词弹窗与悬浮词典两个独立 entry point 共用。
class PopupDictionaryLoadingPill extends StatelessWidget {
  const PopupDictionaryLoadingPill({super.key, required this.colorScheme});

  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) {
    return SizedBox.fromSize(
      size: kPopupLoadingPillSize,
      child: Material(
        color: colorScheme.surface,
        elevation: 3,
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        // M3E：查词语义图标 + 波浪进度（FushiLinearProgressIndicator 在 Material
        // 设计系统下即 M3E 波浪），轨道用 secondaryContainer 而不是主色淡染。
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            FushiIcon(
              FushiIcons.lookup,
              size: 18,
              color: colorScheme.primary,
            ),
            const SizedBox(width: 10),
            SizedBox(
              width: 80,
              child: FushiLinearProgressIndicator(
                minHeight: 4,
                borderRadius: const BorderRadius.all(Radius.circular(2)),
                color: colorScheme.primary,
                backgroundColor: colorScheme.secondaryContainer,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 系统全局查词入口初始化失败时的错误态（独立 entry point，冷启动没有 AppModel
/// 主题，由调用方给兜底主题）：贴顶居中一张 M3E 大圆角面板，errorContainer
/// 色块图标 + 原因 + 「关闭」，点面板外同样关窗——旧实现在透明全屏正中只画一行
/// 裸字，浮在别的 app 上既看不清也关不掉。
class PopupDictionaryErrorView extends StatelessWidget {
  const PopupDictionaryErrorView({
    super.key,
    required this.colorScheme,
    required this.message,
    required this.onDismiss,
  });

  final ColorScheme colorScheme;
  final String message;
  final VoidCallback onDismiss;

  static const double _gap = 8;
  static const double _maxWidth = 400;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onDismiss,
            child: const SizedBox.expand(),
          ),
        ),
        Align(
          alignment: Alignment.topCenter,
          child: Padding(
            padding: const EdgeInsets.all(_gap),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: _maxWidth),
              child: FushiStaggeredEntrance(
                index: 0,
                child: Material(
                  color: colorScheme.surface,
                  elevation: 3,
                  shape: const RoundedRectangleBorder(
                    borderRadius: FushiM3eShape.containerLargeRadius,
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 20,
                    ),
                    child: FushiPlaceholderMessage(
                      icon: FushiIcons.error,
                      message: message,
                      tone: FushiPlaceholderTone.error,
                      action: FushiFilledButton.tonal(
                        key: const ValueKey<String>('popup_init_error_close'),
                        onPressed: onDismiss,
                        child: Text(t.dialog_close),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
