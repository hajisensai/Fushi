import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/discovery/discovery_labels.dart';

/// 发现页副标题的日期展示：只把完整 ISO 8601 时间戳（OPDS Atom `<updated>`）
/// 收成本地日期，其余源的原文一个字都不动。
void main() {
  String localDate(String iso) {
    final DateTime local = DateTime.parse(iso).toLocal();
    return '${local.year.toString().padLeft(4, '0')}-'
        '${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')}';
  }

  test('OPDS 的 UTC 时间戳收成本地日期，不再露出 T/毫秒/Z', () {
    const String raw = '2026-09-25T04:55:58.997Z';
    final String shown = formatDiscoveryDate(raw);
    expect(shown, localDate(raw));
    expect(shown, isNot(contains('T')));
    expect(shown, matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')));
  });

  test('带时区偏移的 RFC 3339 同样按本地日期显示', () {
    const String raw = '2026-01-02T23:30:00+09:00';
    expect(formatDiscoveryDate(raw), localDate(raw));
  });

  test('非 ISO 时间戳的源原文原样保留（不猜时区）', () {
    expect(formatDiscoveryDate('2026-09-25 04:55'), '2026-09-25 04:55');
    expect(formatDiscoveryDate('2026-09-25'), '2026-09-25');
    expect(formatDiscoveryDate('3 days ago'), '3 days ago');
    expect(formatDiscoveryDate(''), '');
  });

  test('形似 ISO 但缺时刻的原样返回', () {
    expect(formatDiscoveryDate('2026-09-25Tgarbage'), '2026-09-25Tgarbage');
  });
}
