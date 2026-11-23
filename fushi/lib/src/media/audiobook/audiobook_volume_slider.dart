import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/components/settings_shared.dart'
    show gamepadSeekableSlider;

/// 有声书音量拖动条：有声书快捷设置的音量行（`AudiobookVolumeRow`）与漫画有声
/// 播放条的音量弹层共用的**唯一口径**。
///
/// 范围 / 吸附 / 键盘步进只在这里写一次：0–200%（与
/// `AudiobookPlayerController.setVolume` 的 clamp 一致），拖动 1% 一档（200 档），
/// 方向键 / 手柄 D-pad 单按 5%——全程 1% 一按要按 200 下，单按步进与拖动档位
/// 解耦。回调给的值直接交给 `AudiobookPlayerController.setVolume`（它负责生效 +
/// 按书持久化），所以两处入口写进同一个按书音量、行为一字不差。
///
/// 独立成公开 widget 同 `AudiobookSpeedSlider`：行为测试不必实例化持有 just_audio
/// 平台播放器的控制器就能 pump 验证。
class AudiobookVolumeSlider extends StatelessWidget {
  const AudiobookVolumeSlider({
    required this.volume,
    required this.onChanged,
    super.key,
    this.autofocus = false,
  });

  /// 音量上限（200%）。
  static const double maxVolume = 2.0;

  /// 拖动吸附档数：0–200% 共 200 档 = 1% 一档。
  static const int sliderDivisions = 200;

  /// 键盘 / 手柄左右键单按步进：5%。
  static const double keyStep = 0.05;

  /// 读数文案：`80%`。
  static String format(double volume) =>
      '${(volume.clamp(0.0, maxVolume) * 100).round()}%';

  /// 当前音量（0.0–2.0，1.0 = 100%）。
  final double volume;

  /// 新音量（已按档位吸附 / 步进对齐）。
  final ValueChanged<double> onChanged;

  /// 挂载即抢焦点（弹出面板里唯一的调值控件，键盘 / 手柄打开后直接左右调）。
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final double value = volume.clamp(0.0, maxVolume);
    return gamepadSeekableSlider(
      value: value,
      max: maxVolume,
      divisions: sliderDivisions,
      label: format(value),
      step: keyStep,
      autofocus: autofocus,
      onChanged: onChanged,
    );
  }
}
