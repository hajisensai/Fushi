import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart'
    show adaptiveModalSheet;
import 'package:fushi/src/utils/components/fushi_material_components.dart'
    show FushiModalSheetFrame;
import 'package:fushi/src/utils/components/glass/fushi_glass_toggles.dart'
    show FushiSlider;
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:material_ui/material_ui.dart';

/// 手机遥控器的音量弹层：一根 0–100 滑条，松手时把值交给 [onCommit]（每次拖动
/// 只发一条遥控命令，不随手指逐帧发）。[initial] 是电脑上报的当前音量。
Future<void> showVideoRemoteVolumeSheet({
  required BuildContext context,
  required int initial,
  required ValueChanged<int> onCommit,
}) => adaptiveModalSheet<void>(
  context: context,
  builder: (BuildContext sheetContext) =>
      VideoRemoteVolumeSheet(initial: initial, onCommit: onCommit),
);

/// [showVideoRemoteVolumeSheet] 的内容（单独成组件便于测试）。
class VideoRemoteVolumeSheet extends StatefulWidget {
  const VideoRemoteVolumeSheet({
    super.key,
    required this.initial,
    required this.onCommit,
  });

  final int initial;
  final ValueChanged<int> onCommit;

  @override
  State<VideoRemoteVolumeSheet> createState() => _VideoRemoteVolumeSheetState();
}

class _VideoRemoteVolumeSheetState extends State<VideoRemoteVolumeSheet> {
  late double _value = widget.initial.clamp(0, 100).toDouble();

  @override
  Widget build(BuildContext context) {
    final int percent = _value.round();
    return FushiModalSheetFrame(
      title: t.audio_volume,
      leadingIcon: percent == 0 ? FushiIcons.volumeOff : FushiIcons.volumeUp,
      body: Row(
        children: <Widget>[
          Expanded(
            child: FushiSlider(
              key: const ValueKey<String>('video-remote-volume-slider'),
              value: _value,
              max: 100,
              divisions: 100,
              label: '$percent',
              onChanged: (double value) => setState(() => _value = value),
              onChangeEnd: (double value) => widget.onCommit(value.round()),
            ),
          ),
          SizedBox(
            width: 48,
            child: Text(
              '$percent',
              textAlign: TextAlign.end,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
        ],
      ),
    );
  }
}
