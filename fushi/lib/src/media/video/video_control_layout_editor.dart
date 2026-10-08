import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/controls/control_layout.dart';
import 'package:fushi/src/controls/control_layout_editor.dart';
import 'package:fushi/src/media/video/video_control_customization.dart';
import 'package:fushi/src/media/video/video_control_item_presentation.dart';
import 'package:fushi/src/media/video/video_custom_action_bindings.dart';
import 'package:fushi/src/media/video/video_custom_action_picker.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/utils.dart';

/// 控制条 9 槽位拖拽编辑器（TODO-274/312 phase 2）。从旧
/// `VideoQuickSettingsSheet._buildControlDragEditor` 系列方法原样抽出为独立控件
/// （阶段 B：面板改 schema 投影，本编辑器以 `SettingsCustomItem` 入 schema、仅播放
/// 中可见）；「重置布局」行改由并列的 schema action 项承载，经 [layout] +
/// didUpdateWidget 同步回本编辑器。
///
/// 拖放状态机 / 调色板 / 隐藏托盘 / 驳回提示已抽成泛型 [ControlLayoutEditor]
/// （`src/controls/`），本控件只保留视频域知识：9 槽舞台几何、图标 / 标签 / 槽位名、
/// volume / 必需项的驳回文案，以及「快捷键 N」chip 的点击改绑入口。
class VideoControlLayoutEditor extends StatefulWidget {
  const VideoControlLayoutEditor({
    required this.layout,
    required this.onLayoutChanged,
    required this.isTouchControls,
    this.customActionBindings = VideoCustomActionBindings.empty,
    this.onCustomActionBindingsChanged,
    super.key,
  });

  /// 页面当前生效布局（外部重置/持久化后经 rebuild 传入，didUpdateWidget 同步）。
  final VideoControlLayout layout;

  /// 槽位/显隐变化后回调：持久化 v2 布局 + 实时生效（调用方负责）。
  final Future<void> Function(VideoControlLayout layout)? onLayoutChanged;

  /// 触屏控件（无右键菜单兜底）：禁止把「设置」按钮拖入 hidden 移除（TODO-554）。
  final bool isTouchControls;

  /// 自定义「快捷键 1..4」按钮当前绑的动作（决定 chip 的图标与名字）。
  final VideoCustomActionBindings customActionBindings;

  /// 改绑回调：点「快捷键 N」chip 选动作后落盘 + 实时生效（调用方负责）。
  /// null = 不提供改绑入口（chip 仍可拖动，只是点不出选择器）。
  final Future<void> Function(VideoCustomActionBindings bindings)?
      onCustomActionBindingsChanged;

  @override
  State<VideoControlLayoutEditor> createState() =>
      _VideoControlLayoutEditorState();
}

class _VideoControlLayoutEditorState extends State<VideoControlLayoutEditor> {
  /// 自定义「快捷键」按钮绑定的本地镜像：本地先改、UI 立刻反映，同时把新值交给外部
  /// 落盘（外部回传经 didUpdateWidget 同步回来）。布局本身的镜像在泛型编辑器里。
  late VideoCustomActionBindings _customActionBindings =
      widget.customActionBindings;

  @override
  void didUpdateWidget(VideoControlLayoutEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.customActionBindings != widget.customActionBindings) {
      _customActionBindings = widget.customActionBindings;
    }
  }

  @override
  Widget build(BuildContext context) {
    final Future<void> Function(VideoControlLayout layout)? onLayoutChanged =
        widget.onLayoutChanged;
    return ControlLayoutEditor<VideoControlSlot, VideoControlItem>(
      layout: widget.layout.core,
      onLayoutChanged: onLayoutChanged == null
          ? null
          : (ControlLayout<VideoControlSlot, VideoControlItem> next) =>
              unawaited(onLayoutChanged(VideoControlLayout.fromCore(next))),
      isTouchControls: widget.isTouchControls,
      paletteItems: VideoControlItem.customizableItems,
      paletteTitle: t.video_control_palette_title,
      stageBuilder: _buildControlStagePreview,
      iconOf: (VideoControlItem item) =>
          videoControlItemIcon(item, bindings: _customActionBindings),
      labelOf: (VideoControlItem item) => videoControlItemLabel(
        item,
        context,
        bindings: _customActionBindings,
      ),
      slotLabelOf: _controlSlotLabel,
      rejectionMessageOf: _controlRejectionMessage,
      dragCanceledMessageOf: _controlDragCanceledMessage,
      canRenderChip: (VideoControlItem item) => item.isChipRenderable,
      wrapChip: _wrapCustomActionChip,
      slotOrder: const <VideoControlSlot>[
        VideoControlSlot.topLeft,
        VideoControlSlot.topCenter,
        VideoControlSlot.topRight,
        VideoControlSlot.screenLeft,
        VideoControlSlot.screenRight,
        VideoControlSlot.bottomLeft,
        VideoControlSlot.bottomCenter,
        VideoControlSlot.bottomRight,
        VideoControlSlot.hidden,
      ],
      keyPrefix: 'video-control',
    );
  }

  Widget _buildControlStagePreview(
    BuildContext context,
    ControlSlotRegionBuilder<VideoControlSlot> buildSlotRegion,
  ) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final FushiAppleColors apple = appleColorsOf(context);
    // 舞台 = 播放器缩略画面。模拟画面底：MD3 用 surfaceContainerHigh→Highest
    // 渐变；Apple 用分组底的两级系统灰。顶栏 / 屏幕两侧竖条 / 底栏都按真实位置
    // 浮在画面上（BUG-2448：三行堆叠、行高随内容，槽位两两不重叠；舞台只保留
    // 16:9 的**最小**高度维持方位感）。
    final Gradient frame = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: isGlassDesign(context)
          ? <Color>[
              apple.tertiaryGroupedBackground,
              apple.secondaryGroupedBackground,
            ]
          : <Color>[cs.surfaceContainerHigh, cs.surfaceContainerHighest],
    );
    return ControlStagePanel(
      key: const ValueKey<String>('video-control-editor-preview'),
      heightRatio: 9 / 16,
      minHeight: 260,
      maxHeight: 420,
      background: frame,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _buildStageRow(
            buildSlotRegion,
            left: VideoControlSlot.topLeft,
            center: VideoControlSlot.topCenter,
            right: VideoControlSlot.topRight,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                if (constraints.maxWidth < ControlStageBar.stackedBelowWidth) {
                  return _buildCompactSlotGrid(
                    buildSlotRegion,
                    <VideoControlSlot>[
                      VideoControlSlot.screenLeft,
                      VideoControlSlot.screenRight,
                    ],
                  );
                }
                return Row(
                  children: <Widget>[
                    ControlStageRail(
                      child: buildSlotRegion(
                        VideoControlSlot.screenLeft,
                        growToContent: true,
                        direction: Axis.vertical,
                      ),
                    ),
                    const Expanded(child: _MockVideoCenter()),
                    ControlStageRail(
                      child: buildSlotRegion(
                        VideoControlSlot.screenRight,
                        growToContent: true,
                        direction: Axis.vertical,
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          _buildStageRow(
            buildSlotRegion,
            left: VideoControlSlot.bottomLeft,
            center: VideoControlSlot.bottomCenter,
            right: VideoControlSlot.bottomRight,
          ),
        ],
      ),
    );
  }

  /// 舞台一条栏：左区靠左、中区居中、右区靠右（[center] 为 null 时中间留空）。
  Widget _buildStageRow(
    ControlSlotRegionBuilder<VideoControlSlot> buildSlotRegion, {
    required VideoControlSlot left,
    required VideoControlSlot? center,
    required VideoControlSlot right,
  }) {
    return ControlStageBar(
      start: buildSlotRegion(left, growToContent: true),
      center: center == null
          ? null
          : buildSlotRegion(
              center,
              growToContent: true,
              alignment: WrapAlignment.center,
            ),
      end: buildSlotRegion(
        right,
        growToContent: true,
        alignment: WrapAlignment.end,
      ),
    );
  }

  /// 窄窗下屏幕两侧竖条放不下：改成并排的两条横向小栏（左栏靠左、右栏靠右）。
  Widget _buildCompactSlotGrid(
    ControlSlotRegionBuilder<VideoControlSlot> buildSlotRegion,
    List<VideoControlSlot> slots,
  ) {
    return Row(
      children: <Widget>[
        for (int i = 0; i < slots.length; i++) ...<Widget>[
          if (i > 0) const SizedBox(width: 6),
          Expanded(
            child: Align(
              alignment: i == 0
                  ? AlignmentDirectional.centerStart
                  : AlignmentDirectional.centerEnd,
              heightFactor: 1,
              child: ControlStageRail(
                child: buildSlotRegion(
                  slots[i],
                  growToContent: true,
                  alignment: i == 0 ? WrapAlignment.start : WrapAlignment.end,
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// 「快捷键 N」槽位：点一下选它执行哪个动作（拖动仍然照常改位置——Draggable 用的是
  /// 即时拖拽识别器，与 onTap 在手势竞技场里按「有没有位移」自然分流，不互相吃事件）。
  /// 这是本功能唯一的配置入口：按钮就在编辑器里，点它配、拖它摆，不用去别的页面找。
  Widget _wrapCustomActionChip(
    BuildContext context,
    VideoControlItem item,
    Widget chip,
  ) {
    if (!item.isCustomAction || widget.onCustomActionBindingsChanged == null) {
      return chip;
    }
    return GestureDetector(
      onTap: () => unawaited(_pickCustomAction(item)),
      child: chip,
    );
  }

  /// 点「快捷键 N」chip：选它执行哪个动作。选完立即落盘 + 生效，没有「保存」步骤。
  ///
  /// 弹窗本体走共享的 [showVideoCustomActionPicker]——播放器控制条上直接点空按钮走的
  /// 是同一个入口，两处列表/顺序/选中态必然一致。
  Future<void> _pickCustomAction(VideoControlItem item) async {
    final int? slotIndex = item.customActionSlotIndex;
    final Future<void> Function(VideoCustomActionBindings)? onChanged =
        widget.onCustomActionBindingsChanged;
    if (slotIndex == null || onChanged == null) return;
    final ShortcutAction? current = _customActionBindings.actionAt(slotIndex);
    final VideoCustomActionPick? pick = await showVideoCustomActionPicker(
      context: context,
      slotNumber: slotIndex + 1,
      current: current,
    );
    // null = 用户点外部 / 返回键取消（区别于显式选了「不绑定」，那是
    // `VideoCustomActionPick(null)`）——取消必须保持原绑定不动。
    if (pick == null || !mounted) return;
    final VideoCustomActionBindings next =
        _customActionBindings.withAction(slotIndex, pick.action);
    if (next == _customActionBindings) return;
    setState(() => _customActionBindings = next);
    await onChanged(next);
  }

  /// 拖到任何目标外松手：只有 volume 需要解释（它被限制在底栏，拖去别处会被所有
  /// 槽位拒收，松手时给一句为什么）。
  String? _controlDragCanceledMessage(VideoControlItem item) =>
      item == VideoControlItem.volume
          ? t.video_control_reject_volume_bottom
          : null;

  String? _controlRejectionMessage(
    VideoControlItem item,
    VideoControlSlot target,
  ) {
    if (item == VideoControlItem.volume && !item.canMoveToSlot(target)) {
      return t.video_control_reject_volume_bottom;
    }
    if ((item.pinnedRequired ||
            (widget.isTouchControls && item.pinnedOnTouch)) &&
        target == VideoControlSlot.hidden) {
      return t.video_control_reject_required;
    }
    if (!item.canMoveToSlot(
      target,
      isTouchControls: widget.isTouchControls,
    )) {
      return t.video_control_reject_unavailable;
    }
    return null;
  }

  String _controlSlotLabel(VideoControlSlot slot) {
    switch (slot) {
      case VideoControlSlot.topLeft:
        return t.video_control_slot_top_left;
      case VideoControlSlot.topRight:
        return t.video_control_slot_top_right;
      case VideoControlSlot.bottomLeft:
        return t.video_control_slot_bottom_left;
      case VideoControlSlot.bottomCenter:
        return t.video_control_slot_bottom_center;
      case VideoControlSlot.bottomRight:
        return t.video_control_slot_bottom_right;
      case VideoControlSlot.screenLeft:
        return t.video_control_slot_screen_left;
      case VideoControlSlot.screenRight:
        return t.video_control_slot_screen_right;
      case VideoControlSlot.hidden:
        return t.video_control_slot_hidden;
      case VideoControlSlot.topCenter:
        return t.video_control_slot_top_center;
    }
  }
}

/// 模拟画面中央：一颗播放符号 + 两行字幕线，让舞台读出「这是播放器」。
class _MockVideoCenter extends StatelessWidget {
  const _MockVideoCenter();

  @override
  Widget build(BuildContext context) {
    final ControlEditorStyle style = ControlEditorStyle.of(context);
    return ExcludeSemantics(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            FushiIcon(
              Icons.play_circle_outline,
              size: 40,
              color: style.secondaryLabel.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 14),
            const ControlStageTextLines(
              widthFactors: <double>[0.62, 0.44],
              centered: true,
            ),
          ],
        ),
      ),
    );
  }
}
