/// 音乐迷你播放条（设计 §11.2）：与有声书「正在听书」条互斥——媒体会话归谁就显示谁
/// （[MediaSessionOwner]）。
///
/// 外壳是与有声书条共用的 [FushiNowPlayingBar]（封面取色色块 + 出血标题大字 +
/// 九角饼干封面外绕波浪进度 + M3E 按钮组；宽屏底部居中浮动色块、窄屏底栏上方
/// 卡片，见该组件文件头）。本文件只把音乐会话接上去：歌名 / 歌手 · 专辑、试听
/// 标记、上一首 / 下一首、队列 · 播放模式 · 音量 · 关闭四个额外动作，窄屏放不下
/// 时收进长按菜单（音质 / 队列 / 信号路径 / 音效 / 停止）。
library;

import 'dart:async';

import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/media/music/music_session.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/audio_controller.dart';
import 'package:fushi/src/pages/implementations/music/music_cover.dart';
import 'package:fushi/src/pages/implementations/music/music_preview_badge.dart';
import 'package:fushi/src/pages/implementations/music/music_audio_effects_page.dart';
import 'package:fushi/src/pages/implementations/music/music_signal_path_panel.dart';
import 'package:fushi/src/pages/implementations/music/music_quality_sheet.dart';
import 'package:fushi/src/pages/implementations/music/music_lyrics_page.dart';
import 'package:fushi/src/pages/implementations/music/music_queue_panel.dart';
import 'package:fushi/src/utils/components/fushi_m3e_player.dart';
import 'package:fushi/src/utils/components/fushi_now_playing_bar.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart';

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
        return _musicBar(context, appModel, session, item);
      },
    );
  }
}

/// 把音乐会话接到共用的 [FushiNowPlayingBar] 上。
Widget _musicBar(
  BuildContext context,
  AppModel appModel,
  MusicSession session,
  MusicPlayItem item,
) {
  final MusicPlayerEngine engine = session.engine;
  final String byline = <String?>[
    item.artist,
    item.album,
  ].whereType<String>().where((String v) => v.isNotEmpty).join(' · ');
  return FushiNowPlayingBar(
    barKey: const ValueKey<String>('music_bar_open_player'),
    playButtonKey: const ValueKey<String>('music_bar_play_pause'),
    title: item.title,
    subtitle: byline.isEmpty ? t.music_now_playing : byline,
    titleTrailing: MusicPreviewBadgeSwitcher(visible: item.isPreview),
    coverBuilder: (BuildContext context, double size) =>
        MusicCover(coverPath: item.coverPath, size: size),
    tintImage: musicCoverImageProvider(item.coverPath, size: 128),
    clock: MusicEngineClock(engine),
    isPlaying: engine.isPlaying,
    onPlayPause: () => unawaited(engine.togglePlayPause()),
    previous: FushiNowPlayingSkip(
      icon: FushiIcons.skipPrevious,
      tooltip: t.shortcut_action_music_previous_track,
      onPressed: engine.canSkipPrevious
          ? () => unawaited(engine.skipPrevious())
          : null,
    ),
    next: FushiNowPlayingSkip(
      icon: FushiIcons.skipNext,
      tooltip: t.shortcut_action_music_next_track,
      onPressed: () => unawaited(engine.skipNext()),
    ),
    actions: <Widget>[
      musicQueueButton(context, engine),
      musicPlayModeButton(context, engine),
      // 音量滑杆浮在条外：开着时让宽屏色块保持展开。
      Builder(
        builder: (BuildContext context) => MusicVolumeButton(
          onOpenChanged: FushiNowPlayingBar.holdExpandedOf(context),
        ),
      ),
      _musicBarCloseButton(session),
    ],
    onMore: () => unawaited(_musicBarMoreMenu(context, appModel, session)),
    onTap: () => _openPlayer(context),
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

/// 窄屏放不下额外动作时的长按 / 右键菜单。
Future<void> _musicBarMoreMenu(
  BuildContext context,
  AppModel appModel,
  MusicSession session,
) async {
  await adaptiveModalSheet<void>(
    context: context,
    builder: (BuildContext sheet) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (musicItemQualitySelectable(session.engine.current))
            FushiListTileControl(
              key: const ValueKey<String>('music_bar_quality'),
              leading: const FushiIcon(FushiIcons.highQuality),
              title: Text(t.music_quality_title),
              subtitle: Text(
                musicPluginQualityLabel(
                  appModel.musicPluginQualityFor(session.engine.current!.path),
                ),
              ),
              onTap: () {
                Navigator.of(sheet).pop();
                unawaited(showMusicQualitySheet(context, appModel));
              },
            ),
          FushiListTileControl(
            key: const ValueKey<String>('music_bar_menu_queue'),
            leading: const FushiIcon(FushiIcons.playlist),
            title: Text(t.music_queue_title),
            onTap: () {
              Navigator.of(sheet).pop();
              unawaited(showMusicQueue(context, session.engine));
            },
          ),
          if (session.engine.capabilities.signalPath)
            FushiListTileControl(
              leading: const FushiIcon(FushiIcons.highQuality),
              title: Text(t.music_signal_path_title),
              onTap: () {
                Navigator.of(sheet).pop();
                unawaited(showMusicSignalPathPanel(context, appModel));
              },
            ),
          // 音效：托管播放的后端（Apple Music 等）拿不到信号，效果器对它无效，不给入口。
          if (session.engine.capabilities.signalPath)
            FushiListTileControl(
              leading: const FushiIcon(FushiIcons.barChart),
              title: Text(t.music_effects_title),
              onTap: () {
                Navigator.of(sheet).pop();
                unawaited(showMusicAudioEffectsPanel(context, appModel));
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

/// 播放引擎的位置读口（波浪进度条用；播放条与歌词页共用）。
class MusicEngineClock implements FushiPlaybackClock {
  const MusicEngineClock(this.engine);

  final MusicPlayerEngine engine;

  @override
  Duration get position => engine.position;

  @override
  Duration get duration => engine.duration ?? Duration.zero;
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
            child: FushiNowPlayingCollapse(
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
    // 电台由 MusicKit 排队，随机 / 循环无意义。
    onPressed: engine.canShuffleOrRepeat ? () => unawaited(cycle()) : null,
    icon: AnimatedSwitcher(
      duration: fushiMotionDuration(context, FushiMotion.short),
      child: FushiIcon(glyph, key: ValueKey<IconData>(glyph)),
    ),
  );
}

/// 播放队列按钮（迷你条 / 停靠条，纯图标）：窄屏弹底部弹层、宽屏从右侧滑出侧栏
/// （[showMusicQueue]）。
Widget musicQueueButton(BuildContext context, MusicPlayerEngine engine) =>
    FushiPressScale(
      child: FushiIconButtonControl(
        key: const ValueKey<String>('music_bar_queue'),
        tooltip: t.music_queue_title,
        onPressed: () => unawaited(showMusicQueue(context, engine)),
        icon: const FushiIcon(FushiIcons.playlist),
      ),
    );

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

  /// 滑杆展开 / 收起（宿主据此保持展开，见 [FushiNowPlayingBar.holdExpandedOf]）。
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
