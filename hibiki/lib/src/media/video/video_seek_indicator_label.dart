/// TODO-916 症状①：视频横滑 seek 居中 HUD 的纯文本格式化。
///
/// media_kit fork（third_party/media_kit_video）的 `seekIndicatorBuilder` 只回传
/// **增量** Duration（有符号 swipeDuration）。主流播放器横滑时显示的是**目标绝对
/// 时间**而非纯增量，故把「拖动起点位置 + 增量」算成 clamp 到 `[0, duration]` 的目标
/// 时间。逻辑抽成无依赖纯函数类，便于在 widget 测试外直接单测（真实手势 seek 在
/// headless 里驱动不了，见 `test/pages/video_horizontal_seek_test.dart`）。
class VideoSeekIndicatorLabel {
  const VideoSeekIndicatorLabel._();

  /// 目标绝对时间标签：`位置 + 增量` clamp 到 `[0, duration]` 后格式化。
  /// [delta] 可负（向后拖）。
  static String target(
    Duration position,
    Duration delta,
    Duration duration,
  ) {
    Duration result = position + delta;
    if (result < Duration.zero) {
      result = Duration.zero;
    } else if (result > duration) {
      result = duration;
    }
    return clock(result);
  }

  /// 增量标签（带正负号，如 `+0:15` / `-1:20`）。[delta] 有符号。
  static String deltaSigned(Duration delta) {
    final String sign = delta.isNegative ? '-' : '+';
    return '$sign${clock(delta.abs())}';
  }

  /// 把非负 [value] 格式化成时钟串：不足 1 小时 `M:SS`（分不补前导零，如 `9:05`），
  /// 满 1 小时 `H:MM:SS`。负值由调用方先取绝对值。
  static String clock(Duration value) {
    final int totalSeconds = value.inSeconds;
    final int hours = totalSeconds ~/ 3600;
    final int minutes = (totalSeconds % 3600) ~/ 60;
    final int seconds = totalSeconds % 60;
    String two(int v) => v.toString().padLeft(2, '0');
    if (hours > 0) {
      return '$hours:${two(minutes)}:${two(seconds)}';
    }
    return '$minutes:${two(seconds)}';
  }
}
