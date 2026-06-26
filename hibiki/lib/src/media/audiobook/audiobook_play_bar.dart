import 'package:flutter/material.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart'
    show HibikiFocusId;
import 'package:hibiki/src/focus/hibiki_focus_target.dart';
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
    this.invertSkip = false,
    this.showCue = true,
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

  /// 跟随「反转底栏前进后退按钮」偏好（[ReaderSettings.invertAudiobookSkipDirection]）。
  /// 为 true 时把 ⏮ / ⏭ 两键的**功能方向**整体互换——左键变下一句/快进、右键变
  /// 上一句/快退，图标 + tooltip + onPressed 三者一起换以保持视觉与行为一致。
  ///
  /// 与 [reversed] 严格正交：[reversed] 只镜像顶层控件的屏幕左右位置（barItems
  /// 顺序），不碰任何 onPressed/图标；[invertSkip] 只换三联键内部功能 + 图标，
  /// 不碰位置。两维度互不连带（BUG-021 契约的延伸）。
  final bool invertSkip;

  /// TODO-728: whether to render the current-sentence ([currentCue]) text in the
  /// bar. Default true = current behavior. When false the text is replaced by an
  /// empty placeholder that still occupies the same Expanded flex slot, so the
  /// other controls keep their positions (no layout jump).
  final bool showCue;

  /// 用户点 ⚙ 设置按钮后触发。由 reader 页面侧注入，因为设置面板要
  /// 访问 WebView controller 才能 probe ttu 当前章节 / TOC、触发书签。
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final Color? fg = foregroundColor;
    // 播放/暂停键回到原生 [IconButton.filledTonal]：标准 MD3 圆形 tonal 容器 +
    // state-layer + ripple（TODO-297 还原「图标 + 圆框 md3」旧版观感）。注入纸张
    // 前景色时（c3dbe59a1）用 12% tonal 底 + 满前景色，保证任何纸张主题上都有
    // 对比度且不泄漏 app Material 主题的 secondaryContainer；为 null 时回退到
    // filledTonal 的默认 secondaryContainer/onSecondaryContainer 配色。
    final ButtonStyle? playStyle = fg != null
        ? IconButton.styleFrom(
            backgroundColor: fg.withValues(alpha: 0.12),
            foregroundColor: fg,
          )
        : null;
    // 上一句/下一句、设置齿轮按旧版是无框原生 [IconButton]（仅图标），纸张主题
    // 前景色经 [IconButton.styleFrom] 的 foregroundColor 注入。
    final ButtonStyle? flatStyle =
        fg != null ? IconButton.styleFrom(foregroundColor: fg) : null;
    final TextStyle? cueStyle = fg != null
        ? Theme.of(context).textTheme.bodySmall?.copyWith(color: fg)
        : Theme.of(context).textTheme.bodySmall;
    // ⏮⏯⏭ 是一个原子组：reversed 镜像整条 bar 时这组只换边、内部方向不动，
    // 否则快退/快进会左右颠倒（BUG-021）。用 min-size Row 包住三键。
    //
    // [invertSkip] 是一个与 reversed 正交的功能维度：开时把左键（屏幕上仍在
    // 左、id=audiobook_prev）的图标 + tooltip + onPressed 整体换成「下一句/快进」，
    // 右键换成「上一句/快退」，三者一起换以免视觉与行为脱节。位置（左右）不变，
    // 只是功能互换——这与 reversed（只换位置不换功能）互不连带。
    //
    // 把「后退」与「前进」两组语义抽成局部记录，再按 invertSkip 决定哪组喂左键、
    // 哪组喂右键，消除内部的 if 分支特例。
    final ({
      IconData icon,
      String tooltip,
      VoidCallback onPressed
    }) backwardKey = (
      icon: skipActionSeconds == 0
          ? Icons.skip_previous_outlined
          : Icons.fast_rewind_outlined,
      tooltip:
          skipActionSeconds == 0 ? t.prev_sentence : '-${skipActionSeconds}s',
      onPressed: () {
        if (skipActionSeconds == 0) {
          controller.skipToPrevCue();
        } else {
          controller.seekRelative(-skipActionSeconds);
        }
      },
    );
    final ({IconData icon, String tooltip, VoidCallback onPressed}) forwardKey =
        (
      icon: skipActionSeconds == 0
          ? Icons.skip_next_outlined
          : Icons.fast_forward_outlined,
      tooltip:
          skipActionSeconds == 0 ? t.next_sentence : '+${skipActionSeconds}s',
      onPressed: () {
        if (skipActionSeconds == 0) {
          controller.skipToNextCue();
        } else {
          controller.seekRelative(skipActionSeconds);
        }
      },
    );
    // 左键（屏幕左侧，id=audiobook_prev）：invertSkip 开时变前进键。
    final ({IconData icon, String tooltip, VoidCallback onPressed}) leftKey =
        invertSkip ? forwardKey : backwardKey;
    // 右键（屏幕右侧，id=audiobook_next）：invertSkip 开时变后退键。
    final ({IconData icon, String tooltip, VoidCallback onPressed}) rightKey =
        invertSkip ? backwardKey : forwardKey;
    final Widget playbackControls = Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _FocusableBarButton(
          id: const HibikiFocusId('audiobook_prev'),
          icon: Icon(leftKey.icon),
          iconSize: 22,
          style: flatStyle,
          tooltip: leftKey.tooltip,
          onPressed: leftKey.onPressed,
        ),
        _FocusableBarButton(
          id: const HibikiFocusId('audiobook_play'),
          filledTonal: true,
          icon: Icon(
            controller.isPlaying
                ? Icons.pause_outlined
                : Icons.play_arrow_outlined,
          ),
          iconSize: 24,
          style: playStyle,
          onPressed: controller.togglePlayPause,
          tooltip: controller.isPlaying ? t.pause : t.play,
        ),
        _FocusableBarButton(
          id: const HibikiFocusId('audiobook_next'),
          icon: Icon(rightKey.icon),
          iconSize: 22,
          style: flatStyle,
          tooltip: rightKey.tooltip,
          onPressed: rightKey.onPressed,
        ),
      ],
    );
    final List<Widget> barItems = <Widget>[
      playbackControls,
      SizedBox(width: tokens.spacing.gap / 2),
      // TODO-728: keep the Expanded slot whether or not the cue is shown so the
      // surrounding controls do not shift when the user toggles it off.
      Expanded(
        child: showCue
            ? Text(
                controller.currentCue?.text ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: cueStyle,
              )
            : const SizedBox.shrink(),
      ),
      AudiobookFollowAudioButton(
        controller: controller,
        foregroundColor: fg,
      ),
      _FocusableBarButton(
        id: const HibikiFocusId('audiobook_settings'),
        icon: const Icon(Icons.tune_outlined),
        iconSize: 20,
        style: flatStyle,
        onPressed: onOpenSettings,
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
        final Color onColor = foregroundColor ?? colors.primary;
        final Color offColor = foregroundColor != null
            ? foregroundColor!.withValues(alpha: 0.6)
            : colors.onSurfaceVariant;
        // 旧版 follow 键是无框原生 [IconButton]（仅图标着色），还原其观感的同时
        // 保留 c3dbe59a1 的纸张前景色注入：开启态用满前景色 / 关闭态 60%。
        return _FocusableBarButton(
          id: const HibikiFocusId('audiobook_follow'),
          icon: Icon(on ? Icons.link : Icons.link_off),
          iconSize: 20,
          color: on ? onColor : offColor,
          tooltip: on ? t.follow_audio_on_tooltip : t.follow_audio_off_tooltip,
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

/// 有声书播放控制条上的一个图标按钮，已注册为应用焦点目标（[HibikiFocusTarget]）。
///
/// 裸 Material [IconButton] 的焦点节点不会进入 [HibikiFocusController] 的目标表，
/// 所以在 `experimentalFocusNavigation` 下方向键 / 手柄方向只在已注册的
/// [HibikiFocusTarget] 之间移动，永远跳不到播放条这几个按钮（TODO-712：用户报
/// 「这三个按钮好像没焦点」）。这里把按钮包进 [HibikiFocusTarget] 让它成为可达
/// 的焦点目标。
///
/// [HibikiFocusTarget] 自己持有焦点节点（[Focus]）；A / Enter 经
/// `Actions.maybeInvoke<ActivateIntent>(primaryFocus.context, ...)` 从该焦点节点
/// **向上**走 Actions 链分发，而 [IconButton] 内建的 [ActivateIntent] 处理器在
/// 子树**下方**够不到——所以这里在 [HibikiFocusTarget] 之上显式挂一层
/// `Actions{ActivateIntent → onPressed}`，与导航项 `_NavFocusCell` 同款做法，
/// 否则焦点能到但确认键按不动按钮。
class _FocusableBarButton extends StatelessWidget {
  const _FocusableBarButton({
    required this.id,
    required this.icon,
    required this.iconSize,
    required this.onPressed,
    required this.tooltip,
    this.style,
    this.color,
    this.filledTonal = false,
  });

  final HibikiFocusId id;
  final Widget icon;
  final double iconSize;
  final VoidCallback onPressed;
  final String tooltip;

  /// 透传给底层 [IconButton] 的 [ButtonStyle]（纸张主题前景色注入）。
  final ButtonStyle? style;

  /// 透传给底层 [IconButton] 的 [IconButton.color]（follow 键按开/关态着色用）。
  final Color? color;

  /// true 时底层用 [IconButton.filledTonal]（播放/暂停键的 MD3 圆框 tonal 容器）。
  final bool filledTonal;

  @override
  Widget build(BuildContext context) {
    final Widget button = filledTonal
        ? IconButton.filledTonal(
            icon: icon,
            iconSize: iconSize,
            style: style,
            color: color,
            tooltip: tooltip,
            onPressed: onPressed,
          )
        : IconButton(
            icon: icon,
            iconSize: iconSize,
            style: style,
            color: color,
            tooltip: tooltip,
            onPressed: onPressed,
          );
    return Actions(
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (ActivateIntent intent) {
            onPressed();
            return null;
          },
        ),
      },
      child: HibikiFocusTarget(id: id, child: button),
    );
  }
}
