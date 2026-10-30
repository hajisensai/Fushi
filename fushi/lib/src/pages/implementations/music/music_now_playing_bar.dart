/// 音乐迷你播放条（设计 §11.2）：与有声书「正在听书」条互斥——媒体会话归谁就显示谁
/// （[MediaSessionOwner]）。
///
/// M3E 两形态（用户 2026-10-29 定版：窄屏「形状唱片 + 圆环波浪」、宽屏「停靠条」，
/// 两者要看得出是一家）：
/// - 窄屏 [_CompactMusicBar]：浮动卡片，九角饼干形封面外绕一圈波浪进度，右边是
///   M3E 按钮组（上一首 / 形变播放键 / 下一首）；
/// - 宽屏 [_DockedMusicBar]：「灵动岛」——底部居中的小胶囊，悬停 / 触屏点一下
///   弹性展开出歌手、按钮组、信号路径 · 歌词 · 停止。
///
/// 一家人的线索：同一个九角饼干形封面、同一种不对称圆角（左下收紧
/// [kMusicBarRadius]）、同一枚形变播放键、同一种波浪进度、同一个
/// surfaceContainerHighest 底色。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/media/music/music_session.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/audio_controller.dart';
import 'package:fushi/src/pages/implementations/music/music_cover.dart';
import 'package:fushi/src/shortcuts/context_menu_trigger.dart';
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/pages/implementations/music/music_signal_path_panel.dart';
import 'package:fushi/src/pages/implementations/music/music_lyrics_page.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_m3e_player.dart';
import 'package:fushi/src/utils/components/fushi_expressive_progress.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 纯函数：两条迷你条谁显示。音乐有活动会话、且（音乐持有媒体会话或有声书没有会话）
/// 时显示音乐条；有声书条在音乐持有会话时让位。
bool musicBarVisible({
  required bool musicActive,
  required bool audiobookActive,
  required MediaSessionOwner owner,
}) => musicActive && (owner == MediaSessionOwner.music || !audiobookActive);

class MusicNowPlayingBar extends ConsumerWidget {
  const MusicNowPlayingBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppModel appModel = ref.watch(appProvider);
    final MusicSession session = appModel.musicSession;
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[
        session,
        appModel.audioCtrl.sessionOwner,
        appModel.audiobookSession,
      ]),
      builder: (BuildContext context, _) {
        final MusicPlayItem? item = session.engine.current;
        if (item == null ||
            !musicBarVisible(
              musicActive: session.isActive,
              audiobookActive: appModel.audiobookSession.isActive,
              owner: appModel.audioCtrl.sessionOwner.value,
            )) {
          return const SizedBox.shrink();
        }
        return LayoutBuilder(
          builder: (BuildContext context, BoxConstraints c) =>
              c.maxWidth >= kMusicBarDockedMinWidth
              ? _DockedMusicBar(session: session, item: item)
              : _CompactMusicBar(
                  session: session,
                  item: item,
                  roomy: c.maxWidth >= kMusicBarCompactRoomyWidth,
                ),
        );
      },
    );
  }
}

/// 播放区宽到这个值就用停靠条（M3 expanded 档下限之上）。
const double kMusicBarDockedMinWidth = 900;

/// 窄屏卡片在这个宽度以上才平铺信号路径 / 停止（放不下时收进长按菜单）。
const double kMusicBarCompactRoomyWidth = 520;

/// 两形态共用的不对称圆角：左下收紧，其余大圆角。
const BorderRadius kMusicBarRadius = BorderRadius.only(
  topLeft: Radius.circular(32),
  topRight: Radius.circular(32),
  bottomRight: Radius.circular(32),
  bottomLeft: Radius.circular(12),
);

/// 播放条的封面：九角饼干形裁切（两形态同一形状）。
Widget _shapedCover(MusicPlayItem item, double size) => ClipPath(
  clipper: ShapeBorderClipper(
    shape: MaterialShapeBorder(shape: MaterialShapes.cookie9Sided),
  ),
  child: SizedBox.square(
    dimension: size,
    child: MusicCover(coverPath: item.coverPath, size: size),
  ),
);

double _progressOf(MusicPlayerEngine engine) {
  final Duration? duration = engine.duration;
  if (duration == null || duration.inMilliseconds <= 0) return 0;
  return (engine.position.inMilliseconds / duration.inMilliseconds).clamp(
    0.0,
    1.0,
  );
}

void _openPlayer(BuildContext context) => unawaited(
  Navigator.of(context).push<void>(
    adaptivePageRoute<void>(
      context: context,
      builder: (_) => const MusicLyricsPage(),
    ),
  ),
);

/// 外壳：底色、圆角、投影、点条身开播放页（按钮各自吃掉自己的点击）。
class _BarShell extends StatelessWidget {
  const _BarShell({required this.child, required this.padding, this.onTap});

  final Widget child;
  final EdgeInsetsGeometry padding;

  /// 点条身；缺省打开播放页。
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return FushiPressScale(
      child: GestureDetector(
        key: const ValueKey<String>('music_bar_open_player'),
        behavior: HitTestBehavior.opaque,
        onTap: onTap ?? () => _openPlayer(context),
        child: DecoratedBox(
          decoration: isGlassDesign(context)
              ? fushiAppleSolidFloatingDecoration(
                  context,
                  shape: const RoundedRectangleBorder(
                    borderRadius: kMusicBarRadius,
                  ),
                )
              : BoxDecoration(
                  color: cs.surfaceContainerHighest,
                  borderRadius: kMusicBarRadius,
                  boxShadow: <BoxShadow>[
                    BoxShadow(
                      color: cs.shadow.withValues(alpha: 0.28),
                      blurRadius: 18,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

/// 歌名 + 歌手两行。
class _BarTitle extends StatelessWidget {
  const _BarTitle({required this.item});

  final MusicPlayItem item;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      Text(
        item.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: context.fushiType.titleSmallEmphasized,
      ),
      Text(
        <String?>[item.artist, item.album]
            .whereType<String>()
            .where((String v) => v.isNotEmpty)
            .join(' · ')
            .ifEmpty(t.music_now_playing),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: context.fushiType.bodySmall.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    ],
  );
}

extension on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}

/// 上一首 / 形变播放键 / 下一首（M3E 标准按钮组）；播放条与歌词页共用。
Widget musicTransportGroup(MusicSession session, {required double playSize}) {
  final MusicPlayerEngine engine = session.engine;
  return FushiButtonGroup(
    spacing: 4,
    children: <Widget>[
      FushiIconButtonControl.filledTonal(
        size: ButtonSizeVariant.small,
        tooltip: t.shortcut_action_music_previous_track,
        onPressed: () => unawaited(engine.skipPrevious()),
        icon: const FushiIcon(FushiIcons.skipPrevious),
      ),
      FushiExpressivePlayButton(
        key: const ValueKey<String>('music_bar_play_pause'),
        isPlaying: engine.isPlaying,
        size: playSize,
        onPressed: () => unawaited(engine.togglePlayPause()),
      ),
      FushiIconButtonControl.filledTonal(
        size: ButtonSizeVariant.small,
        tooltip: t.shortcut_action_music_next_track,
        onPressed: () => unawaited(engine.skipNext()),
        icon: const FushiIcon(FushiIcons.skipNext),
      ),
    ],
  );
}

/// 窄屏：形状唱片 + 圆环波浪进度 + 按钮组。
class _CompactMusicBar extends StatelessWidget {
  const _CompactMusicBar({
    required this.session,
    required this.item,
    required this.roomy,
  });

  final MusicSession session;
  final MusicPlayItem item;

  /// 宽度够时平铺信号路径 / 停止；不够时它们在长按菜单里。
  final bool roomy;

  @override
  Widget build(BuildContext context) => _CollapsePeek(
    builder: (BuildContext context, bool collapsed, VoidCallback peek) {
      final ColorScheme cs = Theme.of(context).colorScheme;
      final MusicPlayerEngine engine = session.engine;
      // 宿主页往下滚时收成小胶囊（封面圆环 + 播放键），往上滚展开（与底部导航同步）。
      final Duration motion = fushiMotionDuration(context, FushiMotion.medium);
      final Widget card = _BarShell(
        padding: EdgeInsets.fromLTRB(8, 8, collapsed ? 8 : 10, 8),
        // 收起时点一下先展开，展开后再点才进播放页。
        onTap: collapsed ? peek : null,
        child: FushiAnimatedSize(
          duration: motion,
          curve: FushiSpringCurve.spatial,
          alignment: AlignmentDirectional.centerEnd,
          child: Row(
            mainAxisSize: collapsed ? MainAxisSize.min : MainAxisSize.max,
            children: <Widget>[
              SizedBox.square(
                dimension: 60,
                child: Stack(
                  alignment: Alignment.center,
                  children: <Widget>[
                    FushiWavyCircularProgress(
                      value: _progressOf(engine),
                      color: cs.primary,
                      trackColor: cs.onSurface.withValues(alpha: 0.12),
                      strokeWidth: 3,
                      size: 60,
                      padding: EdgeInsets.zero,
                    ),
                    _shapedCover(item, 44),
                  ],
                ),
              ),
              if (!collapsed) ...<Widget>[
                const SizedBox(width: 12),
                Expanded(child: _BarTitle(item: item)),
                const SizedBox(width: 8),
                if (roomy) ...<Widget>[
                  musicPlayModeButton(context, engine),
                  const MusicVolumeButton(),
                  const SizedBox(width: 4),
                ],
                musicTransportGroup(session, playSize: 48),
                if (roomy) _musicBarCloseButton(session),
              ],
            ],
          ),
        ),
      );
      return Padding(
        padding: const EdgeInsets.fromLTRB(
          kFushiFloatingToolbarEdgeMargin,
          4,
          kFushiFloatingToolbarEdgeMargin,
          8,
        ),
        child: AnimatedAlign(
          duration: motion,
          curve: FushiSpringCurve.effects,
          heightFactor: 1,
          alignment: collapsed
              ? AlignmentDirectional.centerEnd.resolve(
                  Directionality.of(context),
                )
              : Alignment.center,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: roomy
                ? card
                : ContextMenuTrigger(
                    onInvoke: contextMenuInvoker(
                      () => unawaited(_moreMenu(context)),
                    ),
                    child: GestureDetector(
                      onLongPress: () => unawaited(_moreMenu(context)),
                      child: card,
                    ),
                  ),
          ),
        ),
      );
    },
  );

  Future<void> _moreMenu(BuildContext context) async {
    final AppModel appModel = ProviderScope.containerOf(
      context,
    ).read(appProvider);
    await adaptiveModalSheet<void>(
      context: context,
      builder: (BuildContext sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            FushiListTileControl(
              leading: const FushiIcon(FushiIcons.highQuality),
              title: Text(t.music_signal_path_title),
              onTap: () {
                Navigator.of(sheet).pop();
                unawaited(showMusicSignalPathPanel(context, appModel));
              },
            ),
            FushiListTileControl(
              leading: const FushiIcon(FushiIcons.stop),
              title: Text(t.music_stop),
              onTap: () {
                Navigator.of(sheet).pop();
                unawaited(session.stop());
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// 播放引擎的位置读口（波浪进度条用；播放条与歌词页共用）。
class MusicEngineClock implements FushiPlaybackClock {
  const MusicEngineClock(this.engine);

  final MusicPlayerEngine engine;

  @override
  Duration get position => engine.position;

  @override
  Duration get duration => engine.duration ?? Duration.zero;
}

/// 宽屏：「灵动岛」——平时是底部居中的一颗小胶囊（圆环波浪封面 + 歌名 + 跳动的
/// 音量柱 + 播放键），几乎不挡内容；鼠标移上去（触屏先点一下）弹性展开，露出歌手、
/// 上 / 下一首按钮组、信号路径、歌词与停止。底色 / 不对称圆角 / 饼干形封面 / 圆环
/// 波浪与窄屏卡片同一套（用户 2026-10-29：两个方案结合）。
class _DockedMusicBar extends StatefulWidget {
  const _DockedMusicBar({required this.session, required this.item});

  final MusicSession session;
  final MusicPlayItem item;

  @override
  State<_DockedMusicBar> createState() => _DockedMusicBarState();
}

class _DockedMusicBarState extends State<_DockedMusicBar> {
  bool _hovered = false;

  /// 触屏点开的展开态（没有悬停可依赖）；点到岛外或鼠标离开时收起。
  bool _pinned = false;

  /// 音量滑杆开着：滑杆浮在岛外，鼠标移过去会离开岛，这期间不许收起。
  bool _menuOpen = false;

  bool get _expanded =>
      _hovered ||
      _pinned ||
      _menuOpen ||
      MusicBarCollapse.maybeOf(context) == false;

  @override
  Widget build(BuildContext context) {
    final MusicSession session = widget.session;
    final MusicPlayerEngine engine = session.engine;
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool expanded = _expanded;
    // 宽屏「灵动岛」随宿主页滚动：往下滚缩回小胶囊、往上滚弹性展开（用户
    // 2026-10-29），悬停 / 点一下也照常展开。
    final double ring = expanded ? 60 : 48;
    final Duration motion = fushiMotionDuration(context, FushiMotion.medium);
    final Widget cover = ListenableBuilder(
      listenable: engine,
      builder: (BuildContext context, _) => SizedBox.square(
        dimension: ring,
        child: Stack(
          alignment: Alignment.center,
          children: <Widget>[
            FushiWavyCircularProgress(
              value: _progressOf(engine),
              color: cs.primary,
              trackColor: cs.onSurface.withValues(alpha: 0.12),
              strokeWidth: 3,
              size: ring,
              padding: EdgeInsets.zero,
            ),
            _shapedCover(widget.item, ring - 16),
          ],
        ),
      ),
    );
    final Widget collapsed = Row(
      key: const ValueKey<String>('music-island-collapsed'),
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        cover,
        ...<Widget>[
          const SizedBox(width: 12),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 200),
            child: Text(
              widget.item.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.fushiType.titleSmallEmphasized,
            ),
          ),
          const SizedBox(width: 14),
          _LevelBars(playing: engine.isPlaying, color: cs.primary),
        ],
        ...<Widget>[
          const SizedBox(width: 12),
          FushiExpressivePlayButton(
            key: const ValueKey<String>('music_bar_play_pause'),
            isPlaying: engine.isPlaying,
            size: 44,
            onPressed: () => unawaited(engine.togglePlayPause()),
          ),
        ],
      ],
    );
    final Widget open = Row(
      key: const ValueKey<String>('music-island-expanded'),
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        cover,
        const SizedBox(width: 14),
        SizedBox(width: 220, child: _BarTitle(item: widget.item)),
        const SizedBox(width: 12),
        musicTransportGroup(session, playSize: 52),
        const SizedBox(width: 12),
        // 展开态右侧只留循环与音量（用户 2026-10-29）；信号路径在歌词页「⋯」里，
        // 点条身进播放页。
        musicPlayModeButton(context, engine),
        MusicVolumeButton(
          onOpenChanged: (bool open) => setState(() => _menuOpen = open),
        ),
        _musicBarCloseButton(session),
      ],
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
      child: AnimatedAlign(
        duration: motion,
        curve: FushiSpringCurve.effects,
        heightFactor: 1,
        alignment: Alignment.center,
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() {
            _hovered = false;
            _pinned = false;
          }),
          child: TapRegion(
            onTapOutside: (_) {
              if (_pinned) setState(() => _pinned = false);
            },
            child: _BarShell(
              padding: EdgeInsets.fromLTRB(8, 6, expanded ? 12 : 8, 6),
              // 收起时第一下只展开（触屏没有悬停）；展开后点条身才进播放页。
              onTap: expanded ? null : () => setState(() => _pinned = true),
              child: FushiAnimatedSize(
                duration: motion,
                curve: FushiSpringCurve.spatial,
                child: AnimatedSwitcher(
                  duration: fushiMotionDuration(context, FushiMotion.short),
                  layoutBuilder: (Widget? current, List<Widget> previous) =>
                      Stack(
                        alignment: Alignment.center,
                        clipBehavior: Clip.none,
                        children: <Widget>[
                          for (final Widget w in previous) Positioned(child: w),
                          ?current,
                        ],
                      ),
                  child: expanded ? open : collapsed,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 灵动岛里跳动的音量柱：播放时四根柱错相起伏，暂停时落成一排短柱。
class _LevelBars extends StatefulWidget {
  const _LevelBars({required this.playing, required this.color});

  final bool playing;
  final Color color;

  @override
  State<_LevelBars> createState() => _LevelBarsState();
}

class _LevelBarsState extends State<_LevelBars>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(covariant _LevelBars oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    final bool run = widget.playing && fushiExpressiveMotionEnabled(context);
    if (run && !_ctrl.isAnimating) {
      unawaited(_ctrl.repeat());
    } else if (!run && _ctrl.isAnimating) {
      _ctrl.stop();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 22,
    height: 20,
    child: CustomPaint(
      painter: _LevelBarsPainter(
        progress: _ctrl,
        active: widget.playing,
        color: widget.color,
      ),
    ),
  );
}

class _LevelBarsPainter extends CustomPainter {
  _LevelBarsPainter({
    required this.progress,
    required this.active,
    required this.color,
  }) : super(repaint: progress);

  final Animation<double> progress;
  final bool active;
  final Color color;

  static const List<double> _phase = <double>[0, 0.55, 0.2, 0.8];
  static const List<double> _speed = <double>[1, 2, 3, 2];

  @override
  void paint(Canvas canvas, Size size) {
    const int n = 4;
    final double gap = size.width / (n * 2 - 1);
    final Paint paint = Paint()..color = color;
    final double t = progress.value;
    for (int i = 0; i < n; i++) {
      final double wave = active
          ? 0.5 + 0.5 * math.sin(2 * math.pi * (t * _speed[i] + _phase[i]))
          : 0;
      final double h = size.height * (0.22 + 0.78 * wave);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(i * gap * 2, (size.height - h) / 2, gap, h),
          Radius.circular(gap / 2),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _LevelBarsPainter old) =>
      old.active != active || old.color != color;
}

/// 有音乐在播时正文底部额外让出的高度：悬浮播放条（含上下外边距）的占位，
/// 列表最后一行能滚到条的上方。
const double kMusicFloatingBarReserve = 88;

/// 悬浮播放条宿主（用户 2026-10-29：「需要所有界面都是浮起来的」）：正文铺满，
/// 播放条叠在底部、不占一行。条贴在原底部安全区之上（玻璃移动布局的悬浮标签栏
/// 让位也走这个 padding）。结构恒定：有无音乐都是同一个 Stack，正文不重挂。
///
/// [reserveSpace]：有音乐在播时给正文底部让出 [kMusicFloatingBarReserve]（见
/// [MusicBarReserve]）。首页传 false——它的各个 tab（设置、书架 …）有用 SafeArea
/// 截视口的，整页加高会把列表截短、底下空一截；音乐页自己再包 [MusicBarReserve]。
class MusicFloatingBarHost extends StatefulWidget {
  const MusicFloatingBarHost({
    super.key,
    required this.child,
    this.reserveSpace = true,
  });

  final Widget child;
  final bool reserveSpace;

  @override
  State<MusicFloatingBarHost> createState() => _MusicFloatingBarHostState();
}

class _MusicFloatingBarHostState extends State<MusicFloatingBarHost> {
  /// 正文往下滚 → 收起，往上滚 → 展开（用户 2026-10-29：所有页面、窄宽屏都要）。
  bool _collapsed = false;

  bool _onScroll(UserScrollNotification n) {
    if (n.metrics.axis != Axis.vertical) return false;
    final bool? next = switch (n.direction) {
      ScrollDirection.reverse => true,
      ScrollDirection.forward => false,
      ScrollDirection.idle => null,
    };
    if (next != null && next != _collapsed) {
      setState(() => _collapsed = next);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final Widget content = widget.reserveSpace
        ? MusicBarReserve(child: widget.child)
        : widget.child;
    // 嵌在别的宿主下面（首页 tab 里推入的页面）：外层已经在画条，不再叠一条，
    // 但正文仍要给条让位。
    if (context.dependOnInheritedWidgetOfExactType<_MusicFloatingBarScope>() !=
        null) {
      return content;
    }
    final double bottom = MediaQuery.paddingOf(context).bottom;
    return _MusicFloatingBarScope(
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            child: NotificationListener<UserScrollNotification>(
              onNotification: _onScroll,
              child: content,
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: bottom,
            child: MusicBarCollapse(
              collapsed: _collapsed,
              child: const MusicNowPlayingBar(),
            ),
          ),
        ],
      ),
    );
  }
}

/// 有音乐在播时把 [kMusicFloatingBarReserve] 加进子树的底部 MediaQuery padding
/// （`withBottomSafeInset` 等按它留白），列表最后一行能滚到悬浮条上方。
class MusicBarReserve extends ConsumerStatefulWidget {
  const MusicBarReserve({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<MusicBarReserve> createState() => _MusicBarReserveState();
}

class _MusicBarReserveState extends ConsumerState<MusicBarReserve> {
  MusicSession? _session;
  bool _active = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final MusicSession session = ref.read(appProvider).musicSession;
    if (!identical(session, _session)) {
      _session?.removeListener(_onSession);
      _session = session..addListener(_onSession);
      _active = session.isActive;
    }
  }

  @override
  void dispose() {
    _session?.removeListener(_onSession);
    super.dispose();
  }

  /// 会话频繁通知（位置等），只在「有没有在播」翻转时才重建。
  void _onSession() {
    final bool active = _session?.isActive ?? false;
    if (active != _active && mounted) setState(() => _active = active);
  }

  @override
  Widget build(BuildContext context) {
    final MediaQueryData media = MediaQuery.of(context);
    return MediaQuery(
      data: _active
          ? media.copyWith(
              padding: media.padding.copyWith(
                bottom: media.padding.bottom + kMusicFloatingBarReserve,
              ),
            )
          : media,
      child: widget.child,
    );
  }
}

/// 标记「上面已经有一个悬浮播放条宿主」。
class _MusicFloatingBarScope extends InheritedWidget {
  const _MusicFloatingBarScope({required super.child});

  @override
  bool updateShouldNotify(_MusicFloatingBarScope oldWidget) => false;
}

/// 播放模式按钮（循环切：顺序 → 列表循环 → 单曲循环 → 随机 → 顺序）；歌词页按钮行
/// 与底部播放条共用。
Widget musicPlayModeButton(
  BuildContext context,
  MusicPlayerEngine engine, {
  double? iconSize,
}) {
  final MusicRepeatMode repeat = engine.repeatMode;
  final bool shuffled = engine.shuffled;
  final (IconData glyph, String tip, bool on) = shuffled
      ? (FushiIcons.shuffle, t.music_play_mode_shuffle, true)
      : switch (repeat) {
          MusicRepeatMode.off => (
            FushiIcons.repeat,
            t.music_play_mode_sequential,
            false,
          ),
          MusicRepeatMode.all => (
            FushiIcons.repeat,
            t.music_play_mode_repeat_all,
            true,
          ),
          MusicRepeatMode.one => (
            FushiIcons.repeatOne,
            t.music_play_mode_repeat_one,
            true,
          ),
        };
  Future<void> cycle() async {
    if (shuffled) {
      await engine.setShuffle(false);
      await engine.setRepeatMode(MusicRepeatMode.off);
    } else {
      switch (repeat) {
        case MusicRepeatMode.off:
          await engine.setRepeatMode(MusicRepeatMode.all);
        case MusicRepeatMode.all:
          await engine.setRepeatMode(MusicRepeatMode.one);
        case MusicRepeatMode.one:
          await engine.setRepeatMode(MusicRepeatMode.all);
          await engine.setShuffle(true);
      }
    }
  }

  return FushiIconButtonControl(
    key: const ValueKey<String>('music_lyrics_play_mode'),
    iconSize: iconSize,
    isSelected: on,
    tooltip: tip,
    onPressed: () => unawaited(cycle()),
    icon: AnimatedSwitcher(
      duration: fushiMotionDuration(context, FushiMotion.short),
      child: FushiIcon(glyph, key: ValueKey<IconData>(glyph)),
    ),
  );
}

/// 音量：点开一条横向滑杆（0–100，写偏好并即时下发给后端）。
/// 关闭迷你条：停止音乐并释放媒体会话（条随之消失）。用户 2026-10-30「底部栏
/// 提供个按钮关闭」——原来只藏在长按菜单的「停止音乐」里。
Widget _musicBarCloseButton(MusicSession session) => FushiIconButtonControl(
  key: const ValueKey<String>('music_bar_close'),
  tooltip: t.music_stop,
  onPressed: () => unawaited(session.stop()),
  icon: const FushiIcon(FushiIcons.close),
);

/// 音量按钮：点开弹出音量滑杆（迷你条与播放页共用，读写 [AppModel.musicVolume]）。
class MusicVolumeButton extends StatefulWidget {
  const MusicVolumeButton({super.key, this.onOpenChanged, this.iconSize});

  /// 图标尺寸；null = 按钮默认（迷你条）。播放页按钮行传自己的统一尺寸。
  final double? iconSize;

  /// 滑杆展开 / 收起（宿主据此保持展开，见 [_DockedMusicBarState]）。
  final ValueChanged<bool>? onOpenChanged;

  @override
  State<MusicVolumeButton> createState() => _MusicVolumeButtonState();
}

class _MusicVolumeButtonState extends State<MusicVolumeButton> {
  final MenuController _menu = MenuController();
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    final AppModel appModel = ProviderScope.containerOf(
      context,
    ).read(appProvider);
    final double volume = _dragging ?? appModel.musicVolume;
    return MenuAnchor(
      controller: _menu,
      alignmentOffset: const Offset(-96, 8),
      onOpen: () => widget.onOpenChanged?.call(true),
      onClose: () => widget.onOpenChanged?.call(false),
      menuChildren: <Widget>[
        StatefulBuilder(
          builder: (BuildContext context, StateSetter setInner) {
            final double v = _dragging ?? appModel.musicVolume;
            return SizedBox(
              width: 240,
              child: Row(
                children: <Widget>[
                  const SizedBox(width: 12),
                  FushiIcon(
                    v <= 0 ? FushiIcons.volumeOff : FushiIcons.volumeUp,
                    size: 20,
                  ),
                  Expanded(
                    child: adaptiveSlider(
                      context: context,
                      value: v.clamp(0, 100),
                      max: 100,
                      onChanged: (double next) {
                        setInner(() => _dragging = next);
                        setState(() {});
                        unawaited(appModel.setMusicVolume(next));
                      },
                      onChangeEnd: (_) => setState(() => _dragging = null),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ],
      builder: (BuildContext context, MenuController menu, Widget? _) =>
          FushiIconButtonControl(
            key: const ValueKey<String>('music_bar_volume'),
            tooltip: t.music_volume_title,
            isSelected: menu.isOpen,
            iconSize: widget.iconSize,
            onPressed: () => menu.isOpen ? menu.close() : menu.open(),
            icon: FushiIcon(
              volume <= 0 ? FushiIcons.volumeOff : FushiIcons.volumeUp,
            ),
          ),
    );
  }
}

/// 宿主页的「滚动收起」状态（首页随底部导航一起收，见 home_page）：窄屏卡片据此
/// 缩成只剩封面圆环 + 播放键的小胶囊。没有这层时恒为展开。
class MusicBarCollapse extends InheritedWidget {
  const MusicBarCollapse({
    super.key,
    required this.collapsed,
    required super.child,
  });

  final bool collapsed;

  static bool of(BuildContext context) => maybeOf(context) ?? false;

  /// 没有宿主收起状态时为 null（单独推出的页面）。
  static bool? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MusicBarCollapse>()?.collapsed;

  @override
  bool updateShouldNotify(MusicBarCollapse oldWidget) =>
      oldWidget.collapsed != collapsed;
}

/// 滚动收起的「先展开」：收起时点一下只展开（[peek]），展开后再点才进播放页；
/// 宿主的收起状态一翻转（再往下 / 往上滚）就把这次展开作废。
class _CollapsePeek extends StatefulWidget {
  const _CollapsePeek({required this.builder});

  final Widget Function(BuildContext context, bool collapsed, VoidCallback peek)
  builder;

  @override
  State<_CollapsePeek> createState() => _CollapsePeekState();
}

class _CollapsePeekState extends State<_CollapsePeek> {
  bool? _hostCollapsed;
  bool _peeking = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final bool host = MusicBarCollapse.of(context);
    if (host != _hostCollapsed) {
      _hostCollapsed = host;
      _peeking = false;
    }
  }

  @override
  Widget build(BuildContext context) => widget.builder(
    context,
    (_hostCollapsed ?? false) && !_peeking,
    () => setState(() => _peeking = true),
  );
}
