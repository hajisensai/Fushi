// RWKV-Instant 排队设置（牌组键 rwkvQueue）的解析：缺省 = 上游 kuma3 默认，坏值回落，越界夹住。
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

void main() {
  test('缺省 / 非 Map：上游默认（最少 0、间隔 5 次 / 30 秒）；没写过「忽略每日复习上限」= 关', () {
    for (final Object? v in <Object?>[null, 'x', 3]) {
      final SrsRwkvQueueSettings s = SrsRwkvQueueSettings.fromValue(v);
      expect(s.minReviewsPerDay, 0);
      expect(s.repeatMinReviews, 5);
      expect(s.repeatMinSeconds, 30);
      expect(s.ignoreReviewLimit, isFalse);
    }
  });

  test('忽略每日复习上限：旧牌组的值没有这个键 → 关（每日复习上限照旧生效）；只认明确的 true；新建牌组的初值开着', () {
    // 加这项设置之前写下的值（只有四项）：不能读成开，否则老用户自己设的每日复习上限被无声覆盖。
    expect(
      SrsRwkvQueueSettings.fromValue(<String, Object?>{
        'minReviews': 3,
        'repeatReviews': 5,
        'repeatSeconds': 30,
        'refreshEvery': 1,
      }).ignoreReviewLimit,
      isFalse,
    );
    for (final Object? v in <Object?>[false, null, 'true', 1]) {
      expect(
        SrsRwkvQueueSettings.fromValue(<String, Object?>{
          'ignoreLimit': v,
        }).ignoreReviewLimit,
        isFalse,
        reason: '$v',
      );
    }
    expect(
      SrsRwkvQueueSettings.fromValue(<String, Object?>{
        'ignoreLimit': true,
      }).ignoreReviewLimit,
      isTrue,
    );
    expect(SrsRwkvQueueSettings.forNewDeck.ignoreReviewLimit, isTrue);
    expect(
      SrsRwkvQueueSettings.fromValue(SrsRwkvQueueSettings.forNewDeck.toValue()),
      SrsRwkvQueueSettings.forNewDeck,
    );
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
