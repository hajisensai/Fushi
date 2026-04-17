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
    final ColorScheme colors = Theme.of(context).colorScheme;

    return Material(
      color: colors.surface.withAlpha(230),
      elevation: 8,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              // 上一句
              IconButton(
                icon: const Icon(Icons.skip_previous),
                iconSize: 22,
                onPressed: controller.skipToPrevCue,
                tooltip: '上一句',
              ),
              // 播放/暂停
              IconButton(
                icon: Icon(
                  controller.isPlaying ? Icons.pause : Icons.play_arrow,
                ),
                iconSize: 28,
                onPressed: controller.togglePlayPause,
              ),
              // 下一句
              IconButton(
                icon: const Icon(Icons.skip_next),
                iconSize: 22,
                onPressed: controller.skipToNextCue,
                tooltip: '下一句',
              ),
              const SizedBox(width: 4),
              // 当前句文本（单行省略）
              Expanded(
                child: Text(
                  controller.currentCue?.text ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              // 倍速按钮
              AudiobookSpeedButton(controller: controller),
            ],
          ),
        ),
      ),
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
      child: Text(
        '${current.toStringAsFixed(2)}x',
        style: Theme.of(context).textTheme.labelSmall,
      ),
    );
  }
}
