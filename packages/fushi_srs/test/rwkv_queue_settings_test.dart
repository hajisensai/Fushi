// RWKV-Instant 排队设置（牌组键 rwkvQueue）的解析：缺省 = 上游 kuma3 默认，坏值回落，越界夹住。
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

void main() {
  test('缺省 / 非 Map：上游默认（最少 0、间隔 5 次 / 30 秒）', () {
    for (final Object? v in <Object?>[null, 'x', 3]) {
      final SrsRwkvQueueSettings s = SrsRwkvQueueSettings.fromValue(v);
      expect(s.minReviewsPerDay, 0);
      expect(s.repeatMinReviews, 5);
      expect(s.repeatMinSeconds, 30);
      expect(s.ignoreReviewLimit, isFalse);
    }
  });

  test('往返；单项类型不对回落默认，负数与过大值夹到范围内', () {
    const SrsRwkvQueueSettings s = SrsRwkvQueueSettings(
      minReviewsPerDay: 12,
      repeatMinReviews: 0,
      repeatMinSeconds: 90,
      ignoreReviewLimit: true,
    );
    expect(SrsRwkvQueueSettings.fromValue(s.toValue()), s);
    final SrsRwkvQueueSettings odd = SrsRwkvQueueSettings.fromValue(
      <String, Object?>{
        'minReviews': -4,
        'repeatReviews': '7',
        'repeatSeconds': 1 << 30,
      },
    );
    expect(odd.minReviewsPerDay, 0);
    expect(odd.repeatMinReviews, 5);
    expect(odd.repeatMinSeconds, SrsRwkvQueueSettings.maxRepeatMinSeconds);
  });
}
