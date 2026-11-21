import 'package:fushi_engine/media/video/subtitle/srt_writer.dart';
import 'package:test/test.dart';

void main() {
  group('formatSrtTimestamp', () {
    test('HH:MM:SS,mmm 各位补零', () {
      expect(formatSrtTimestamp(0), '00:00:00,000');
      expect(formatSrtTimestamp(1234), '00:00:01,234');
      expect(formatSrtTimestamp(61005), '00:01:01,005');
      expect(formatSrtTimestamp(3723456), '01:02:03,456');
    });

    test('负值 clamp 到 0，不写出取模后的伪毫秒', () {
      expect(formatSrtTimestamp(-1), '00:00:00,000');
      expect(formatSrtTimestamp(-50), '00:00:00,000');
      expect(formatSrtTimestamp(-3723456), '00:00:00,000');
    });

    test('超过 99 小时按实际位数写出', () {
      expect(formatSrtTimestamp(100 * 3600000 + 1), '100:00:00,001');
    });
  });

  group('writeSrtBlocks', () {
    test('序号从 1 连续、按给定顺序、每块后一个空行、只用 \\n', () {
      final String srt = writeSrtBlocks(<SrtBlock>[
        (startMs: 5000, endMs: 6000, text: 'い'),
        (startMs: 0, endMs: 1500, text: 'あ\nう'),
      ]);
      expect(
        srt,
        '1\n00:00:05,000 --> 00:00:06,000\nい\n\n'
        '2\n00:00:00,000 --> 00:00:01,500\nあ\nう\n\n',
      );
      expect(srt, isNot(contains('\r')));
    });

    test('空输入返回空串', () {
      expect(writeSrtBlocks(const <SrtBlock>[]), isEmpty);
    });
  });
}
