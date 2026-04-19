import 'package:flutter/material.dart';
import 'package:hibiki/src/media/audiobook/audiobook_controller.dart';

/// 有声书播放控制条（紧凑型，固定于阅读器底部）。
///
/// 通过 [ListenableBuilder] 监听 [AudiobookPlayerController] 即可实现响应式更新：
/// ```dart
/// ListenableBuilder(
///   listenable: controller,
///   builder: (_, __) => AudiobookPlayBar(controller: controller),
/// )
/// ```
class AudiobookPlayBar extends StatelessWidget {
  const AudiobookPlayBar({required this.controller, super.key});

  final AudiobookPlayerController controller;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: BottomAppBar(
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.skip_previous),
              iconSize: 22,
              onPressed: controller.skipToPrevCue,
              tooltip: '上一句',
            ),
            IconButton.filledTonal(
              icon: Icon(
                controller.isPlaying ? Icons.pause : Icons.play_arrow,
              ),
              iconSize: 24,
              onPressed: controller.togglePlayPause,
              tooltip: controller.isPlaying ? '暂停' : '播放',
            ),
            IconButton(
              icon: const Icon(Icons.skip_next),
              iconSize: 22,
              onPressed: controller.skipToNextCue,
              tooltip: '下一句',
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                controller.currentCue?.text ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            AudiobookFollowAudioButton(controller: controller),
            AudiobookSpeedButton(controller: controller),
            AudiobookDelayButton(controller: controller),
          ],
        ),
      ),
    );
  }
}

/// Follow audio 开关按钮（磁铁图标；PR8b）。
///
/// 独立于 [AudiobookPlayBar] 的 [ListenableBuilder] 订阅 —— 按钮只随
/// [AudiobookPlayerController.followAudio] 变化重绘，避免每次 cue 更新
/// 整条 play bar 都跟着刷新时这颗按钮也 rebuild。点击 toggle 并持久化
/// （controller 侧内部调 onCrossChapter 用户传入的 persist 回调）。
class AudiobookFollowAudioButton extends StatelessWidget {
  const AudiobookFollowAudioButton({required this.controller, super.key});

  final AudiobookPlayerController controller;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: controller.followAudio,
      builder: (BuildContext context, bool on, _) {
        final ColorScheme colors = Theme.of(context).colorScheme;
        return IconButton(
          icon: Icon(on ? Icons.link : Icons.link_off),
          iconSize: 20,
          color: on ? colors.primary : colors.onSurfaceVariant,
          tooltip: on ? 'Follow audio: ON（跨章自动跳转）' : 'Follow audio: OFF',
          onPressed: () {
            // persist 回调在 reader 页面把 controller 和 repo 绑上；这里
            // 只翻内存状态，controller.setFollowAudio 内部会用绑好的回调
            // 落库，按钮自己不碰 Isar。
            controller.setFollowAudio(!on);
          },
        );
      },
    );
  }
}

/// 倍速切换按钮（0.75 → 1.0 → 1.25 → 1.5 循环）。
class AudiobookSpeedButton extends StatelessWidget {
  const AudiobookSpeedButton({required this.controller, super.key});

  final AudiobookPlayerController controller;

  static const List<double> _speeds = [0.75, 1.0, 1.25, 1.5];

  @override
  Widget build(BuildContext context) {
    final double current = controller.speed;
    final int idx = _speeds.indexWhere((s) => (s - current).abs() < 0.01);
    final double next = _speeds[(idx + 1) % _speeds.length];

    return TextButton(
      onPressed: () => controller.setSpeed(next),
      style: TextButton.styleFrom(
        minimumSize: const Size(48, 36),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        visualDensity: VisualDensity.compact,
      ),
      child: Text(
        '${current.toStringAsFixed(2)}x',
        style: Theme.of(context).textTheme.labelMedium,
      ),
    );
  }
}

/// 音画同步延迟调节按钮。
///
/// 值为 0 时显示 av_timer 图标；非 0 时把数值直接画在按钮上（如 "-200ms"
/// / "+500ms"），方便扫一眼看到当前偏移是什么方向。点击弹 bottom sheet
/// 让用户按 ±50 / ±200 / ±1000ms 粒度调整，或归零。
///
/// ValueListenableBuilder 只监听 `delayMs`，不跟着 cue 刷新 rebuild。
class AudiobookDelayButton extends StatelessWidget {
  const AudiobookDelayButton({required this.controller, super.key});

  final AudiobookPlayerController controller;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: controller.delayMs,
      builder: (BuildContext context, int ms, _) {
        final String label = ms == 0
            ? ''
            : '${ms > 0 ? '+' : ''}${ms}ms';
        final Widget child = ms == 0
            ? const Icon(Icons.av_timer_outlined, size: 20)
            : Text(label, style: Theme.of(context).textTheme.labelMedium);
        return TextButton(
          onPressed: () => _openSheet(context),
          style: TextButton.styleFrom(
            minimumSize: const Size(48, 36),
            padding: const EdgeInsets.symmetric(horizontal: 6),
            visualDensity: VisualDensity.compact,
          ),
          child: child,
        );
      },
    );
  }

  Future<void> _openSheet(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (BuildContext ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
            child: ValueListenableBuilder<int>(
              valueListenable: controller.delayMs,
              builder: (BuildContext ctx2, int ms, _) {
                final ThemeData theme = Theme.of(ctx2);
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('音画同步 (毫秒)',
                        style: theme.textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text(
                      '正数 = 音频先于文字，向回拨 cue；负数 = 音频滞后。',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Center(
                      child: Text(
                        '${ms > 0 ? '+' : ''}$ms ms',
                        style: theme.textTheme.headlineSmall,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        _stepBtn(ctx2, '-1s', -1000),
                        _stepBtn(ctx2, '-200', -200),
                        _stepBtn(ctx2, '-50', -50),
                        _stepBtn(ctx2, '+50', 50),
                        _stepBtn(ctx2, '+200', 200),
                        _stepBtn(ctx2, '+1s', 1000),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        onPressed: ms == 0
                            ? null
                            : () => controller.setDelayMs(0),
                        icon: const Icon(Icons.restart_alt, size: 18),
                        label: const Text('归零'),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }

  Widget _stepBtn(BuildContext ctx, String label, int delta) {
    return FilledButton.tonal(
      onPressed: () {
        controller.setDelayMs(controller.delayMs.value + delta);
      },
      style: FilledButton.styleFrom(
        minimumSize: const Size(52, 40),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        visualDensity: VisualDensity.compact,
      ),
      child: Text(label),
    );
  }
}
