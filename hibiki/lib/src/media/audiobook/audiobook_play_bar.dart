import 'package:flutter/material.dart';
import 'package:hibiki/src/media/audiobook/audiobook_controller.dart';

/// 有声书播放控制条（紧凑型，固定于阅读器底部）。
///
/// Row 只放最常用的实时控件：⏮ ⏯ ⏭、当前 cue、Follow 磁铁、设置齿轮。
/// 倍速 / 音画同步 / 阅读进度 等放进 [onOpenSettings] 回调展开的底部
/// 设置面板，空出 bar 横向空间、并为 ttu 原生工具栏被隐藏后失去的
/// "TOC/书签/全屏/退出"入口预留位置（后续补）。
class AudiobookPlayBar extends StatelessWidget {
  const AudiobookPlayBar({
    required this.controller,
    required this.onOpenSettings,
    super.key,
  });

  final AudiobookPlayerController controller;

  /// 用户点 ⚙ 设置按钮后触发。由 reader 页面侧注入，因为设置面板要
  /// 访问 WebView controller 才能 probe ttu 当前章节 / 总章节。
  final VoidCallback onOpenSettings;

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
            IconButton(
              icon: const Icon(Icons.tune),
              iconSize: 20,
              onPressed: onOpenSettings,
              tooltip: '有声书设置',
            ),
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

/// 有声书设置面板的单一入口 —— 展示并调整：
/// - 阅读进度（只读，章节 + 全书%）
/// - 倍速（0.75 / 1.0 / 1.25 / 1.5 四选一）
/// - 音画同步（±50 / ±200 / ±1s / 归零）
///
/// [readerProgress] 是 reader 页面 probe 出来的 (section, total)。null 表示
/// probe 失败或 ttu 没就绪，这时候进度区显示 "—"。`section` 是 0-based。
class AudiobookSettingsSheet extends StatelessWidget {
  const AudiobookSettingsSheet({
    required this.controller,
    required this.readerProgress,
    super.key,
  });

  final AudiobookPlayerController controller;

  /// (currentSection0, totalSections)；未 probe 时 null。
  final (int section, int total)? readerProgress;

  static const List<double> _speeds = [0.75, 1.0, 1.25, 1.5];

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildProgressSection(theme),
            const SizedBox(height: 20),
            _buildSpeedSection(theme),
            const SizedBox(height: 20),
            _buildDelaySection(theme),
          ],
        ),
      ),
    );
  }

  Widget _buildProgressSection(ThemeData theme) {
    final (int section, int total)? prog = readerProgress;
    final String label;
    if (prog == null || prog.$2 <= 0) {
      label = '—';
    } else {
      final int idx1 = prog.$1 + 1; // 1-based 给人看
      final int total = prog.$2;
      final int pct = (idx1 / total * 100).clamp(0, 100).round();
      label = '第 $idx1 / $total 章 · $pct%';
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('阅读进度', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(label, style: theme.textTheme.bodyLarge),
      ],
    );
  }

  Widget _buildSpeedSection(ThemeData theme) {
    final double current = controller.speed;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('倍速', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: _speeds.map((double s) {
            final bool selected = (s - current).abs() < 0.01;
            return ChoiceChip(
              label: Text('${s.toStringAsFixed(2)}x'),
              selected: selected,
              onSelected: (bool on) {
                if (on) controller.setSpeed(s);
              },
            );
          }).toList(),
        ),
      ],
    );
  }

  Widget _buildDelaySection(ThemeData theme) {
    return ValueListenableBuilder<int>(
      valueListenable: controller.delayMs,
      builder: (BuildContext ctx, int ms, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('音画同步', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              '正数 = 音频先于文字，向回拨 cue；负数 = 音频滞后。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 10),
            Center(
              child: Text(
                '${ms > 0 ? '+' : ''}$ms ms',
                style: theme.textTheme.headlineSmall,
              ),
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _stepBtn('-1s', -1000),
                _stepBtn('-200', -200),
                _stepBtn('-50', -50),
                _stepBtn('+50', 50),
                _stepBtn('+200', 200),
                _stepBtn('+1s', 1000),
              ],
            ),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: ms == 0 ? null : () => controller.setDelayMs(0),
                icon: const Icon(Icons.restart_alt, size: 18),
                label: const Text('归零'),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _stepBtn(String label, int delta) {
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
