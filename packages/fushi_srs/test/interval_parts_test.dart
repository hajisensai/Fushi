import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

/// 评分按钮的间隔拆成「数值 + 单位」：单位交给界面按语言出文案（m 与 mo 不再混读）。
void main() {
  const int now = 1000000000;
  const int today = 100;

  ({String amount, SrsIntervalUnit unit}) learning(int minutes) =>
      srsIntervalParts(
        SrsScheduleResult(
          queue: SrsQueue.learning,
          dueAt: now + minutes * 60000,
        ),
        nowMs: now,
        today: today,
      );

  ({String amount, SrsIntervalUnit unit}) review(int days) => srsIntervalParts(
    SrsScheduleResult(queue: SrsQueue.review, dueDay: today + days),
    nowMs: now,
    today: today,
  );

  test('学习中：分钟 / 小时', () {
    expect(learning(0), (amount: '1', unit: SrsIntervalUnit.minutes));
    expect(learning(10), (amount: '10', unit: SrsIntervalUnit.minutes));
    expect(learning(90), (amount: '1.5', unit: SrsIntervalUnit.hours));
  });

  test('复习：天 / 月 / 年', () {
    expect(review(4), (amount: '4', unit: SrsIntervalUnit.days));
    expect(review(333), (amount: '11.1', unit: SrsIntervalUnit.months));
    expect(review(730), (amount: '2.0', unit: SrsIntervalUnit.years));
  });

  test('英文缩写形态与 Anki 一致', () {
    expect(
      srsFormatInterval(
        const SrsScheduleResult(queue: SrsQueue.review, dueDay: today + 333),
        nowMs: now,
        today: today,
      ),
      '11.1mo',
    );
  });
}
