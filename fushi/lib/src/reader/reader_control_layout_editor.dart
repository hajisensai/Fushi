/// 阅读器按钮布局的拖拽编辑器（设置 → 阅读 → 阅读界面）。泛型骨架
/// `ControlLayoutEditor` 管拖放状态机；这里只给阅读器的舞台几何（顶栏一行 /
/// 底栏一行，各左中右）、图标 / 文案与驳回提示。与视频页编辑器同一套手感。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:fushi/src/controls/control_layout.dart';
import 'package:fushi/src/controls/control_layout_editor.dart';
import 'package:fushi/src/pages/implementations/reader_fushi/reader_panel_kit.dart';
import 'package:fushi/src/reader/reader_control_layout.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi/src/utils/misc/toast_severity.dart';
import 'package:fushi/utils.dart';

export 'package:fushi/src/controls/control_layout_editor.dart'
    show controlLayoutEditorHintStyle;

/// 阅读器按钮图标：与顶栏渲染同一张表（`chrome.part.dart` 的 `_readerControlIcon`
/// 只是在这张表上按运行态换全屏 / 歌词两颗的图标）。
IconData readerControlItemIcon(ReaderControlItem item) {
  switch (item) {
    case ReaderControlItem.back:
      return Icons.arrow_back;
    case ReaderControlItem.modeToggle:
      return Icons.lyrics_outlined;
    case ReaderControlItem.navigation:
      return Icons.format_list_bulleted;
    case ReaderControlItem.gallery:
      return Icons.collections_outlined;
    case ReaderControlItem.statistics:
      return Icons.insights_outlined;
    case ReaderControlItem.studyTimer:
      return Icons.timer_outlined;
    case ReaderControlItem.title:
      return Icons.title;
    case ReaderControlItem.audiobook:
      return Icons.headphones_outlined;
    case ReaderControlItem.fullscreen:
      return Icons.fullscreen_rounded;
    case ReaderControlItem.toolbars:
      return Icons.web_asset_off_outlined;
    case ReaderControlItem.settings:
      return Icons.tune_outlined;
    case ReaderControlItem.audiobookPrev:
      return Icons.skip_previous_outlined;
    case ReaderControlItem.audiobookPlayPause:
      return Icons.play_arrow_outlined;
    case ReaderControlItem.audiobookNext:
      return Icons.skip_next_outlined;
    case ReaderControlItem.audiobookSeekBack:
      return Icons.replay_10_outlined;
    case ReaderControlItem.audiobookSeekForward:
      return Icons.forward_10_outlined;
    case ReaderControlItem.audiobookFollow:
      return Icons.link;
  }
}

String readerControlItemLabel(ReaderControlItem item) {
  switch (item) {
    case ReaderControlItem.back:
      return t.back;
    case ReaderControlItem.modeToggle:
      return t.lyrics_mode;
    case ReaderControlItem.navigation:
      return t.section_navigation;
    case ReaderControlItem.gallery:
      return t.reader_gallery_tooltip;
    case ReaderControlItem.statistics:
      return t.reading_statistics;
    case ReaderControlItem.studyTimer:
      return t.shortcut_action_reader_toggle_study_clock;
    case ReaderControlItem.title:
      return t.reader_control_title;
    case ReaderControlItem.audiobook:
      return t.section_audiobook;
    case ReaderControlItem.fullscreen:
      return t.shortcut_action_global_toggle_fullscreen;
    case ReaderControlItem.toolbars:
      return t.reader_toolbars_hide;
    case ReaderControlItem.settings:
      return t.reader_settings_section;
    case ReaderControlItem.audiobookPrev:
      return t.prev_sentence;
    case ReaderControlItem.audiobookPlayPause:
      return t.reader_control_item_play_pause;
    case ReaderControlItem.audiobookNext:
      return t.next_sentence;
    case ReaderControlItem.audiobookSeekBack:
      return t.reader_control_item_seek_back;
    case ReaderControlItem.audiobookSeekForward:
      return t.reader_control_item_seek_forward;
    case ReaderControlItem.audiobookFollow:
      return t.audiobook_follow_audio;
  }
}

String readerControlSlotLabel(ReaderControlSlot slot) {
  switch (slot) {
    case ReaderControlSlot.topLeft:
      return t.video_control_slot_top_left;
    case ReaderControlSlot.topCenter:
      return t.video_control_slot_top_center;
    case ReaderControlSlot.topRight:
      return t.video_control_slot_top_right;
    case ReaderControlSlot.bottomLeft:
      return t.video_control_slot_bottom_left;
    case ReaderControlSlot.bottomCenter:
      return t.video_control_slot_bottom_center;
    case ReaderControlSlot.bottomRight:
      return t.video_control_slot_bottom_right;
    case ReaderControlSlot.overflow:
      return t.reader_control_slot_overflow;
    case ReaderControlSlot.hidden:
      return t.reader_control_slot_hidden;
  }
}

/// 按钮布局编辑器（2026-10 重做，用户：「按钮排布也优化一下」）：上方是所见即所得
/// 的工具栏预览（按当前工具栏样式画悬浮胶囊或贴边整宽条，随编辑实时变化），下方
/// 是三区编辑——「常驻」（顶部左 / 书名 / 顶部右 / 底部工具栏左中右）、「更多菜单」
/// （⋯）、「隐藏」。每颗按钮是一枚胶囊 chip：
///  * 触屏长按拖、桌面直接拖，落到某区的某颗 chip 上 = 插到它前面，落在区的空白处
///    = 追加到末尾；
///  * 键盘：chip 可聚焦，Enter / 点击弹「移到…」菜单（各区 + 前移 / 后移）。
/// 必需项（返回 / 设置）进隐藏、返回进「更多」、书名进别处一律驳回并提示。
///
/// 写操作全部经 [ControlLayout.moveItem]（模型不变式在那里），改完立即回调
/// [onLayoutChanged]（宿主写偏好并通知开着的书重锚 chrome）。
class ReaderControlLayoutEditor extends StatelessWidget {
  const ReaderControlLayoutEditor({
    super.key,
    required this.layout,
    required this.onLayoutChanged,
    required this.isTouchControls,
    this.floating = true,
    this.compact = false,
    this.defaults,
  });

  final ReaderControlLayout layout;
  final Future<void> Function(ReaderControlLayout layout)? onLayoutChanged;
  final bool isTouchControls;

  /// 预览按悬浮工具栏（默认）还是贴边整宽条画。
  final bool floating;

  /// 预览按手机（窄窗）还是平板 / 桌面画。
  final bool compact;

  /// 「恢复默认」写回的布局；null 不显示该按钮。
  final ReaderControlLayout? defaults;

  static const List<ReaderControlSlot> _bottomSlots = <ReaderControlSlot>[
    ReaderControlSlot.bottomLeft,
    ReaderControlSlot.bottomCenter,
    ReaderControlSlot.bottomRight,
  ];

  void _move(
    BuildContext context,
    ReaderControlItem item,
    ReaderControlSlot target, {
    int? index,
  }) {
    final Future<void> Function(ReaderControlLayout)? changed = onLayoutChanged;
    if (changed == null) return;
    final String? reject = readerControlRejectionMessage(item, target);
    if (reject != null) {
      FushiToast.show(msg: reject, severity: ToastSeverity.warning);
      return;
    }
    final ControlLayout<ReaderControlSlot, ReaderControlItem> next =
        layout.core.moveItem(item, target, index: index);
    if (next == layout.core) return;
    unawaited(changed(ReaderControlLayout.fromCore(next)));
  }

  /// 按钮当前所在区（hidden = 已移除）。
  ReaderControlSlot _slotOf(ReaderControlItem item) => layout.core.slotOf(item);

  List<ReaderControlItem> _itemsIn(ReaderControlSlot slot) {
    if (slot == ReaderControlSlot.hidden) {
      return <ReaderControlItem>[
        for (final ReaderControlItem i in layout.core.removedItems)
          if (i != ReaderControlItem.title) i,
      ];
    }
    return layout
        .itemsIn(slot)
        .where((ReaderControlItem i) => i != ReaderControlItem.title)
        .toList();
  }

  Future<void> _showMoveMenu(
    BuildContext chipContext,
    ReaderControlItem item,
  ) async {
    final RenderObject? box = chipContext.findRenderObject();
    final RenderObject? overlay =
        Overlay.of(chipContext).context.findRenderObject();
    if (box is! RenderBox || overlay is! RenderBox) return;
    final Offset topLeft = box.localToGlobal(Offset.zero, ancestor: overlay);
    final RelativeRect position = RelativeRect.fromRect(
      topLeft & box.size,
      Offset.zero & overlay.size,
    );
    final ReaderControlSlot current = _slotOf(item);
    final List<ReaderControlItem> siblings = _itemsIn(current);
    final int at = siblings.indexOf(item);
    final String? choice = await showMenu<String>(
      context: chipContext,
      position: position,
      items: <PopupMenuEntry<String>>[
        if (current != ReaderControlSlot.hidden && at > 0)
          PopupMenuItem<String>(
            value: 'earlier',
            child: _MenuRow(
              icon: Icons.arrow_upward_rounded,
              label: t.reader_control_move_earlier,
            ),
          ),
        if (current != ReaderControlSlot.hidden &&
            at >= 0 &&
            at < siblings.length - 1)
          PopupMenuItem<String>(
            value: 'later',
            child: _MenuRow(
              icon: Icons.arrow_downward_rounded,
              label: t.reader_control_move_later,
            ),
          ),
        const PopupMenuDivider(),
        for (final ReaderControlSlot slot in <ReaderControlSlot>[
          ReaderControlSlot.topLeft,
          ReaderControlSlot.topRight,
          ..._bottomSlots,
          ReaderControlSlot.overflow,
          ReaderControlSlot.hidden,
        ])
          if (slot != current)
            PopupMenuItem<String>(
              value: slot.storageValue,
              enabled: item.canMoveToSlot(slot),
              child: _MenuRow(
                icon: _zoneIcon(slot),
                label: '${t.reader_control_move_to} · ${_zoneLabel(slot)}',
              ),
            ),
      ],
    );
    if (choice == null || !chipContext.mounted) return;
    if (choice == 'earlier') {
      _move(chipContext, item, current, index: at - 1);
    } else if (choice == 'later') {
      _move(chipContext, item, current, index: at + 1);
    } else {
      for (final ReaderControlSlot s in ReaderControlSlot.values) {
        if (s.storageValue == choice) _move(chipContext, item, s);
      }
    }
  }

  static String _zoneLabel(ReaderControlSlot slot) => switch (slot) {
        ReaderControlSlot.overflow => t.reader_control_slot_overflow,
        ReaderControlSlot.hidden => t.reader_control_zone_hidden,
        _ => readerControlSlotLabel(slot),
      };

  static IconData _zoneIcon(ReaderControlSlot slot) => switch (slot) {
        ReaderControlSlot.topLeft ||
        ReaderControlSlot.topCenter ||
        ReaderControlSlot.topRight =>
          Icons.vertical_align_top_rounded,
        ReaderControlSlot.overflow => Icons.more_horiz_rounded,
        ReaderControlSlot.hidden => Icons.visibility_off_outlined,
        _ => Icons.vertical_align_bottom_rounded,
      };

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool glass = isGlassDesign(context);
    final bool showsTitle = layout.showsTitle;
    Widget zone(ReaderControlSlot slot, {String? label}) => _ZoneRow(
          key: ValueKey<String>('reader-control-edit-slot-${slot.name}'),
          slot: slot,
          label: label ?? _zoneLabel(slot),
          icon: _zoneIcon(slot),
          items: _itemsIn(slot),
          touch: isTouchControls,
          onDrop: (ReaderControlItem item, int? index) =>
              _move(context, item, slot, index: index),
          onChipActivate: _showMoveMenu,
        );
    final List<Widget> sections = <Widget>[
      _ReaderToolbarPreview(
        key: const ValueKey<String>('reader-control-editor-preview'),
        layout: layout,
        floating: floating,
        compact: compact,
      ),
      Text(
        t.reader_control_editor_drag_hint,
        style: controlLayoutEditorHintStyle(context),
      ),
      _ZoneCard(
        title: t.reader_control_zone_pinned,
        hint: t.reader_control_zone_pinned_hint,
        tone: ReaderPanelCardTone.emphasis,
        children: <Widget>[
          zone(ReaderControlSlot.topLeft),
          _TitleSwitchRow(
            key: const ValueKey<String>('reader-control-edit-slot-topCenter'),
            value: showsTitle,
            onChanged: onLayoutChanged == null
                ? null
                : (bool v) => _move(
                      context,
                      ReaderControlItem.title,
                      v
                          ? ReaderControlSlot.topCenter
                          : ReaderControlSlot.hidden,
                    ),
          ),
          zone(ReaderControlSlot.topRight),
          ReaderPanelSectionLabel(
            t.reader_control_zone_bottom_toolbar,
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
          ),
          for (final ReaderControlSlot slot in _bottomSlots) zone(slot),
        ],
      ),
      _ZoneCard(
        title: t.reader_control_slot_overflow,
        hint: t.reader_control_zone_overflow_hint,
        tone: ReaderPanelCardTone.neutral,
        children: <Widget>[
          zone(ReaderControlSlot.overflow, label: ''),
        ],
      ),
      _ZoneCard(
        title: t.reader_control_zone_hidden,
        hint: t.reader_control_zone_hidden_hint,
        tone: ReaderPanelCardTone.neutral,
        children: <Widget>[
          zone(ReaderControlSlot.hidden, label: ''),
        ],
      ),
      if (defaults != null && onLayoutChanged != null)
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: FushiTextButton.icon(
            key: const ValueKey<String>('reader-control-restore-defaults'),
            onPressed: () => unawaited(onLayoutChanged!(defaults!)),
            icon: const FushiIcon(Icons.restart_alt_rounded),
            label: Text(t.reader_control_restore_defaults),
          ),
        ),
    ];
    return DefaultTextStyle.merge(
      style: TextStyle(
        color:
            glass ? appleColorsOf(context).label : theme.colorScheme.onSurface,
      ),
      child: FushiEntranceScope(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (int i = 0; i < sections.length; i++) ...<Widget>[
              if (i > 0) const SizedBox(height: 12),
              readerPanelStagger(i, sections[i]),
            ],
          ],
        ),
      ),
    );
  }
}

/// 驳回提示（null = 允许）。纯函数，编辑器与测试共用。
String? readerControlRejectionMessage(
  ReaderControlItem item,
  ReaderControlSlot target,
) {
  if (item.pinnedRequired && target == ReaderControlSlot.hidden) {
    return t.reader_control_reject_required;
  }
  if (item == ReaderControlItem.title ||
      target == ReaderControlSlot.topCenter) {
    if (!item.canMoveToSlot(target)) return t.reader_control_reject_title;
  }
  if (!item.canMoveToSlot(target)) return t.video_control_reject_unavailable;
  return null;
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          FushiIcon(icon, size: 20),
          const SizedBox(width: 12),
          Flexible(child: Text(label)),
        ],
      );
}

/// 一个区（标题 + 说明 + 若干行）。M3E 常驻区是 primaryContainer 饱和色块。
class _ZoneCard extends StatelessWidget {
  const _ZoneCard({
    required this.title,
    required this.hint,
    required this.tone,
    required this.children,
  });

  final String title;
  final String hint;
  final ReaderPanelCardTone tone;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color fg = ReaderPanelCard.foregroundFor(context, tone);
    return ReaderPanelCard(
      tone: tone,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            title,
            style: theme.textTheme.titleMedium?.copyWith(
              color: fg,
              fontWeight: FontWeight.w800,
            ),
          ),
          Text(
            hint,
            style: theme.textTheme.bodySmall?.copyWith(
              color: fg.withValues(alpha: 0.72),
            ),
          ),
          const SizedBox(height: 8),
          ...children,
        ],
      ),
    );
  }
}

/// 书名开关（顶栏中间只放书名，书名只能开 / 关）。
class _TitleSwitchRow extends StatelessWidget {
  const _TitleSwitchRow({super.key, required this.value, this.onChanged});

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: <Widget>[
          const FushiIcon(Icons.title_rounded, size: 20),
          const SizedBox(width: 10),
          Expanded(child: Text(t.reader_control_show_title)),
          FushiSwitch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

/// 一个槽位的放置区：标签 + 胶囊 chip 流。落在 chip 上 = 插到它前面；落在空白 =
/// 追加到末尾。拖动悬停时区底高亮（动画）。
class _ZoneRow extends StatelessWidget {
  const _ZoneRow({
    super.key,
    required this.slot,
    required this.label,
    required this.icon,
    required this.items,
    required this.touch,
    required this.onDrop,
    required this.onChipActivate,
  });

  final ReaderControlSlot slot;
  final String label;
  final IconData icon;
  final List<ReaderControlItem> items;
  final bool touch;
  final void Function(ReaderControlItem item, int? index) onDrop;
  final Future<void> Function(BuildContext chipContext, ReaderControlItem item)
      onChipActivate;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool glass = isGlassDesign(context);
    final Color accent =
        glass ? appleColorsOf(context).accent : theme.colorScheme.primary;
    return DragTarget<ReaderControlItem>(
      onWillAcceptWithDetails: (DragTargetDetails<ReaderControlItem> d) =>
          d.data.canMoveToSlot(slot),
      onAcceptWithDetails: (DragTargetDetails<ReaderControlItem> d) =>
          onDrop(d.data, null),
      builder: (
        BuildContext context,
        List<ReaderControlItem?> candidates,
        List<dynamic> rejected,
      ) {
        final bool hovering = candidates.isNotEmpty;
        return AnimatedContainer(
          duration: fushiMotionDuration(context, FushiMotion.short),
          curve: FushiMotion.standard,
          margin: const EdgeInsets.symmetric(vertical: 3),
          padding: const EdgeInsets.all(6),
          decoration: ShapeDecoration(
            color: hovering
                ? accent.withValues(alpha: 0.14)
                : accent.withValues(alpha: 0),
            shape: RoundedRectangleBorder(
              borderRadius: const BorderRadius.all(Radius.circular(16)),
              side: BorderSide(
                color: rejected.isNotEmpty
                    ? theme.colorScheme.error
                    : hovering
                        ? accent
                        : accent.withValues(alpha: 0),
                width: 1.5,
              ),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (label.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(left: 2, bottom: 4),
                  child: Row(
                    children: <Widget>[
                      FushiIcon(icon, size: 16),
                      const SizedBox(width: 6),
                      Text(
                        label,
                        style: theme.textTheme.labelMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              AnimatedSize(
                duration: fushiMotionDuration(context, FushiMotion.short),
                curve: FushiMotion.standard,
                alignment: Alignment.topLeft,
                child: items.isEmpty
                    ? SizedBox(
                        height: 40,
                        child: Center(
                          child: FushiIcon(
                            Icons.add_rounded,
                            color: accent.withValues(alpha: 0.5),
                          ),
                        ),
                      )
                    : Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: <Widget>[
                          for (int i = 0; i < items.length; i++)
                            DragTarget<ReaderControlItem>(
                              onWillAcceptWithDetails:
                                  (DragTargetDetails<ReaderControlItem> d) =>
                                      d.data != items[i] &&
                                      d.data.canMoveToSlot(slot),
                              onAcceptWithDetails:
                                  (DragTargetDetails<ReaderControlItem> d) =>
                                      onDrop(d.data, i),
                              builder: (
                                BuildContext context,
                                List<ReaderControlItem?> c,
                                List<dynamic> r,
                              ) =>
                                  _DraggableChip(
                                key: ValueKey<String>(
                                  'reader-control-chip-${items[i].storageValue}',
                                ),
                                item: items[i],
                                touch: touch,
                                insertMarker: c.isNotEmpty,
                                onActivate: onChipActivate,
                              ),
                            ),
                        ],
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 一颗可拖动、可聚焦（Enter 弹菜单）的按钮胶囊。
class _DraggableChip extends StatelessWidget {
  const _DraggableChip({
    super.key,
    required this.item,
    required this.touch,
    required this.insertMarker,
    required this.onActivate,
  });

  final ReaderControlItem item;
  final bool touch;
  final bool insertMarker;
  final Future<void> Function(BuildContext chipContext, ReaderControlItem item)
      onActivate;

  @override
  Widget build(BuildContext context) {
    final Widget chip = _ChipFace(item: item, insertMarker: insertMarker);
    final Widget feedback = Material(
      type: MaterialType.transparency,
      child: Transform.scale(
        scale: 1.06,
        child: _ChipFace(item: item, lifted: true),
      ),
    );
    final Widget ghost = Opacity(opacity: 0.35, child: chip);
    final Widget draggable = touch
        ? LongPressDraggable<ReaderControlItem>(
            data: item,
            feedback: feedback,
            childWhenDragging: ghost,
            child: chip,
          )
        : Draggable<ReaderControlItem>(
            data: item,
            feedback: feedback,
            childWhenDragging: ghost,
            child: chip,
          );
    return Builder(
      builder: (BuildContext chipContext) => FushiPressScale(
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: () => unawaited(onActivate(chipContext, item)),
            child: Semantics(
              button: true,
              label: readerControlItemLabel(item),
              child: draggable,
            ),
          ),
        ),
      ),
    );
  }
}

class _ChipFace extends StatelessWidget {
  const _ChipFace({
    required this.item,
    this.insertMarker = false,
    this.lifted = false,
  });

  final ReaderControlItem item;
  final bool insertMarker;
  final bool lifted;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool glass = isGlassDesign(context);
    final ColorScheme cs = theme.colorScheme;
    final Color bg = glass
        ? appleColorsOf(context).tertiaryGroupedBackground
        : cs.secondaryContainer;
    final Color fg =
        glass ? appleColorsOf(context).label : cs.onSecondaryContainer;
    final Color marker = glass ? appleColorsOf(context).accent : cs.primary;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        AnimatedContainer(
          duration: fushiMotionDuration(context, FushiMotion.short),
          width: insertMarker ? 3 : 0,
          height: 28,
          margin: EdgeInsets.only(right: insertMarker ? 4 : 0),
          decoration: ShapeDecoration(
            color: marker,
            shape: const StadiumBorder(),
          ),
        ),
        Container(
          constraints: const BoxConstraints(minHeight: 36),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: ShapeDecoration(
            color: bg,
            shape: StadiumBorder(
              side: item.pinnedRequired
                  ? BorderSide(color: marker.withValues(alpha: 0.6))
                  : BorderSide.none,
            ),
            shadows: lifted
                ? <BoxShadow>[
                    BoxShadow(
                      color: cs.shadow.withValues(alpha: 0.25),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ]
                : const <BoxShadow>[],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              FushiIcon(readerControlItemIcon(item), size: 18, color: fg),
              const SizedBox(width: 6),
              Text(
                readerControlItemLabel(item),
                style: theme.textTheme.labelLarge?.copyWith(color: fg),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 所见即所得预览：一张缩略书页，按工具栏样式画顶部 / 底部 chrome（按钮只读）。
class _ReaderToolbarPreview extends StatelessWidget {
  const _ReaderToolbarPreview({
    super.key,
    required this.layout,
    required this.floating,
    required this.compact,
  });

  final ReaderControlLayout layout;
  final bool floating;
  final bool compact;

  FushiToolbarItem _item(ReaderControlItem i) => FushiToolbarItem(
        icon: readerControlItemIcon(i),
        label: readerControlItemLabel(i),
        onPressed: null,
      );

  List<FushiToolbarItem> _items(ReaderControlSlot slot) => <FushiToolbarItem>[
        for (final ReaderControlItem i in layout.itemsIn(slot))
          if (i != ReaderControlItem.title) _item(i),
      ];

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool glass = isGlassDesign(context);
    final List<FushiToolbarItem> overflow = _items(ReaderControlSlot.overflow);
    final List<List<FushiToolbarItem>> bottom = <List<FushiToolbarItem>>[
      _items(ReaderControlSlot.bottomLeft),
      _items(ReaderControlSlot.bottomCenter),
      _items(ReaderControlSlot.bottomRight),
    ];
    final bool hasBottom =
        bottom.any((List<FushiToolbarItem> g) => g.isNotEmpty);
    final String title = layout.showsTitle ? t.reader_control_title : '';
    final Widget top = floating
        ? FushiFloatingTopBar(
            leading: _items(ReaderControlSlot.topLeft),
            title: title,
            actions: <List<FushiToolbarItem>>[
              _items(ReaderControlSlot.topRight),
            ],
            overflow: overflow,
          )
        : _DockedPreviewBar(
            leading: _items(ReaderControlSlot.topLeft),
            title: title,
            trailing: <FushiToolbarItem>[
              ..._items(ReaderControlSlot.topRight),
              if (overflow.isNotEmpty)
                FushiToolbarItem(
                  icon: Icons.more_vert,
                  label: t.reader_control_slot_overflow,
                  onPressed: null,
                ),
            ],
          );
    final Widget? bottomBar = !hasBottom
        ? null
        : floating
            ? FushiFloatingToolbar(groups: bottom, showLabels: compact)
            : _DockedPreviewBar(
                leading: bottom[0],
                center: bottom[1],
                trailing: bottom[2],
              );
    final Color paper = glass
        ? appleColorsOf(context).secondaryGroupedBackground
        : theme.colorScheme.surfaceContainer;
    final Widget page = ClipRRect(
      borderRadius: const BorderRadius.all(Radius.circular(20)),
      child: ColoredBox(
        color: paper,
        child: Padding(
          padding: EdgeInsets.all(floating ? 8 : 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              top,
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 18, vertical: 18),
                child: ControlStageTextLines(),
              ),
              if (bottomBar != null)
                floating ? Center(child: bottomBar) : bottomBar,
            ],
          ),
        ),
      ),
    );
    // 预览按真实尺寸排版（手机 420 / 平板桌面 760），放不下时整体等比缩小。
    final double design = compact ? 420 : 760;
    return IgnorePointer(
      child: ExcludeFocus(
        child: AnimatedSize(
          duration: fushiMotionDuration(context, FushiMotion.medium),
          curve: FushiMotion.standard,
          alignment: Alignment.topCenter,
          child: Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: SizedBox(
                width: design,
                child: AnimatedSwitcher(
                  duration: fushiMotionDuration(context, FushiMotion.short),
                  child: KeyedSubtree(
                    key: ValueKey<int>(layout.hashCode),
                    child: page,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 贴边样式预览条：整宽实体条，左 / 中 / 右三组图标。
class _DockedPreviewBar extends StatelessWidget {
  const _DockedPreviewBar({
    this.leading = const <FushiToolbarItem>[],
    this.center = const <FushiToolbarItem>[],
    this.trailing = const <FushiToolbarItem>[],
    this.title = '',
  });

  final List<FushiToolbarItem> leading;
  final List<FushiToolbarItem> center;
  final List<FushiToolbarItem> trailing;
  final String title;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color fg = isGlassDesign(context)
        ? appleColorsOf(context).label
        : theme.colorScheme.onSurfaceVariant;
    Widget icons(List<FushiToolbarItem> items) => Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (final FushiToolbarItem i in items)
              Padding(
                padding: const EdgeInsets.all(10),
                child: FushiIcon(i.icon, color: fg, size: 22),
              ),
          ],
        );
    return ColoredBox(
      color: theme.colorScheme.surfaceContainer,
      child: SizedBox(
        height: 48,
        child: Row(
          children: <Widget>[
            icons(leading),
            Expanded(
              child: center.isNotEmpty
                  ? Center(child: icons(center))
                  : Text(
                      title,
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(color: fg),
                    ),
            ),
            icons(trailing),
          ],
        ),
      ),
    );
  }
}

/// 设置页里的完整编辑器：顶部「手机 / 平板与桌面」目标切换（默认按当前窗口），
/// 分别读写两份布局；下面是 [ReaderControlLayoutEditor]。
class ReaderControlLayoutTargetEditor extends StatefulWidget {
  const ReaderControlLayoutTargetEditor({
    super.key,
    required this.read,
    required this.write,
    required this.floating,
    required this.isTouchControls,
  });

  /// 读某个目标（compact = 手机）当前的布局。
  final ReaderControlLayout Function(bool compact) read;

  /// 写某个目标的布局（宿主写偏好 + 通知开着的书）。
  final Future<void> Function(bool compact, ReaderControlLayout layout) write;
  final bool floating;
  final bool isTouchControls;

  @override
  State<ReaderControlLayoutTargetEditor> createState() =>
      _ReaderControlLayoutTargetEditorState();
}

class _ReaderControlLayoutTargetEditorState
    extends State<ReaderControlLayoutTargetEditor> {
  bool? _compact;

  @override
  Widget build(BuildContext context) {
    final bool compact = _compact ??=
        MediaQuery.sizeOf(context).width < kReaderControlCompactWidth;
    final ReaderControlLayout layout = widget.read(compact);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        ReaderPanelTabs<bool>(
          padding: const EdgeInsets.only(bottom: 12),
          tabs: <ReaderPanelTab<bool>>[
            ReaderPanelTab<bool>(
              value: true,
              label: t.reader_control_layout_target_compact,
              icon: Icons.smartphone_rounded,
              key: const ValueKey<String>('reader-control-target-compact'),
            ),
            ReaderPanelTab<bool>(
              value: false,
              label: t.reader_control_layout_target_wide,
              icon: Icons.laptop_rounded,
              key: const ValueKey<String>('reader-control-target-wide'),
            ),
          ],
          selected: compact,
          onChanged: (bool v) => setState(() => _compact = v),
        ),
        AnimatedSwitcher(
          duration: fushiMotionDuration(context, FushiMotion.medium),
          switchInCurve: FushiMotion.enter,
          switchOutCurve: FushiMotion.exit,
          child: ReaderControlLayoutEditor(
            key: ValueKey<bool>(compact),
            layout: layout,
            compact: compact,
            floating: widget.floating,
            isTouchControls: widget.isTouchControls,
            defaults: compact
                ? ReaderControlLayout.compactDefaults
                : ReaderControlLayout.defaults,
            onLayoutChanged: (ReaderControlLayout next) async {
              await widget.write(compact, next);
              if (mounted) setState(() {});
            },
          ),
        ),
      ],
    );
  }
}
