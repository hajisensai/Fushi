/// Used for formatting byte-size strings.
///
/// 与 [HibikiTimeFormat] 风格对称的字节大小格式化唯一真相源（命名统一 G4 收敛，
/// 基底取自原 `update_checker_ui.dart` 的 `formatUpdateDownloadByteCount`）。
class HibikiByteFormat {
  /// 1024 进制人类可读大小：B 档整数（`512 B`），KB/MB/GB 保留 1 位小数
  /// （`1.5 KB` / `12.0 MB` / `1.2 GB`）。`null` → `—`（未知大小占位）。
  static String bytes(int? bytes) {
    if (bytes == null) return '—';
    if (bytes.abs() < 1024) return '$bytes B';

    const List<String> units = <String>['B', 'KB', 'MB', 'GB'];
    double value = bytes.toDouble();
    int unitIndex = 0;
    while (value.abs() >= 1024 && unitIndex < units.length - 1) {
      value /= 1024;
      unitIndex += 1;
    }
    return '${value.toStringAsFixed(1)} ${units[unitIndex]}';
  }

  /// `<大小>/s` 速率文案；`null` / 负值 / 非有限 → `—`。
  static String speed(double? bytesPerSecond) {
    if (bytesPerSecond == null || !bytesPerSecond.isFinite) return '—';
    if (bytesPerSecond < 0) return '—';
    return '${bytes(bytesPerSecond.round())}/s';
  }
}
