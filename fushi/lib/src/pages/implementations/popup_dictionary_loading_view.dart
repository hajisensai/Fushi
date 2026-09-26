import 'package:flutter/material.dart';

import 'package:fushi/src/pages/implementations/dictionary_popup_layer.dart'
    show computeFloatingLyricPopupRect;
import 'package:fushi/src/startup/startup_splash_mark.dart' show DelayedReveal;

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
      child: SizedBox.fromSize(
        size: kPopupLoadingPillSize,
        child: Material(
          color: colorScheme.surface,
          elevation: 3,
          shape: const StadiumBorder(),
          clipBehavior: Clip.antiAlias,
          child: Center(
            child: SizedBox(
              width: 88,
              child: LinearProgressIndicator(
                minHeight: 4,
                borderRadius: const BorderRadius.all(Radius.circular(2)),
                color: colorScheme.primary,
                backgroundColor: colorScheme.primary.withValues(alpha: 0.16),
              ),
            ),
          ),
        ),
      ),
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
