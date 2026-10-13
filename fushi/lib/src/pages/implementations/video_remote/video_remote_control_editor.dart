import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart' show ProviderScope;
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/controls/control_layout.dart';
import 'package:fushi/src/controls/control_layout_editor.dart';
import 'package:fushi/src/media/video/video_remote_control_layout.dart';
import 'package:fushi/src/models/app_model.dart' show appProvider;
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/video_remote/video_remote_models.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart'
    show adaptiveModalSheet;
import 'package:fushi/src/utils/components/fushi_material_components.dart'
    show FushiModalSheetFrame;
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:material_ui/material_ui.dart';

/// 遥控器控制卡按钮布局编辑器：复用通用拖拽编辑器 [ControlLayoutEditor]，舞台是
/// 控制卡的缩略图（主控制组一行、更多按钮一行），托盘里是全部按钮，移出区收
/// 不要的按钮。播放 / 暂停是必需项，拖去移出区被驳回。
class VideoRemoteControlEditor extends StatelessWidget {
  const VideoRemoteControlEditor({
    super.key,
    required this.layout,
    required this.onLayoutChanged,
    this.isTouchControls = true,
  });

  final VideoRemoteControlLayout layout;
  final ValueChanged<VideoRemoteControlLayout>? onLayoutChanged;
  final bool isTouchControls;

  @override
  Widget build(BuildContext context) {
    final ValueChanged<VideoRemoteControlLayout>? changed = onLayoutChanged;
    return ControlLayoutEditor<VideoRemoteControlSlot, VideoRemoteControlItem>(
      layout: layout.core,
      onLayoutChanged: changed == null
          ? null
          : (
              ControlLayout<VideoRemoteControlSlot, VideoRemoteControlItem>
              next,
            ) => changed(VideoRemoteControlLayout.fromCore(next)),
      isTouchControls: isTouchControls,
      paletteItems: VideoRemoteControlItem.values,
      paletteTitle: t.video_control_palette_title,
      stageBuilder: _buildStage,
      iconOf: (VideoRemoteControlItem item) => videoRemoteControlIcon(item),
      labelOf: (VideoRemoteControlItem item) => videoRemoteControlLabel(item),
      slotLabelOf: videoRemoteControlSlotLabel,
      rejectionMessageOf: videoRemoteControlRejectionMessage,
      slotOrder: const <VideoRemoteControlSlot>[
        VideoRemoteControlSlot.primary,
        VideoRemoteControlSlot.secondary,
        VideoRemoteControlSlot.hidden,
      ],
      keyPrefix: 'video-remote-control',
    );
  }

  Widget _buildStage(
    BuildContext context,
    ControlSlotRegionBuilder<VideoRemoteControlSlot> buildSlotRegion,
  ) {
    final ThemeData theme = Theme.of(context);
    final ControlEditorStyle style = ControlEditorStyle.of(context);
    Widget region(VideoRemoteControlSlot slot) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          videoRemoteControlSlotLabel(slot),
          style: theme.textTheme.labelMedium?.copyWith(
            color: style.secondaryLabel,
          ),
        ),
        const SizedBox(height: 6),
        buildSlotRegion(
          slot,
          growToContent: true,
          alignment: WrapAlignment.center,
        ),
      ],
    );
    return ControlStagePanel(
      key: const ValueKey<String>('video-remote-control-editor-preview'),
      heightRatio: 0.5,
      minHeight: 200,
      maxHeight: 320,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.end,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            region(VideoRemoteControlSlot.primary),
            const SizedBox(height: 12),
            region(VideoRemoteControlSlot.secondary),
          ],
        ),
      ),
    );
  }
}

/// 槽位名（编辑器舞台 / 驳回提示）。
String videoRemoteControlSlotLabel(VideoRemoteControlSlot slot) =>
    switch (slot) {
      VideoRemoteControlSlot.primary => t.video_remote_control_slot_primary,
      VideoRemoteControlSlot.secondary => t.video_remote_control_slot_secondary,
      VideoRemoteControlSlot.hidden => t.video_remote_control_slot_hidden,
    };

/// 拖放被拒的原因；能放返回 null。
String? videoRemoteControlRejectionMessage(
  VideoRemoteControlItem item,
  VideoRemoteControlSlot target,
) {
  if (item.canMoveToSlot(target)) return null;
  return t.video_remote_control_reject_pinned;
}

/// 打开遥控器按钮自定义面板：读当前布局，改动立即写回偏好
/// `video_remote_control_layout`（偏好仓库会通知监听者，遥控页随之重建）。
/// [prefs] 省略时从 [appProvider] 取。
Future<void> showVideoRemoteControlEditor(
  BuildContext context, {
  PreferencesRepository? prefs,
}) {
  final PreferencesRepository repository =
      prefs ??
      ProviderScope.containerOf(
        context,
        listen: false,
      ).read(appProvider).prefsRepo;
  return adaptiveModalSheet<void>(
    context: context,
    expandable: true,
    builder: (BuildContext sheetContext) =>
        _VideoRemoteControlEditorSheet(prefs: repository),
  );
}

class _VideoRemoteControlEditorSheet extends StatefulWidget {
  const _VideoRemoteControlEditorSheet({required this.prefs});

  final PreferencesRepository prefs;

  @override
  State<_VideoRemoteControlEditorSheet> createState() =>
      _VideoRemoteControlEditorSheetState();
}

class _VideoRemoteControlEditorSheetState
    extends State<_VideoRemoteControlEditorSheet> {
  late VideoRemoteControlLayout _layout = widget.prefs.videoRemoteControlLayout;

  void _apply(VideoRemoteControlLayout next) {
    if (next == _layout) return;
    setState(() => _layout = next);
    unawaited(widget.prefs.setVideoRemoteControlLayout(next));
  }

  @override
  Widget build(BuildContext context) {
    return FushiModalSheetFrame(
      title: t.video_remote_control_customize,
      subtitle: t.video_remote_control_editor_hint,
      leadingIcon: FushiIcons.dashboardCustomize,
      scrollable: true,
      body: VideoRemoteControlEditor(layout: _layout, onLayoutChanged: _apply),
      footer: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: <Widget>[
          FushiTextButton(
            key: const ValueKey<String>('video-remote-control-editor-reset'),
            onPressed: _layout == VideoRemoteControlLayout.defaults
                ? null
                : () => _apply(VideoRemoteControlLayout.defaults),
            child: Text(t.reset),
          ),
        ],
      ),
    );
  }
}
