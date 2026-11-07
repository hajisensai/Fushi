/// 播放队列面板（设计稿 ③ / W1 / W3）：正文只有一份 [MusicQueuePanel]，窄屏装进底部弹层
/// （[showMusicQueue]），宽屏装进全屏播放页右侧的常驻侧栏（[MusicQueueSidebar]）或从右侧
/// 滑出的同一个侧栏（曲库页播放条的队列按钮）。
///
/// 队列状态全在 [MusicPlayerEngine]（顺序、当前曲、「下一首播放」标记）；面板只读引擎、发
/// 编辑命令，不存镜像。唯一的本地状态是「刚移出、可撤销」的那一首（撤销 = 放回原位置）与
/// 拖动排序时的落点。
///
/// 交互：点一行跳播（桌面双击跳播、单击选中）；左滑移出（底部提示可撤销）；桌面悬停 / 选中
/// 时行内出现移出按钮，Delete / Backspace 移出选中行；右侧手柄拖动排序，插入线指示落点。
/// 外部队列（Apple Music 电台，[MusicPlayerEngine.canEditQueue] 为假）下编辑入口全部禁用。
library;

import 'dart:async';

import 'package:flutter/gestures.dart'
    show PointerDeviceKind, kDoubleTapTimeout;
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/pages/implementations/music/music_cover.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/app_ui_scale.dart';
import 'package:fushi/src/utils/components/fushi_mine_notice_card.dart'
    show kMineNoticeActionVisibleFor;
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';

/// 侧栏宽度（设计稿 W1）。
const double kMusicQueueSidebarWidth = 360;

/// 这个宽度（真实视口宽，见 [windowSizeClassReal]）下队列用侧栏而不是底部弹层：仓库统一的
/// expanded 档（≥ 840）。
bool musicQueueUsesSidebar(BuildContext context, double logicalWidth) =>
    windowSizeClassReal(logicalWidth, FushiAppUiScale.of(context)) ==
    WindowSizeClass.expanded;

/// 打开播放队列：宽屏从右侧滑出侧栏，窄屏底部弹层。
Future<void> showMusicQueue(BuildContext context, MusicPlayerEngine engine) {
  final Size screen = MediaQuery.sizeOf(context);
  if (musicQueueUsesSidebar(context, screen.width)) {
    final Duration motion = fushiMotionDuration(context, FushiMotion.medium);
    return showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: Colors.black.withValues(alpha: 0.18),
      transitionDuration: motion,
      pageBuilder: (BuildContext c, _, _) => Align(
        alignment: AlignmentDirectional.centerEnd,
        child: SafeArea(
          left: false,
          child: MusicQueueSidebar(engine: engine, elevated: true),
        ),
      ),
      transitionBuilder:
          (
            BuildContext c,
            Animation<double> animation,
            Animation<double> secondary,
            Widget child,
          ) {
            final bool rtl = Directionality.of(c) == TextDirection.rtl;
            return SlideTransition(
              position:
                  Tween<Offset>(
                    begin: Offset(rtl ? -1 : 1, 0),
                    end: Offset.zero,
                  ).animate(
                    CurvedAnimation(
                      parent: animation,
                      curve: FushiSpringCurve.spatial,
                      reverseCurve: FushiSpringCurve.effects,
                    ),
                  ),
              child: child,
            );
          },
    );
  }
  return adaptiveModalSheet<void>(
    context: context,
    builder: (BuildContext sheet) => SizedBox(
      height: (screen.height * 0.75).clamp(320, 720).toDouble(),
      child: MusicQueuePanel(engine: engine),
    ),
  );
}

/// 侧栏外壳（全屏播放页右侧常驻 / 曲库页从右侧滑出）：约 360 宽、左边一道分隔线。
class MusicQueueSidebar extends StatelessWidget {
  const MusicQueueSidebar({
    super.key,
    required this.engine,
    this.elevated = false,
  });

  final MusicPlayerEngine engine;

  /// 浮在页面上（滑出式）：加投影、不透明底色。
  final bool elevated;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Material(
      type: MaterialType.canvas,
      color: elevated
          ? cs.surfaceContainerLow
          : cs.surfaceContainerLow.withValues(alpha: 0.72),
      elevation: elevated ? 6 : 0,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: BorderDirectional(
            start: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.5)),
          ),
        ),
        child: SizedBox(
          width: kMusicQueueSidebarWidth,
          child: MusicQueuePanel(engine: engine, sidebar: true),
        ),
      ),
    );
  }
}

/// `m:ss`（与曲目列表的 `formatMusicDuration` 同格式；不 import 曲目列表，免得本面板经
/// 播放条接进 AppModel 的大 import 环，见 `import_cycle_guard_test.dart`）。
String _mmss(int ms) {
  final int s = ms ~/ 1000;
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

/// 总时长的显示（「1 小时 38 分」/「42 分钟」）。
String musicQueueDurationLabel(Duration d) {
  final int hours = d.inHours;
  final int minutes = d.inMinutes.remainder(60);
  return hours > 0
      ? t.music_queue_duration_hours(hours: hours, minutes: minutes)
      : t.music_queue_duration_minutes(minutes: minutes);
}

/// 队列正文。
class MusicQueuePanel extends StatefulWidget {
  const MusicQueuePanel({
    super.key,
    required this.engine,
    this.sidebar = false,
  });

  final MusicPlayerEngine engine;

  /// 装在侧栏里（宽屏）：标题字号收一档、桌面下底部给操作提示。
  final bool sidebar;

  @override
  State<MusicQueuePanel> createState() => _MusicQueuePanelState();
}

/// 刚移出、可撤销的那一首。
typedef _Removed = ({MusicPlayItem item, int index, bool playNext});

class _MusicQueuePanelState extends State<MusicQueuePanel> {
  final ScrollController _scroll = ScrollController();
  final GlobalKey _viewportKey = GlobalKey();
  _Removed? _undo;
  Timer? _undoTimer;

  /// 拖动中：被拖的那一格、落点（插到哪一格之前；等于队列长度 = 放到队尾）。
  int? _dragFrom;
  int? _dropBefore;

  MusicPlayerEngine get _engine => widget.engine;

  @override
  void dispose() {
    _undoTimer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _remove(int index) async {
    final List<MusicPlayItem> q = _engine.queue;
    if (index < 0 || index >= q.length || index == _engine.index) return;
    final _Removed removed = (
      item: q[index],
      index: index,
      playNext: _engine.isPlayNextAt(index),
    );
    _undoTimer?.cancel();
    setState(() => _undo = removed);
    _undoTimer = Timer(kMineNoticeActionVisibleFor, () {
      if (mounted) setState(() => _undo = null);
    });
    await _engine.removeFromQueue(index);
  }

  Future<void> _restore() async {
    final _Removed? removed = _undo;
    _undoTimer?.cancel();
    setState(() => _undo = null);
    if (removed == null) return;
    await _engine.insertIntoQueue(
      removed.index,
      removed.item,
      playNext: removed.playNext,
    );
  }

  void _onDragUpdate(DragUpdateDetails d) {
    // 拖到列表上下边缘时自动滚动。
    final RenderObject? box = _viewportKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !_scroll.hasClients) return;
    final double y = box.globalToLocal(d.globalPosition).dy;
    const double edge = 48;
    double delta = 0;
    if (y < edge) delta = -(edge - y) / 3;
    if (y > box.size.height - edge) delta = (y - (box.size.height - edge)) / 3;
    if (delta == 0) return;
    final ScrollPosition p = _scroll.position;
    _scroll.jumpTo(
      (p.pixels + delta).clamp(p.minScrollExtent, p.maxScrollExtent),
    );
  }

  void _endDrag() => setState(() {
    _dragFrom = null;
    _dropBefore = null;
  });

  Future<void> _drop(int from) async {
    final int? before = _dropBefore;
    _endDrag();
    if (before == null) return;
    // 拿起后后面的格子都往前挪了一格。
    final int to = before > from ? before - 1 : before;
    if (to == from) return;
    await _engine.moveInQueue(from, to);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _engine,
    builder: (BuildContext context, _) {
      final List<MusicPlayItem> queue = _engine.queue;
      final int current = _engine.index;
      final bool editable = _engine.canEditQueue;
      final ColorScheme cs = Theme.of(context).colorScheme;
      final MusicPlayItem? playing = _engine.current;
      return Stack(
        children: <Widget>[
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _header(context, queue),
              _modeRow(context, editable, queue.length),
              if (!editable && queue.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Text(
                    t.music_queue_external_locked,
                    style: context.fushiType.bodySmall.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ),
              Expanded(
                child: LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints box) =>
                      FushiEntranceScope(
                        child: CustomScrollView(
                          key: _viewportKey,
                          controller: _scroll,
                          slivers: <Widget>[
                            if (playing != null) ...<Widget>[
                              _sectionLabel(context, t.music_now_playing),
                              SliverToBoxAdapter(
                                child: FushiStaggeredEntrance(
                                  index: 0,
                                  child: _CurrentRow(item: playing),
                                ),
                              ),
                              _sectionLabel(context, t.music_queue_up_next),
                            ],
                            if (current + 1 >= queue.length)
                              SliverToBoxAdapter(
                                child: Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    20,
                                    8,
                                    20,
                                    24,
                                  ),
                                  child: Text(
                                    t.music_queue_up_next_empty,
                                    style: context.fushiType.bodyMedium
                                        .copyWith(color: cs.onSurfaceVariant),
                                  ),
                                ),
                              )
                            else
                              SliverList.builder(
                                itemCount: queue.length - current - 1,
                                itemBuilder: (BuildContext context, int k) {
                                  final int i = current + 1 + k;
                                  return FushiStaggeredEntrance(
                                    index: k + 1,
                                    child: _upcoming(
                                      context,
                                      queue,
                                      i,
                                      editable: editable,
                                      width: box.maxWidth,
                                    ),
                                  );
                                },
                              ),
                            const SliverToBoxAdapter(
                              child: SizedBox(height: 72),
                            ),
                          ],
                        ),
                      ),
                ),
              ),
              if (widget.sidebar && isDesktopPlatform && editable)
                DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border(
                      top: BorderSide(
                        color: cs.outlineVariant.withValues(alpha: 0.5),
                      ),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 10, 20, 12),
                    child: Text(
                      t.music_queue_desktop_hint,
                      style: context.fushiType.bodySmall.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          PositionedDirectional(
            start: 12,
            end: 12,
            bottom: 12,
            child: AnimatedSwitcher(
              duration: fushiMotionDuration(context, FushiMotion.short),
              transitionBuilder: (Widget child, Animation<double> a) =>
                  FadeTransition(
                    opacity: a,
                    child: SlideTransition(
                      position: Tween<Offset>(
                        begin: const Offset(0, 0.4),
                        end: Offset.zero,
                      ).animate(a),
                      child: child,
                    ),
                  ),
              child: _undo == null
                  ? const SizedBox.shrink()
                  : _UndoBar(
                      key: ValueKey<_Removed>(_undo!),
                      title: _undo!.item.title,
                      onUndo: () => unawaited(_restore()),
                    ),
            ),
          ),
        ],
      );
    },
  );

  Widget _header(BuildContext context, List<MusicPlayItem> queue) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final int totalMs = queue.fold<int>(
      0,
      (int sum, MusicPlayItem i) => sum + (i.durationMs ?? 0),
    );
    final String duration = musicQueueDurationLabel(
      Duration(milliseconds: totalMs),
    );
    final String? source = _engine.source?.title;
    final String summary = source == null || source.isEmpty
        ? t.music_queue_summary(count: queue.length, duration: duration)
        : t.music_queue_summary_source(
            count: queue.length,
            duration: duration,
            source: source,
          );
    return Padding(
      padding: EdgeInsets.fromLTRB(20, widget.sidebar ? 20 : 4, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Semantics(
            header: true,
            child: Text(
              t.music_queue_title,
              style: widget.sidebar
                  ? context.fushiType.titleLargeEmphasized
                  : context.fushiType.headlineSmallEmphasized,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            summary,
            key: const ValueKey<String>('music_queue_summary'),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: context.fushiType.bodySmall.copyWith(
              color: cs.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  /// 播放模式 · 随机 · 清空 同一行。
  Widget _modeRow(BuildContext context, bool editable, int count) {
    final MusicRepeatMode repeat = _engine.repeatMode;
    final bool modes = _engine.canShuffleOrRepeat;
    final (IconData glyph, String label) = switch (repeat) {
      MusicRepeatMode.off => (FushiIcons.repeat, t.music_play_mode_sequential),
      MusicRepeatMode.all => (FushiIcons.repeat, t.music_play_mode_repeat_all),
      MusicRepeatMode.one => (
        FushiIcons.repeatOne,
        t.music_play_mode_repeat_one,
      ),
    };
    final MusicRepeatMode nextRepeat = switch (repeat) {
      MusicRepeatMode.off => MusicRepeatMode.all,
      MusicRepeatMode.all => MusicRepeatMode.one,
      MusicRepeatMode.one => MusicRepeatMode.off,
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Row(
        children: <Widget>[
          FushiPressScale(
            child: FushiIconButtonControl(
              key: const ValueKey<String>('music_queue_repeat'),
              isSelected: repeat != MusicRepeatMode.off,
              tooltip: label,
              onPressed: modes
                  ? () => unawaited(_engine.setRepeatMode(nextRepeat))
                  : null,
              icon: AnimatedSwitcher(
                duration: fushiMotionDuration(context, FushiMotion.short),
                child: FushiIcon(glyph, key: ValueKey<IconData>(glyph)),
              ),
            ),
          ),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.fushiType.labelLarge,
            ),
          ),
          const SizedBox(width: 4),
          FushiPressScale(
            child: FushiIconButtonControl(
              key: const ValueKey<String>('music_queue_shuffle'),
              isSelected: _engine.shuffled,
              tooltip: t.music_play_mode_shuffle,
              onPressed: modes
                  ? () => unawaited(_engine.setShuffle(!_engine.shuffled))
                  : null,
              icon: const FushiIcon(FushiIcons.shuffle),
            ),
          ),
          const Spacer(),
          FushiPressScale(
            child: FushiTextButton(
              key: const ValueKey<String>('music_queue_clear'),
              destructive: true,
              onPressed: editable && count > 1
                  ? () => unawaited(_engine.clearQueue())
                  : null,
              child: Text(t.music_queue_clear),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionLabel(BuildContext context, String text) => SliverToBoxAdapter(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 6),
      child: Text(
        text,
        style: context.fushiType.labelMedium.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    ),
  );

  Widget _upcoming(
    BuildContext context,
    List<MusicPlayItem> queue,
    int i, {
    required bool editable,
    required double width,
  }) {
    final MusicPlayItem item = queue[i];
    // 同一首可能出现多格（电台续播会追加重复曲目）：按它是第几次出现区分 key。
    int occurrence = 0;
    for (int k = 0; k < i; k++) {
      if (queue[k].trackUid == item.trackUid) occurrence++;
    }
    final String id = '${item.trackUid}#$occurrence';
    final bool last = i == queue.length - 1;
    final Widget row = _QueueRow(
      key: ValueKey<String>('music_queue_row_$id'),
      item: item,
      playNext: _engine.isPlayNextAt(i),
      editable: editable,
      dragging: _dragFrom == i,
      lineBefore: _dragFrom != null && _dropBefore == i,
      lineAfter: _dragFrom != null && last && _dropBefore == queue.length,
      onPlay: () => unawaited(_engine.jumpTo(i)),
      onRemove: () => unawaited(_remove(i)),
      handle: editable
          ? _DragHandle(
              index: i,
              rowWidth: width,
              feedback: SizedBox(
                width: width,
                child: _QueueRow(
                  item: item,
                  playNext: _engine.isPlayNextAt(i),
                  editable: false,
                  floating: true,
                  onPlay: () {},
                  onRemove: () {},
                ),
              ),
              onStarted: () => setState(() {
                _dragFrom = i;
                _dropBefore = null;
              }),
              onUpdate: _onDragUpdate,
              onEnd: _endDrag,
            )
          : null,
    );
    if (!editable) return row;
    BuildContext? rowContext;
    final Widget target = DragTarget<int>(
      onWillAcceptWithDetails: (DragTargetDetails<int> d) => true,
      onMove: (DragTargetDetails<int> d) {
        final RenderObject? box = rowContext?.findRenderObject();
        int before = i;
        if (box is RenderBox && box.hasSize) {
          // 浮层（行高约 60）的中线落在这一行的下半截 = 插到它后面。
          final double y = box.globalToLocal(d.offset).dy + 30;
          if (y > box.size.height / 2) before = i + 1;
        }
        if (before != _dropBefore) setState(() => _dropBefore = before);
      },
      onAcceptWithDetails: (DragTargetDetails<int> d) =>
          unawaited(_drop(d.data)),
      builder: (BuildContext c, _, _) {
        rowContext = c;
        return row;
      },
    );
    return Dismissible(
      key: ValueKey<String>('music_queue_dismiss_$id'),
      direction: DismissDirection.endToStart,
      background: const _DismissBackground(),
      onDismissed: (_) => unawaited(_remove(i)),
      child: target,
    );
  }
}

/// 「移出队列」的滑动底色。
class _DismissBackground extends StatelessWidget {
  const _DismissBackground();

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return ColoredBox(
      color: cs.errorContainer,
      child: Padding(
        padding: const EdgeInsetsDirectional.only(end: 24),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: <Widget>[
            FushiIcon(FushiIcons.delete, color: cs.onErrorContainer, size: 20),
            const SizedBox(width: 8),
            Text(
              t.music_queue_remove,
              style: context.fushiType.labelLarge.copyWith(
                color: cs.onErrorContainer,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 右侧拖动手柄：按住即拖（列表里纵向），浮层是这一行的副本。
class _DragHandle extends StatelessWidget {
  const _DragHandle({
    required this.index,
    required this.rowWidth,
    required this.feedback,
    required this.onStarted,
    required this.onUpdate,
    required this.onEnd,
  });

  final int index;
  final double rowWidth;
  final Widget feedback;
  final VoidCallback onStarted;
  final ValueChanged<DragUpdateDetails> onUpdate;
  final VoidCallback onEnd;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Draggable<int>(
      data: index,
      axis: Axis.vertical,
      // 浮层（整行宽 [rowWidth]）右端对齐手柄：按下点相对浮层左上角的偏移。
      dragAnchorStrategy:
          (Draggable<Object> d, BuildContext context, Offset position) {
            final RenderObject? box = context.findRenderObject();
            if (box is! RenderBox) return Offset.zero;
            final Offset local = box.globalToLocal(position);
            return Offset(rowWidth - box.size.width + local.dx, local.dy + 4);
          },
      feedback: FushiEntranceScope(enabled: false, child: feedback),
      childWhenDragging: Opacity(opacity: 0.4, child: _icon(cs)),
      onDragStarted: onStarted,
      onDragUpdate: onUpdate,
      onDragEnd: (_) => onEnd(),
      onDraggableCanceled: (_, _) => onEnd(),
      child: MouseRegion(cursor: SystemMouseCursors.grab, child: _icon(cs)),
    );
  }

  Widget _icon(ColorScheme cs) => Tooltip(
    message: t.music_queue_reorder,
    child: Semantics(
      label: t.music_queue_reorder,
      child: SizedBox.square(
        dimension: 48,
        child: Center(
          child: FushiIcon(FushiIcons.dragHandle, color: cs.onSurfaceVariant),
        ),
      ),
    ),
  );
}

/// 「正在播放」那一行：高亮底色。
class _CurrentRow extends StatelessWidget {
  const _CurrentRow({required this.item});

  final MusicPlayItem item;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey<String>('music_queue_current'),
      margin: const EdgeInsets.symmetric(horizontal: 12),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: cs.secondaryContainer,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: <Widget>[
          MusicCover(
            coverPath: item.coverPath,
            size: 48,
            borderRadius: BorderRadius.circular(12),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _RowText(
              item: item,
              color: cs.onSecondaryContainer,
              emphasized: true,
            ),
          ),
        ],
      ),
    );
  }
}

class _RowText extends StatelessWidget {
  const _RowText({
    required this.item,
    this.color,
    this.emphasized = false,
    this.tag,
  });

  final MusicPlayItem item;
  final Color? color;
  final bool emphasized;
  final Widget? tag;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final String subtitle = <String>[
      if (item.artist case final String a when a.isNotEmpty) a,
      if (item.durationMs case final int ms when ms > 0) _mmss(ms),
    ].join(' · ');
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Flexible(
              child: Text(
                item.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    (emphasized
                            ? context.fushiType.titleSmallEmphasized
                            : context.fushiType.bodyLarge)
                        .copyWith(color: color),
              ),
            ),
            if (tag != null) ...<Widget>[const SizedBox(width: 6), tag!],
          ],
        ),
        if (subtitle.isNotEmpty)
          Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.fushiType.bodySmall.copyWith(
              color: color?.withValues(alpha: 0.8) ?? cs.onSurfaceVariant,
            ),
          ),
      ],
    );
  }
}

/// 「下一首播放」小标签。
class _PlayNextTag extends StatelessWidget {
  const _PlayNextTag();

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey<String>('music_queue_play_next_tag'),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: cs.tertiaryContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        t.music_queue_play_next,
        style: context.fushiType.labelSmall.copyWith(
          color: cs.onTertiaryContainer,
        ),
      ),
    );
  }
}

/// 「接下来」里的一行。桌面：单击选中（Delete 移出）、双击跳播、悬停 / 选中时出现移出按钮；
/// 触屏：点一下跳播（移出靠左滑）。
class _QueueRow extends StatefulWidget {
  const _QueueRow({
    super.key,
    required this.item,
    required this.playNext,
    required this.editable,
    required this.onPlay,
    required this.onRemove,
    this.handle,
    this.dragging = false,
    this.lineBefore = false,
    this.lineAfter = false,
    this.floating = false,
  });

  final MusicPlayItem item;
  final bool playNext;
  final bool editable;
  final VoidCallback onPlay;
  final VoidCallback onRemove;
  final Widget? handle;
  final bool dragging;

  /// 拖动排序的插入线画在这一行上方 / 下方。
  final bool lineBefore;
  final bool lineAfter;

  /// 拖动中的浮层副本。
  final bool floating;

  @override
  State<_QueueRow> createState() => _QueueRowState();
}

class _QueueRowState extends State<_QueueRow> {
  bool _hovered = false;
  bool _focused = false;

  /// 上一次鼠标单击的时刻（双击判定）。不挂 `onDoubleTap`：那会让触屏的单击也等双击
  /// 超时才响应。
  DateTime? _lastMouseTap;

  /// 鼠标：单击选中（Delete 移出）、双击跳播；触屏 / 触控笔：点一下跳播。
  void _onTapUp(BuildContext focusContext, TapUpDetails d) {
    if (d.kind != PointerDeviceKind.mouse) {
      widget.onPlay();
      return;
    }
    final DateTime now = DateTime.now();
    final DateTime? last = _lastMouseTap;
    if (last != null && now.difference(last) <= kDoubleTapTimeout) {
      _lastMouseTap = null;
      widget.onPlay();
      return;
    }
    _lastMouseTap = now;
    Focus.of(focusContext).requestFocus();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.delete ||
        event.logicalKey == LogicalKeyboardKey.backspace) {
      if (!widget.editable) return KeyEventResult.ignored;
      widget.onRemove();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter) {
      widget.onPlay();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool showRemove =
        widget.editable && !widget.floating && (_hovered || _focused);
    final Widget line = Container(
      height: 3,
      margin: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        color: cs.primary,
        borderRadius: BorderRadius.circular(2),
      ),
    );
    final Widget body = AnimatedContainer(
      duration: fushiMotionDuration(context, FushiMotion.short),
      margin: widget.floating
          ? const EdgeInsets.symmetric(horizontal: 12, vertical: 4)
          : EdgeInsets.zero,
      padding: const EdgeInsetsDirectional.fromSTEB(20, 6, 4, 6),
      constraints: const BoxConstraints(minHeight: 60),
      decoration: BoxDecoration(
        color: widget.floating
            ? cs.surfaceContainerHighest
            : (_focused
                  ? cs.onSurface.withValues(alpha: 0.08)
                  : (_hovered
                        ? cs.onSurface.withValues(alpha: 0.04)
                        : Colors.transparent)),
        borderRadius: BorderRadius.circular(widget.floating ? 18 : 0),
        boxShadow: widget.floating
            ? <BoxShadow>[
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.3),
                  blurRadius: 24,
                  offset: const Offset(0, 10),
                ),
              ]
            : null,
      ),
      child: Row(
        children: <Widget>[
          MusicCover(
            coverPath: widget.item.coverPath,
            size: 44,
            borderRadius: BorderRadius.circular(10),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _RowText(
              item: widget.item,
              tag: widget.playNext ? const _PlayNextTag() : null,
            ),
          ),
          AnimatedSwitcher(
            duration: fushiMotionDuration(context, FushiMotion.short),
            child: showRemove
                ? FushiIconButtonControl(
                    key: const ValueKey<String>('music_queue_row_remove'),
                    tooltip: t.music_queue_remove,
                    onPressed: widget.onRemove,
                    icon: const FushiIcon(FushiIcons.close),
                  )
                : const SizedBox.shrink(),
          ),
          ?widget.handle,
          if (widget.handle == null && !widget.floating)
            const SizedBox(width: 12),
        ],
      ),
    );
    if (widget.floating) {
      return Material(type: MaterialType.transparency, child: body);
    }
    return Opacity(
      opacity: widget.dragging ? 0.4 : 1,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (widget.lineBefore) line,
          Focus(
            onKeyEvent: _onKey,
            onFocusChange: (bool f) => setState(() => _focused = f),
            child: Builder(
              builder: (BuildContext focusContext) => MouseRegion(
                onEnter: (_) => setState(() => _hovered = true),
                onExit: (_) => setState(() => _hovered = false),
                child: Semantics(
                  button: true,
                  onTap: widget.onPlay,
                  child: FushiPressScale(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapUp: (TapUpDetails d) => _onTapUp(focusContext, d),
                      child: body,
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (widget.lineAfter) line,
        ],
      ),
    );
  }
}

/// 底部「已移出 … · 撤销」提示（面板内，跟着面板走）。
class _UndoBar extends StatelessWidget {
  const _UndoBar({super.key, required this.title, required this.onUndo});

  final String title;
  final VoidCallback onUndo;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Material(
      key: const ValueKey<String>('music_queue_undo_bar'),
      color: cs.inverseSurface,
      elevation: 3,
      borderRadius: BorderRadius.circular(26),
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(18, 4, 6, 4),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                t.music_queue_removed(title: title),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.fushiType.bodyMedium.copyWith(
                  color: cs.onInverseSurface,
                ),
              ),
            ),
            FushiPressScale(
              child: FushiTextButton(
                key: const ValueKey<String>('music_queue_undo'),
                onPressed: onUndo,
                child: Text(
                  t.undo,
                  style: TextStyle(
                    color: cs.inversePrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
