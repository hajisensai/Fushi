import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 制卡队列重放给用户看的状态（手动点「制作队列中的卡片」与空闲自动制卡共用）：跑的期间是
/// 进度，结束后留一枚结果胶囊直到用户关掉（空闲时人不在电脑前，Toast 早过期了；全屏时顶栏
/// 标题也看不到）。
sealed class WebMineAutoStatus {
  const WebMineAutoStatus();
}

/// 正在重放：已处理 [done] / 共 [total]；[auto] = 空闲自动制卡（文案提示「有操作即暂停」）。
final class WebMineAutoRunning extends WebMineAutoStatus {
  const WebMineAutoRunning({
    required this.done,
    required this.total,
    this.auto = true,
  });
  final int done;
  final int total;
  final bool auto;
}

/// 一轮结束：成功 [ok]、失败 [failed]；[remaining] > 0 = 用户回来让位、余下的留在队列。
final class WebMineAutoFinished extends WebMineAutoStatus {
  const WebMineAutoFinished({
    required this.ok,
    required this.failed,
    required this.remaining,
    this.auto = true,
  });
  final int ok;
  final int failed;
  final int remaining;
  final bool auto;
}

/// 静音录音起不来（系统不支持 process loopback / 找不到 WebView2 进程），本轮跳过——
/// 绝不退回会外放的系统混音。
final class WebMineAutoUnavailable extends WebMineAutoStatus {
  const WebMineAutoUnavailable();
}

/// 顶部居中的状态胶囊：状态切换交叉淡入 + 自上滑入（时长走 [fushiMotionDuration]，
/// 墨水屏 / 减弱动态效果下直接到位）；结果态带关闭钮。
class WebMineAutoStatusChip extends StatelessWidget {
  const WebMineAutoStatusChip({
    required this.status,
    required this.onDismiss,
    super.key,
  });

  /// null = 不显示。
  final WebMineAutoStatus? status;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final WebMineAutoStatus? s = status;
    return AnimatedSwitcher(
      duration: fushiMotionDuration(context, FushiMotion.medium),
      reverseDuration: fushiMotionDuration(context, FushiMotion.short),
      switchInCurve: FushiMotion.enter,
      switchOutCurve: FushiMotion.enter,
      transitionBuilder: (Widget child, Animation<double> animation) =>
          FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, -0.4),
                end: Offset.zero,
              ).animate(animation),
              child: child,
            ),
          ),
      child: s == null
          ? const SizedBox.shrink(key: ValueKey<String>('web-mine-auto-none'))
          : _chip(context, s),
    );
  }

  Widget _chip(BuildContext context, WebMineAutoStatus s) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final (IconData icon, String text, bool dismissible) = switch (s) {
      WebMineAutoRunning(:final int done, :final int total, :final bool auto) =>
        (
          FushiIcons.ankiCard,
          auto
              ? t.web_video_mine_auto_running(done: done, total: total)
              : t.web_video_mine_queue_running(done: done, total: total),
          false,
        ),
      WebMineAutoFinished(
        :final int ok,
        :final int failed,
        :final int remaining,
        :final bool auto,
      ) =>
        (
          failed > 0 ? FushiIcons.warning : FushiIcons.check,
          !auto
              ? t.web_video_mine_queue_finished(ok: ok, failed: failed)
              : remaining > 0
              ? t.web_video_mine_auto_paused(
                  ok: ok,
                  failed: failed,
                  count: remaining,
                )
              : t.web_video_mine_auto_finished(ok: ok, failed: failed),
          true,
        ),
      WebMineAutoUnavailable() => (
        FushiIcons.error,
        t.web_video_mine_auto_unavailable,
        true,
      ),
    };
    return Material(
      key: ValueKey<String>('web-mine-auto-${s.runtimeType}'),
      color: cs.inverseSurface,
      shape: const StadiumBorder(),
      elevation: 3,
      child: Padding(
        padding: EdgeInsetsDirectional.only(
          start: 16,
          end: dismissible ? 4 : 16,
          top: 8,
          bottom: 8,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            FushiIcon(icon, size: 18, color: cs.onInverseSurface),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                text,
                style: Theme.of(
                  context,
                ).textTheme.labelLarge?.copyWith(color: cs.onInverseSurface),
              ),
            ),
            if (dismissible) ...<Widget>[
              const SizedBox(width: 4),
              FushiPressScale(
                child: IconButton(
                  tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                  iconSize: 18,
                  color: cs.onInverseSurface,
                  onPressed: onDismiss,
                  icon: const FushiIcon(FushiIcons.close),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
