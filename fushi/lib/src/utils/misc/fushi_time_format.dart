/// Used for formatting time-related strings.
class FushiTimeFormat {
  /// Used for generating a timestamp for use with FFMPEG.
  static String getFfmpegTimestamp(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    String threeDigits(int n) => n.toString().padLeft(3, '0');

    String hours = twoDigits(duration.inHours);
    String mins = twoDigits(duration.inMinutes.remainder(60));
    String secs = twoDigits(duration.inSeconds.remainder(60));
    String mills = threeDigits(duration.inMilliseconds.remainder(1000));

    return '$hours:$mins:$secs.$mills';
  }

  /// 通用时钟串：不足 1 小时 `M:SS`（分钟不补零，如 `9:05`），满 1 小时
  /// `H:MM:SS`。负值不做归一（调用方先 clamp / abs）。
  static String clock(Duration duration) {
    final int totalSeconds = duration.inSeconds;
    final int hours = totalSeconds ~/ 3600;
    final int minutes = (totalSeconds % 3600) ~/ 60;
    final int seconds = totalSeconds % 60;
    final String ss = seconds.toString().padLeft(2, '0');
    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:$ss';
    }
    return '$minutes:$ss';
  }

  /// 同 [clock]，但分钟恒补零：`MM:SS` / `H:MM:SS`。
  static String clockPadded(Duration duration) {
    final int totalSeconds = duration.inSeconds;
    final int hours = totalSeconds ~/ 3600;
    final int minutes = (totalSeconds % 3600) ~/ 60;
    final int seconds = totalSeconds % 60;
    final String mm = minutes.toString().padLeft(2, '0');
    final String ss = seconds.toString().padLeft(2, '0');
    if (hours > 0) {
      return '$hours:$mm:$ss';
    }
    return '$mm:$ss';
  }

  /// `yyyy-MM-dd` day key（零填充月/日，可字典序比较）。统计行 dateKey、备份
  /// 文件名/日期展示共用此一处实现。
  static String dayKey(DateTime date) =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

  /// 本地化无关的 `HH:mm`（时/分恒补零，24 小时制）。
  static String hourMinute(DateTime time) =>
      '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

  /// 本地化无关的 `yyyy-MM-dd HH:mm`（不引 intl，跨 17 语言一致）。
  static String dateHourMinute(DateTime time) =>
      '${dayKey(time)} ${hourMinute(time)}';

  /// Used to display duration on video history items.
  static String getVideoDurationText(Duration duration) {
    String twoDigits(String n) => n.padLeft(2, '0');

    String hours = duration.inHours.toString();
    String mins = duration.inMinutes.remainder(60).toString();
    String secs = duration.inSeconds.remainder(60).toString();

    String padMins = twoDigits(mins);
    String padSecs = twoDigits(secs);

    if (duration.inHours != 0) {
      return '  $hours:$padMins:$padSecs  ';
    } else if (duration.inMinutes != 0) {
      return '  $mins:$padSecs  ';
    } else {
      return '  0:$padSecs  ';
    }
  }
}
