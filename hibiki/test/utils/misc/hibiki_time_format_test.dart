import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/misc/hibiki_time_format.dart';

void main() {
  group('FushiTimeFormat.getFfmpegTimestamp', () {
    test('formats zero duration', () {
      expect(
        FushiTimeFormat.getFfmpegTimestamp(Duration.zero),
        '00:00:00.000',
      );
    });

    test('formats hours, minutes, seconds, milliseconds', () {
      const d = Duration(hours: 1, minutes: 23, seconds: 45, milliseconds: 678);
      expect(FushiTimeFormat.getFfmpegTimestamp(d), '01:23:45.678');
    });

    test('formats sub-second duration', () {
      const d = Duration(milliseconds: 500);
      expect(FushiTimeFormat.getFfmpegTimestamp(d), '00:00:00.500');
    });

    test('formats exactly one hour', () {
      const d = Duration(hours: 1);
      expect(FushiTimeFormat.getFfmpegTimestamp(d), '01:00:00.000');
    });

    test('pads single digit values', () {
      const d = Duration(hours: 2, minutes: 3, seconds: 4, milliseconds: 5);
      expect(FushiTimeFormat.getFfmpegTimestamp(d), '02:03:04.005');
    });
  });

  group('FushiTimeFormat.dayKey / hourMinute / dateHourMinute', () {
    test('dayKey 零填充月/日', () {
      expect(FushiTimeFormat.dayKey(DateTime(2026, 7, 5)), '2026-07-05');
      expect(FushiTimeFormat.dayKey(DateTime(2026, 12, 31)), '2026-12-31');
    });

    test('hourMinute 恒补零（24 小时制）', () {
      expect(FushiTimeFormat.hourMinute(DateTime(2026, 7, 5, 9, 3)), '09:03');
      expect(
        FushiTimeFormat.hourMinute(DateTime(2026, 7, 5, 21, 41)),
        '21:41',
      );
    });

    test('dateHourMinute = dayKey + 空格 + hourMinute', () {
      expect(
        FushiTimeFormat.dateHourMinute(DateTime(2026, 7, 5, 9, 3)),
        '2026-07-05 09:03',
      );
    });
  });

  group('FushiTimeFormat.getVideoDurationText', () {
    test('zero duration shows 0:00 with padding', () {
      expect(
        FushiTimeFormat.getVideoDurationText(Duration.zero),
        '  0:00  ',
      );
    });

    test('shows minutes:seconds when no hours', () {
      const d = Duration(minutes: 5, seconds: 30);
      expect(FushiTimeFormat.getVideoDurationText(d), '  5:30  ');
    });

    test('shows hours:MM:SS when hours present', () {
      const d = Duration(hours: 1, minutes: 23, seconds: 45);
      expect(FushiTimeFormat.getVideoDurationText(d), '  1:23:45  ');
    });

    test('seconds only shows 0:SS', () {
      const d = Duration(seconds: 7);
      expect(FushiTimeFormat.getVideoDurationText(d), '  0:07  ');
    });

    test('pads seconds to two digits', () {
      const d = Duration(minutes: 2, seconds: 5);
      expect(FushiTimeFormat.getVideoDurationText(d), '  2:05  ');
    });
  });
}
