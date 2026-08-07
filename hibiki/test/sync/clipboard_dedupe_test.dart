import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/clipboard_dedupe.dart';

void main() {
  group('dedupeClipboard', () {
    test('trims and returns new text', () {
      expect(dedupeClipboard('  見る  ', null), '見る');
    });
    test('returns null when same as last (after trim)', () {
      expect(dedupeClipboard('見る', '見る'), isNull);
      expect(dedupeClipboard('  見る ', '見る'), isNull);
    });
    test('returns null for empty/blank', () {
      expect(dedupeClipboard('', null), isNull);
      expect(dedupeClipboard('   ', null), isNull);
    });
    test('returns new text when changed', () {
      expect(dedupeClipboard('読む', '見る'), '読む');
    });
  });

  // BUG-1025 回归守卫：同词重复复制必须能再查。旧实现「与上次相同即 null」是永久内容
  // 去重，用户在浏览器里再复制一次同一个词永远查不出来。改为时间窗：窗口内的同词判为
  // 挖词/抓选区写回剪贴板的自触发回声跳过，超窗口的同词判为用户显式重查放行。
  group('dedupeClipboard 时间窗去重 (BUG-1025)', () {
    final DateTime t0 = DateTime(2026, 7, 23, 12, 0, 0);

    test('窗口内的同词仍判为自触发回声，跳过', () {
      expect(
        dedupeClipboard(
          '見る',
          '見る',
          lastAt: t0,
          now: t0.add(const Duration(milliseconds: 100)),
        ),
        isNull,
      );
    });

    test('超出窗口的同词判为用户显式重查，放行', () {
      expect(
        dedupeClipboard(
          '見る',
          '見る',
          lastAt: t0,
          now: t0.add(const Duration(seconds: 3)),
        ),
        '見る',
        reason: '用户手动再次复制同一个词必须能重新查词（BUG-1025 的用户症状）',
      );
    });

    test('窗口边界：恰好等于窗口长度即放行（窗口是开区间上界）', () {
      expect(
        dedupeClipboard('見る', '見る',
            lastAt: t0, now: t0.add(kClipboardRecopyWindow)),
        '見る',
      );
    });

    test('不同的词与时序无关，恒放行', () {
      expect(
        dedupeClipboard('読む', '見る',
            lastAt: t0, now: t0.add(const Duration(milliseconds: 1))),
        '読む',
      );
    });

    test('空串恒跳过，时间窗不改变这一点', () {
      expect(
        dedupeClipboard('   ', '見る',
            lastAt: t0, now: t0.add(const Duration(seconds: 10))),
        isNull,
      );
    });

    test('缺时序信息时退回历史行为（相同即跳过）', () {
      expect(dedupeClipboard('見る', '見る', lastAt: t0), isNull);
      expect(dedupeClipboard('見る', '見る', now: t0), isNull);
    });
  });
}
