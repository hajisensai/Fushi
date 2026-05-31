import 'package:flutter/material.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki/utils.dart';

/// 有声书播放控制条（紧凑型，固定于阅读器底部）。
///
/// Row 只放最常用的实时控件：⏮ ⏯ ⏭、当前 cue、Follow 磁铁、设置齿轮。
/// 倍速 / 音画同步 / 阅读进度 / 章节列表 / 添加书签 / 全屏 / 退出 放进
/// [onOpenSettings] 回调展开的底部设置面板 —— ttu 原生顶部工具栏被隐藏
/// 后这些功能的统一入口。
class AudiobookPlayBar extends StatelessWidget {
  const AudiobookPlayBar({
    required this.controller,
    required this.onOpenSettings,
    this.skipActionSeconds = 0,
    this.backgroundColor,
    super.key,
  });

  final AudiobookPlayerController controller;
  final Color? backgroundColor;

  /// 0 = skip by sentence, 5/10/15/30 = skip by N seconds.
  final int skipActionSeconds;

  /// 用户点 ⚙ 设置按钮后触发。由 reader 页面侧注入，因为设置面板要
  /// 访问 WebView controller 才能 probe ttu 当前章节 / TOC、触发书签。
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return ColoredBox(
      color: backgroundColor ?? Theme.of(context).colorScheme.surface,
      child: SizedBox(
        height: 56,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: tokens.spacing.gap),
          child: Row(
            children: [
              HibikiIconButton(
                icon: skipActionSeconds == 0
                    ? Icons.skip_previous_outlined
                    : Icons.fast_rewind_outlined,
                size: 22,
                padding: EdgeInsets.all(tokens.spacing.gap),
                tooltip: skipActionSeconds == 0
                    ? t.prev_sentence
                    : '-${skipActionSeconds}s',
                onTap: () {
                  if (skipActionSeconds == 0) {
                    controller.skipToPrevCue();
                  } else {
                    controller.seekRelative(-skipActionSeconds);
                  }
                },
              ),
              HibikiIconButton(
                icon: controller.isPlaying
                    ? Icons.pause_outlined
                    : Icons.play_arrow_outlined,
                size: 24,
                backgroundColor:
                    Theme.of(context).colorScheme.secondaryContainer,
                enabledColor:
                    Theme.of(context).colorScheme.onSecondaryContainer,
                padding: EdgeInsets.all(tokens.spacing.gap),
                onTap: controller.togglePlayPause,
                tooltip: controller.isPlaying ? t.pause : t.play,
              ),
              HibikiIconButton(
                icon: skipActionSeconds == 0
                    ? Icons.skip_next_outlined
                    : Icons.fast_forward_outlined,
                size: 22,
                padding: EdgeInsets.all(tokens.spacing.gap),
                tooltip: skipActionSeconds == 0
                    ? t.next_sentence
                    : '+${skipActionSeconds}s',
                onTap: () {
                  if (skipActionSeconds == 0) {
                    controller.skipToNextCue();
                  } else {
                    controller.seekRelative(skipActionSeconds);
                  }
                },
              ),
              SizedBox(width: tokens.spacing.gap / 2),
              Expanded(
                child: Text(
                  controller.currentCue?.text ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              AudiobookFollowAudioButton(controller: controller),
              HibikiIconButton(
                icon: Icons.tune_outlined,
                size: 20,
                padding: EdgeInsets.all(tokens.spacing.gap),
                onTap: onOpenSettings,
                tooltip: t.audiobook_settings,
              ),
            ],
          ),
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
      builder: (context, on, _) {
        final ColorScheme colors = Theme.of(context).colorScheme;
        final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
        return HibikiIconButton(
          icon: on ? Icons.link : Icons.link_off,
          size: 20,
          enabledColor: on ? colors.primary : colors.onSurfaceVariant,
          padding: EdgeInsets.all(tokens.spacing.gap),
          tooltip: on ? t.follow_audio_on_tooltip : t.follow_audio_off_tooltip,
          onTap: () {
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

Widget buildReaderThemeChip({
  required BuildContext context,
  required String label,
  required bool selected,
  required ValueChanged<bool> onSelected,
  Widget? avatar,
}) {
  return HibikiSelectableChip(
    tooltip: label,
    avatar: avatar,
    label: label,
    selected: selected,
    onSelected: onSelected,
  );
}
