import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/components/settings_shared.dart'
    show gamepadSeekableSlider;

/// 有声书倍速拖动条：普通阅读模式快捷设置（`reader_quick_settings_sheet`）
/// 与歌词模式倍速面板（`lyrics_speed_panel`）共用的**唯一实现**。
///
/// 范围 / 吸附 / 键盘步进只在这里写一次：0.25×–3.0×，拖动按 0.05× 一档吸附
/// （55 档），方向键 / 手柄 D-pad 左右单按一档。回调给的值已经吸附好，调用方
/// 直接交给 `AudiobookPlayerController.setSpeed`（它负责生效 + 持久化），两处
/// 入口因此写进同一个偏好、行为一字不差。
///
/// 独立成公开 widget（而非 sheet 私有方法）同 `AudiobookVolumeRow`：行为测试
/// 不必实例化持有 just_audio 平台播放器的控制器就能 pump 验证。
class AudiobookSpeedSlider extends StatelessWidget {
  const AudiobookSpeedSlider({
    required this.speed,
    required this.onChanged,
    super.key,
    this.autofocus = false,
  });

  /// 倍速下限。
  static const double minSpeed = 0.25;

  /// 倍速上限。
  static const double maxSpeed = 3.0;

  /// 拖动吸附档数：(3.0 - 0.25) / 0.05 = 55 档。
  static const int divisions = 55;

  /// 吸附到 0.05× 一档并夹进范围（键盘步进累加的浮点误差也在这里抹平）。
  static double snap(double value) =>
      ((value * 20).roundToDouble() / 20).clamp(minSpeed, maxSpeed);

  /// 读数文案：`1.25x`（两位小数，与普通模式快捷设置标题同一写法）。
  static String format(double speed) => '${speed.toStringAsFixed(2)}x';

  /// 当前倍速。
  final double speed;

  /// 吸附后的新倍速。
  final ValueChanged<double> onChanged;

  /// 挂载即抢焦点（弹出面板里唯一的调值控件，键盘 / 手柄打开后直接左右调）。
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final double value = speed.clamp(minSpeed, maxSpeed);
    return gamepadSeekableSlider(
      value: value,
      min: minSpeed,
      max: maxSpeed,
      divisions: divisions,
      label: format(value),
      autofocus: autofocus,
      onChanged: (double v) {
        final double snapped = snap(v);
        if ((snapped - speed).abs() < 0.001) return;
        onChanged(snapped);
      },
    );
  }
}
