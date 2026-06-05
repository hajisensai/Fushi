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
    this.foregroundColor,
    this.reversed = false,
    super.key,
  });

  final AudiobookPlayerController controller;
  final Color? backgroundColor;

  /// 阅读器纸张主题的前景色（[_themeTextColor]）。注入后整条 bar 的图标 /
  /// cue 文本 / 播放按钮都跟随该主题，而不是全局 Material 主题——避免
  /// 「纸张主题为亮色但 app 处于暗色（或反之）」时前景对比度错乱。
  /// 为 null 时回退到 Material 主题色（用于独立 widget 测试或其它场景）。
  final Color? foregroundColor;

  /// 0 = skip by sentence, 5/10/15/30 = skip by N seconds.
  final int skipActionSeconds;

  /// 跟随「反转底栏方向」偏好（[PreferencesRepository.reverseNavigationBar]）。
  /// 为 true 时镜像整条 bar 的控件位置（反转顶层 children 顺序）。⏮⏯⏭ 播放
  /// 三联键被打包成一个原子组，镜像时整组换边但**内部方向不变**——快退/上一句
  /// 永远在左、快进/下一句永远在右（否则方向语义错乱，BUG-021）。cue 文本
  /// 内部方向同样保留。
  final bool reversed;

  /// 用户点 ⚙ 设置按钮后触发。由 reader 页面侧注入，因为设置面板要
  /// 访问 WebView controller 才能 probe ttu 当前章节 / TOC、触发书签。
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final Color? fg = foregroundColor;
    // 播放按钮用纸张前景色做 12% 的 tonal 底，图标用满前景色——保证在任何
    // 纸张主题上都有对比度，且不再泄漏 app Material 主题的 secondaryContainer。
    final Color playBackground = fg != null
        ? fg.withValues(alpha: 0.12)
        : Theme.of(context).colorScheme.secondaryContainer;
    final Color playForeground =
        fg ?? Theme.of(context).colorScheme.onSecondaryContainer;
    final TextStyle? cueStyle = fg != null
        ? Theme.of(context).textTheme.bodySmall?.copyWith(color: fg)
        : Theme.of(context).textTheme.bodySmall;
    // ⏮⏯⏭ 是一个原子组：reversed 镜像整条 bar 时这组只换边、内部方向不动，
    // 否则快退/快进会左右颠倒（BUG-021）。用 min-size Row 包住三键。
    final Widget playbackControls = Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        HibikiIconButton(
          icon: skipActionSeconds == 0
              ? Icons.skip_previous_outlined
              : Icons.fast_rewind_outlined,
          size: 22,
          enabledColor: fg,
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
          backgroundColor: playBackground,
          enabledColor: playForeground,
          padding: EdgeInsets.all(tokens.spacing.gap),
          onTap: controller.togglePlayPause,
          tooltip: controller.isPlaying ? t.pause : t.play,
        ),
        HibikiIconButton(
          icon: skipActionSeconds == 0
              ? Icons.skip_next_outlined
              : Icons.fast_forward_outlined,
          size: 22,
          enabledColor: fg,
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
      ],
    );
    final List<Widget> barItems = <Widget>[
      playbackControls,
      SizedBox(width: tokens.spacing.gap / 2),
      Expanded(
        child: Text(
          controller.currentCue?.text ?? '',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: cueStyle,
        ),
      ),
      AudiobookFollowAudioButton(
        controller: controller,
        foregroundColor: fg,
      ),
      HibikiIconButton(
        icon: Icons.tune_outlined,
        size: 20,
        enabledColor: fg,
        padding: EdgeInsets.all(tokens.spacing.gap),
        onTap: onOpenSettings,
        tooltip: t.reader_settings_section,
      ),
    ];
    return ColoredBox(
      color: backgroundColor ?? Theme.of(context).colorScheme.surface,
      child: SizedBox(
        height: 56,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: tokens.spacing.gap),
          child: Row(
            children: reversed ? barItems.reversed.toList() : barItems,
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
  const AudiobookFollowAudioButton({
    required this.controller,
    this.foregroundColor,
    super.key,
  });

  final AudiobookPlayerController controller;

  /// 阅读器纸张主题前景色；为 null 时回退到 Material 主题色。开启态用满
  /// 前景色，关闭态用 60% 前景色，保持与同条 bar 其它图标一致的主题来源。
  final Color? foregroundColor;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: controller.followAudio,
      builder: (context, on, _) {
        final ColorScheme colors = Theme.of(context).colorScheme;
        final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
        final Color onColor = foregroundColor ?? colors.primary;
        final Color offColor = foregroundColor != null
            ? foregroundColor!.withValues(alpha: 0.6)
            : colors.onSurfaceVariant;
        return HibikiIconButton(
          icon: on ? Icons.link : Icons.link_off,
          size: 20,
          enabledColor: on ? onColor : offColor,
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
