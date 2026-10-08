import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/media/audiobook/audiobook_controller.dart';
import 'package:fushi/src/utils/components/fushi_expressive_progress.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart' show FushiFocusId;
import 'package:fushi/src/focus/fushi_focus_target.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/utils.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 有声书播放控制条（紧凑型，固定于阅读器底部）。
///
/// Row 只放最常用的实时控件：⏮ ⏯ ⏭、Follow 磁铁、设置齿轮。
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
    this.trailing,
    this.showSettingsButton = true,
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

  /// 用户点 ⚙ 设置按钮后触发。由 reader 页面侧注入，因为设置面板要
  /// 访问 WebView controller 才能 probe ttu 当前章节 / TOC、触发书签。
  final VoidCallback onOpenSettings;

  /// 跟随键之前的可选尾部内容（桌面端把状态行文字并进播放条右端）。
  final Widget? trailing;

  /// Shared reader header already exposes settings, so its playback bar can omit
  /// the duplicate button and leave room for full-size transport touch targets.
  final bool showSettingsButton;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final Color? fg = foregroundColor;
    // 播放/暂停键回到原生 [IconButton.filledTonal]：标准 MD3 圆形 tonal 容器 +
    // state-layer + ripple（TODO-297 还原「图标 + 圆框 md3」旧版观感）。注入纸张
    // 前景色时（c3dbe59a1）用 12% tonal 底 + 满前景色，保证任何纸张主题上都有
    // 对比度且不泄漏 app Material 主题的 secondaryContainer；为 null 时回退到
    // filledTonal 的默认 secondaryContainer/onSecondaryContainer 配色。
    //
    // Apple：iOS 播放键的 `.glassProminent` 形态——纸张前景色实心圆 + 反色
    // 字形（不透明前景色经 [fushiGlassFill] 的 tint 档按 0.82 重铺）。不用
    // 12% 前景色的轻着色：玻璃本身已是中性灰底，再叠一层淡色圆对比度不够。
    final ButtonStyle? playStyle = fg == null
        ? null
        : isGlassDesign(context)
            ? ButtonStyle(
                backgroundColor: WidgetStatePropertyAll<Color>(fg),
                foregroundColor: WidgetStatePropertyAll<Color>(
                  appleOnAccent(fg.withValues(alpha: 1)),
                ),
              )
            : IconButton.styleFrom(
                backgroundColor: fg.withValues(alpha: 0.12),
                foregroundColor: fg,
              );
    // 上一句/下一句、设置齿轮按旧版是无框原生 [IconButton]（仅图标），纸张主题
    // 前景色经 [IconButton.styleFrom] 的 foregroundColor 注入。
    final ButtonStyle? flatStyle =
        fg != null ? IconButton.styleFrom(foregroundColor: fg) : null;
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
          ? FushiIcons.skipPrevious
          : FushiIcons.fastRewind,
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
          ? FushiIcons.skipNext
          : FushiIcons.fastForward,
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
    // 用户 2026-09-14：底栏不再挂 -10s / +10s 两颗跳秒键。三联键（上一句 / 播放 /
    // 下一句）是底栏的全部传输面；要按秒跳就把「跳转动作」设成 5/10/15/30 秒，
    // 左右两键本身就变成快退 / 快进（[skipActionSeconds] 分支），不必再多两颗。
    final Widget playbackControls = Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _FocusableBarButton(
          id: const FushiFocusId('audiobook_prev'),
          icon: FushiIcon(leftKey.icon),
          iconSize: 22,
          style: flatStyle,
          tooltip: leftKey.tooltip,
          onPressed: leftKey.onPressed,
        ),
        _FocusableBarButton(
          id: const FushiFocusId('audiobook_play'),
          filledTonal: true,
          icon: FushiIcon(
            controller.isPlaying
                ? FushiIcons.pause
                : FushiIcons.play,
          ),
          iconSize: 24,
          style: playStyle,
          onPressed: controller.togglePlayPause,
          tooltip: controller.isPlaying ? t.pause : t.play,
        ),
        _FocusableBarButton(
          id: const FushiFocusId('audiobook_next'),
          icon: FushiIcon(rightKey.icon),
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
      // 2026-10 体验优化：trailing（底栏槽位按钮 + 状态读数）原本是定宽 Row
      // 紧跟 Spacer，360dp 下拖进 3 颗以上按钮整条 bar 就溢出。改成占满剩余
      // 宽度、贴着跟随键对齐、放不下时横向滚动——三联键与跟随键永远完整可点。
      if (trailing != null) ...<Widget>[
        Expanded(
          child: Align(
            alignment: reversed ? Alignment.centerLeft : Alignment.centerRight,
            // 桌面端默认 dragDevices 不含鼠标：放不下时鼠标也得拖得动。
            child: HorizontalDragScrollable(
              child: SingleChildScrollView(
                key: const ValueKey<String>('audiobook_play_bar_trailing'),
                scrollDirection: Axis.horizontal,
                reverse: !reversed,
                child: trailing,
              ),
            ),
          ),
        ),
        SizedBox(width: tokens.spacing.gap),
      ] else
        const Spacer(),
      AudiobookFollowAudioButton(controller: controller, foregroundColor: fg),
      if (showSettingsButton)
        _FocusableBarButton(
          id: const FushiFocusId('audiobook_settings'),
          key: const ValueKey<String>('fushi_reader_audiobook_settings_button'),
          semanticsIdentifier: 'hibiki.reader.audiobook.settings',
          icon: const FushiIcon(FushiIcons.settings),
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
          id: const FushiFocusId('audiobook_follow'),
          icon: FushiIcon(on ? FushiIcons.link : FushiIcons.linkOff),
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

/// 有声书播放控制条上的一个图标按钮，已注册为应用焦点目标（[FushiFocusTarget]）。
///
/// 裸 Material [IconButton] 的焦点节点不会进入 [FushiFocusController] 的目标表，
/// 所以在 `experimentalFocusNavigation` 下方向键 / 手柄方向只在已注册的
/// [FushiFocusTarget] 之间移动，永远跳不到播放条这几个按钮（TODO-712：用户报
/// 「这三个按钮好像没焦点」）。这里把按钮包进 [FushiFocusTarget] 让它成为可达
/// 的焦点目标。
///
/// [FushiFocusTarget] 自己持有焦点节点（[Focus]）；A / Enter 经
/// `Actions.maybeInvoke<ActivateIntent>(primaryFocus.context, ...)` 从该焦点节点
/// **向上**走 Actions 链分发，而 [IconButton] 内建的 [ActivateIntent] 处理器在
/// 子树**下方**够不到——所以这里在 [FushiFocusTarget] 之上显式挂一层
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
    this.semanticsIdentifier,
    super.key,
  });

  final FushiFocusId id;
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

  /// Stable native accessibility id for UI automation.
  final String? semanticsIdentifier;

  @override
  Widget build(BuildContext context) {
    Widget button = filledTonal
        ? FushiIconButtonControl.filledTonal(
            icon: icon,
            iconSize: iconSize,
            style: style,
            color: color,
            tooltip: tooltip,
            onPressed: onPressed,
          )
        : FushiIconButtonControl(
            icon: icon,
            iconSize: iconSize,
            style: style,
            color: color,
            tooltip: tooltip,
            onPressed: onPressed,
          );
    if (semanticsIdentifier != null) {
      button = Semantics(identifier: semanticsIdentifier, child: button);
    }
    return Actions(
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (ActivateIntent intent) {
            onPressed();
            return null;
          },
        ),
      },
      child: FushiFocusTarget(id: id, child: button),
    );
  }
}

/// M3 Expressive 悬浮迷你播放条（2026-10，工具栏样式 = 悬浮时阅读器底部用它取代
/// 整宽 [AudiobookPlayBar]）。与 [FushiFloatingToolbar] 同一视觉：64 高全圆角胶囊 +
/// 阴影，内容 `[上一句] [当前句 + 波浪进度] [下一句] [跟随]`；中间信息区可点
/// （[onOpenPanel] = 展开有声书侧板）。播放键默认不在条里——它是条旁的 M3E 形状
/// 变形 FAB（[AudiobookPlayFab]，圆 ↔ 圆角方），整块底部只有一颗播放键；
/// [showPlayButton] 为 true 时（无 FAB 的调用方）放进条内。
///
/// 进度：全书时间轴上的 [FushiWavyLinearProgress]，播放中波动、暂停收平成直线
/// （[FushiWavyLinearProgress.waving]）。Apple 设计系统下胶囊是分组卡面 + 发丝描边，
/// 进度是 3px 细线。
///
/// 上一句 / 下一句与 [AudiobookPlayBar] 同一语义：跟随「跳转方式」（按句 / 按 N 秒）
/// 与 [invertSkip] 功能互换（BUG-021 契约）。
class AudiobookMiniPlayer extends StatefulWidget {
  const AudiobookMiniPlayer({
    required this.controller,
    this.onOpenPanel,
    this.skipActionSeconds = 0,
    this.invertSkip = false,
    this.showPlayButton = false,
    this.colors,
    this.tick = const Duration(milliseconds: 500),
    this.coverPath,
    this.chapterLabel,
    super.key,
  });

  final AudiobookPlayerController controller;
  final VoidCallback? onOpenPanel;
  final int skipActionSeconds;
  final bool invertSkip;
  final bool showPlayButton;
  final FushiFloatingToolbarColors? colors;

  /// 封面文件（M3E 形态下裁成四瓣 cookie 放在条左端）；null 画书本图标。
  final String? coverPath;

  /// 当前章名（当前句下面一行小字）。
  final String? chapterLabel;

  /// 播放中进度刷新周期（控制器只在 cue / 播放态变化时 notify）。
  final Duration tick;

  /// 条高（M3E 悬浮工具栏规格 64）。
  static const double height = kFushiFloatingToolbarExtent;

  @override
  State<AudiobookMiniPlayer> createState() => _AudiobookMiniPlayerState();
}

class _AudiobookMiniPlayerState extends State<AudiobookMiniPlayer> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onController);
    _syncTicker();
  }

  @override
  void didUpdateWidget(AudiobookMiniPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_onController);
      widget.controller.addListener(_onController);
    }
    _syncTicker();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onController);
    _ticker?.cancel();
    super.dispose();
  }

  void _onController() {
    if (!mounted) return;
    _syncTicker();
    setState(() {});
  }

  /// 只在播放中跑周期刷新（暂停时进度不动，不常驻计时器）。
  void _syncTicker() {
    final bool playing = widget.controller.isPlaying;
    if (playing && _ticker == null) {
      _ticker = Timer.periodic(widget.tick, (_) {
        if (mounted) setState(() {});
      });
    } else if (!playing) {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  ({IconData icon, String tooltip, VoidCallback onPressed}) _key({
    required bool forward,
  }) {
    final AudiobookPlayerController c = widget.controller;
    final int skip = widget.skipActionSeconds;
    if (forward) {
      return (
        icon: skip == 0 ? FushiIcons.skipNext : FushiIcons.fastForward,
        tooltip: skip == 0 ? t.next_sentence : '+${skip}s',
        onPressed: () {
          if (skip == 0) {
            c.skipToNextCue();
          } else {
            c.seekRelative(skip);
          }
        },
      );
    }
    return (
      icon: skip == 0 ? FushiIcons.skipPrevious : FushiIcons.fastRewind,
      tooltip: skip == 0 ? t.prev_sentence : '-${skip}s',
      onPressed: () {
        if (skip == 0) {
          c.skipToPrevCue();
        } else {
          c.seekRelative(-skip);
        }
      },
    );
  }

  /// M3 Expressive 形态（Material 设计系统）：整条是饱和 primaryContainer 大圆角
  /// 胶囊——左端四瓣 cookie 裁切的封面，中间当前句 + 章名小字（可点 = 展开侧板），
  /// 右端连接式按钮组「上一句 / 播放（形状变形 FAB，按下回弹）/ 下一句」，按下的
  /// 键变宽、邻键让出（[FushiButtonGroup]，弹簧）；全书进度是一条贴着胶囊底边的
  /// 波浪线（播放中流动、暂停收平）。
  Widget _buildExpressive(BuildContext context) {
    final AudiobookPlayerController c = widget.controller;
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final Color bg = cs.primaryContainer;
    final Color fg = cs.onPrimaryContainer;
    final ButtonStyle flat = IconButton.styleFrom(foregroundColor: fg);
    final ({IconData icon, String tooltip, VoidCallback onPressed}) left =
        _key(forward: widget.invertSkip);
    final ({IconData icon, String tooltip, VoidCallback onPressed}) right =
        _key(forward: !widget.invertSkip);
    final int totalMs = c.totalDuration.inMilliseconds;
    final double fraction = totalMs > 0
        ? (c.globalPosition.inMilliseconds / totalMs).clamp(0.0, 1.0)
        : 0.0;
    final String cue = c.currentCue?.text.trim() ?? '';
    final String label = cue.isEmpty ? t.reader_audiobook_now_playing : cue;
    final String chapter = widget.chapterLabel?.trim() ?? '';
    final String? coverPath = widget.coverPath;
    const OutlinedBorder coverShape = FushiCookieBorder(lobes: 4, depth: 0.1);
    final Widget cover = SizedBox.square(
      dimension: 44,
      child: coverPath == null
          ? DecoratedBox(
              decoration: ShapeDecoration(color: cs.primary, shape: coverShape),
              child: Center(
                child: FushiIcon(
                  FushiIcons.audiobook,
                  color: cs.onPrimary,
                  size: 22,
                ),
              ),
            )
          : ClipPath(
              clipper: ShapeBorderClipper(shape: coverShape),
              child: Image.file(
                File(coverPath),
                key: const ValueKey<String>('audiobook_mini_player_cover'),
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => ColoredBox(color: cs.primary),
              ),
            ),
    );
    final Widget info = Expanded(
      child: Semantics(
        button: widget.onOpenPanel != null,
        label: t.reader_mini_player_open,
        child: InkWell(
          key: const ValueKey<String>('audiobook_mini_player_open'),
          borderRadius: const BorderRadius.all(Radius.circular(20)),
          onTap: widget.onOpenPanel,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                AnimatedSwitcher(
                  duration: fushiMotionDuration(context, FushiMotion.short),
                  switchInCurve: FushiMotion.enter,
                  switchOutCurve: FushiMotion.exit,
                  layoutBuilder: (Widget? current, List<Widget> previous) =>
                      Stack(
                    alignment: AlignmentDirectional.centerStart,
                    children: <Widget>[
                      ...previous,
                      if (current != null) current,
                    ],
                  ),
                  child: Text(
                    label,
                    key: ValueKey<String>('mini_cue_$label'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: fg,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (chapter.isNotEmpty)
                  Text(
                    chapter,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: fg.withValues(alpha: 0.72),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    final Widget group = FushiButtonGroup(
      spacing: 2,
      children: <Widget>[
        _FocusableBarButton(
          id: const FushiFocusId('audiobook_prev'),
          icon: FushiIcon(left.icon),
          iconSize: 26,
          style: flat,
          tooltip: left.tooltip,
          onPressed: left.onPressed,
        ),
        AudiobookPlayFab(controller: c, size: 52),
        _FocusableBarButton(
          id: const FushiFocusId('audiobook_next'),
          icon: FushiIcon(right.icon),
          iconSize: 26,
          style: flat,
          tooltip: right.tooltip,
          onPressed: right.onPressed,
        ),
      ],
    );
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 72),
      child: FushiFloatingPill(
        key: const ValueKey<String>('audiobook_mini_player'),
        color: bg,
        padding: EdgeInsets.zero,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(28)),
        ),
        child: Stack(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 8, 14),
              child: Row(
                children: <Widget>[
                  cover,
                  info,
                  group,
                  AudiobookFollowAudioButton(controller: c, foregroundColor: fg),
                ],
              ),
            ),
            Positioned(
              left: 24,
              right: 24,
              bottom: 2,
              child: FushiWavyLinearProgress(
                key: const ValueKey<String>('audiobook_mini_player_progress'),
                value: fraction,
                waving: c.isPlaying,
                strokeWidth: 3,
                color: fg,
                trackColor: fg.withValues(alpha: 0.18),
                stopIndicatorColor: Colors.transparent,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!isGlassDesign(context) && !isEinkTheme(context)) {
      return _buildExpressive(context);
    }
    final AudiobookPlayerController c = widget.controller;
    final ThemeData theme = Theme.of(context);
    final bool glass = isGlassDesign(context);
    final ({
      Color container,
      Color foreground,
      Color selectedContainer,
      Color selectedForeground,
    }) palette = fushiFloatingToolbarPalette(context, colors: widget.colors);
    final Color fg = palette.foreground;
    final ButtonStyle flat = IconButton.styleFrom(foregroundColor: fg);
    final ({IconData icon, String tooltip, VoidCallback onPressed}) left =
        _key(forward: widget.invertSkip);
    final ({IconData icon, String tooltip, VoidCallback onPressed}) right =
        _key(forward: !widget.invertSkip);
    final int totalMs = c.totalDuration.inMilliseconds;
    final double fraction = totalMs > 0
        ? (c.globalPosition.inMilliseconds / totalMs).clamp(0.0, 1.0)
        : 0.0;
    final String cue = c.currentCue?.text.trim() ?? '';
    final String label = cue.isEmpty ? t.reader_audiobook_now_playing : cue;
    final Widget progress = glass || isEinkTheme(context)
        ? ClipRRect(
            borderRadius: const BorderRadius.all(Radius.circular(2)),
            child: LinearProgressIndicator(
              value: fraction,
              minHeight: 3,
              color: glass ? appleColorsOf(context).accent : fg,
              backgroundColor: fg.withValues(alpha: 0.16),
            ),
          )
        : FushiWavyLinearProgress(
            key: const ValueKey<String>('audiobook_mini_player_progress'),
            value: fraction,
            waving: c.isPlaying,
            strokeWidth: 3,
            color: theme.colorScheme.primary,
            trackColor: fg.withValues(alpha: 0.16),
          );
    final Widget info = Expanded(
      child: Semantics(
        button: widget.onOpenPanel != null,
        label: t.reader_mini_player_open,
        child: InkWell(
          key: const ValueKey<String>('audiobook_mini_player_open'),
          borderRadius: const BorderRadius.all(Radius.circular(20)),
          onTap: widget.onOpenPanel,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                AnimatedSwitcher(
                  duration: fushiMotionDuration(context, FushiMotion.short),
                  switchInCurve: FushiMotion.enter,
                  switchOutCurve: FushiMotion.exit,
                  layoutBuilder: (Widget? current, List<Widget> previous) =>
                      Stack(
                    alignment: AlignmentDirectional.centerStart,
                    children: <Widget>[
                      ...previous,
                      if (current != null) current,
                    ],
                  ),
                  child: Text(
                    label,
                    key: ValueKey<String>('mini_cue_$label'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: fg,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                progress,
              ],
            ),
          ),
        ),
      ),
    );
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: AudiobookMiniPlayer.height),
      child: FushiFloatingPill(
        key: const ValueKey<String>('audiobook_mini_player'),
        color: palette.container,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(
          children: <Widget>[
            _FocusableBarButton(
              id: const FushiFocusId('audiobook_prev'),
              icon: FushiIcon(left.icon),
              iconSize: 24,
              style: flat,
              tooltip: left.tooltip,
              onPressed: left.onPressed,
            ),
            if (widget.showPlayButton)
              AudiobookPlayFab(controller: c, size: 48),
            info,
            _FocusableBarButton(
              id: const FushiFocusId('audiobook_next'),
              icon: FushiIcon(right.icon),
              iconSize: 24,
              style: flat,
              tooltip: right.tooltip,
              onPressed: right.onPressed,
            ),
            AudiobookFollowAudioButton(controller: c, foregroundColor: fg),
          ],
        ),
      ),
    );
  }
}

/// 有声书播放键的 M3E 形状变形 FAB（[FushiToolbarFab] morphing：暂停 = 圆、
/// 播放中 = 圆角方），悬浮工具栏 / 迷你播放条旁共用。只随控制器重建。
class AudiobookPlayFab extends StatelessWidget {
  const AudiobookPlayFab({
    required this.controller,
    this.size = 56,
    super.key,
  });

  final AudiobookPlayerController controller;
  final double size;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (BuildContext context, Widget? _) {
        final bool playing = controller.isPlaying;
        return FushiFocusTarget(
          id: const FushiFocusId('audiobook_play'),
          child: FushiToolbarFab(
            key: const ValueKey<String>('audiobook_play_fab'),
            icon: playing ? FushiIcons.pause : FushiIcons.play,
            tooltip: playing ? t.pause : t.play,
            morphing: true,
            rounded: playing,
            size: size,
            semanticsId: 'hibiki.reader.audiobook.play_fab',
            onPressed: () => controller.togglePlayPause(),
          ),
        );
      },
    );
  }
}
