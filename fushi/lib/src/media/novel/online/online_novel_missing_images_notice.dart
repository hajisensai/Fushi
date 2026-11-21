import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/novel/online/online_novel_missing_images.dart';
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 阅读器顶部的缺图提示：「本章有 N 张插图没取到」+「重新获取插图」+ 关闭。
///
/// 悬浮胶囊（[FushiFloatingToolbarSurface]：MD3 = M3E 悬浮工具栏，Apple = 液态
/// 玻璃胶囊），不占正文位置、不触发重排；出现 / 消失走淡入 + 下滑（时长取
/// [FushiMotion]，减弱动态效果时瞬间到位）。没有提示时零尺寸。
class OnlineNovelMissingImagesNoticeBar extends StatelessWidget {
  const OnlineNovelMissingImagesNoticeBar({
    required this.controller,
    super.key,
  });

  final OnlineNovelMissingImagesController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (BuildContext context, Widget? _) {
        final OnlineNovelMissingImagesNotice? notice = controller.notice;
        return AnimatedSwitcher(
          duration: fushiMotionDuration(context, FushiMotion.medium),
          reverseDuration: fushiMotionDuration(context, FushiMotion.short),
          switchInCurve: FushiMotion.enter,
          switchOutCurve: FushiMotion.exit,
          transitionBuilder: (Widget child, Animation<double> animation) =>
              FadeTransition(
                opacity: fushiUnitClamped(animation),
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0, -0.4),
                    end: Offset.zero,
                  ).animate(animation),
                  child: child,
                ),
              ),
          child: notice == null
              ? const SizedBox.shrink(key: ValueKey<String>('none'))
              : _NoticePill(
                  key: ValueKey<int>(notice.chapter),
                  notice: notice,
                  onRetry: controller.retry,
                  onDismiss: controller.dismiss,
                ),
        );
      },
    );
  }
}

class _NoticePill extends StatelessWidget {
  const _NoticePill({
    required this.notice,
    required this.onRetry,
    required this.onDismiss,
    super.key,
  });

  final OnlineNovelMissingImagesNotice notice;
  final VoidCallback onRetry;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final String message = t.novel_online_images_missing(n: notice.count);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560),
      child: Semantics(
        container: true,
        liveRegion: true,
        label: message,
        child: FushiFloatingToolbarSurface(
          padding: const EdgeInsetsDirectional.only(start: 16, end: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const FushiIcon(FushiIcons.brokenImage, size: 20),
              const SizedBox(width: 8),
              Flexible(
                child: ExcludeSemantics(
                  child: Text(
                    message,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.fushiType.bodyMedium,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              FushiPressScale(
                enabled: !notice.retrying,
                child: FushiTextButton(
                  key: const ValueKey<String>('missing_images_retry'),
                  onPressed: notice.retrying ? null : onRetry,
                  child: notice.retrying
                      ? const SizedBox.square(
                          dimension: 18,
                          child: FushiCircularProgressIndicator.adaptive(
                            strokeWidth: 2,
                          ),
                        )
                      : Text(t.novel_online_images_retry),
                ),
              ),
              FushiIconButtonControl(
                key: const ValueKey<String>('missing_images_dismiss'),
                tooltip: t.novel_online_images_dismiss,
                onPressed: onDismiss,
                icon: const FushiIcon(FushiIcons.close, size: 20),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
