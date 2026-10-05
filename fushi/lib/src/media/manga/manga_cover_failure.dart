import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/manga/mihon/mihon_cloudflare_action.dart';
import 'package:fushi/src/media/manga/mihon/mihon_runtime.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_controls.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';

/// 失败态重试按钮的 key（测试与焦点驱动定位用）。
const ValueKey<String> kMangaCoverRetryKey = ValueKey<String>(
  'manga_cover_retry',
);

/// 在线漫画封面的统一失败态（BUG-2450）。
///
/// 错误只分两型：Cloudflare 挑战走既有的 [MihonCloudflareAction]（要用户亲自过
/// 验证，自动重试没有意义）；其它一切错误——超时、5xx、排队超时、4xx——都给一个
/// 可点的重试图标。此前非 Cloudflare 错误渲染成不可点的破图，一张超时的封面只能
/// 靠离开页面再进来救回。
class MangaCoverFailure extends StatelessWidget {
  const MangaCoverFailure({
    required this.error,
    required this.onRetry,
    this.runtime,
    this.backgroundColor,
    super.key,
  });

  final Object? error;
  final VoidCallback onRetry;

  /// Mihon runtime；Aidoku 封面没有挑战求解器，传 null 即恒走重试图标。
  final Object? runtime;
  /// 底色；null 时跟随主题中性色（surfaceContainerHighest），深浅色都可读。
  final Color? backgroundColor;

  @override
  Widget build(BuildContext context) {
    final bool cloudflare = runtime is ChallengeMihonRuntime &&
        mihonCloudflareChallenge(error) != null;
    final Widget action = cloudflare
        ? MihonCloudflareAction(
            runtime: runtime,
            error: error,
            compact: true,
            onVerified: () async => onRetry(),
          )
        : FushiIconButtonControl(
            key: kMangaCoverRetryKey,
            tooltip: t.retry,
            onPressed: onRetry,
            icon: const FushiIcon(Icons.refresh),
          );
    final ColorScheme cs = Theme.of(context).colorScheme;
    return ColoredBox(
      color: backgroundColor ?? cs.surfaceContainerHighest,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            FushiIcon(
              Icons.broken_image_outlined,
              color: cs.onSurfaceVariant,
            ),
            action,
          ],
        ),
      ),
    );
  }
}
