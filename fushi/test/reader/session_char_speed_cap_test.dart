import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart';

/// BUG-1762：[accumulateSessionCharsCapped] 的速度封顶语义（令牌桶）。
///
/// high-water 只挡「重复计入」，不挡「首次快速掠过」——按住翻页键扫到书末，每页
/// 都在到达瞬间全额入账。封顶把**持续**速率限制在 kMaxReadCharsPerSecond 内：额度
/// 按流逝时间累积、跨次结转，计入时扣减；超出额度的部分随水位静默抬走、不回补
/// （掠过视同跳转，回来重读也不再计）。
///
/// 跨次结转是关键：早先那版按「距上次水位推进的时间 × 速率」收费，等于按**上报
/// 节奏**收费——连续模式一次甩动被 50ms 节流拆成 5~8 次推进，第一次吃光额度、后面
/// 几次各自只隔几十毫秒，正常阅读被砍掉八成。
void main() {
  // 桶容量按 kMaxReadingGap 折算，这里取一个足够大的值代表「不设额外上限」。
  const int bigBucket = 600000 * kMaxReadCharsPerSecond;

  test('正常阅读节奏够不到封顶：整页全额计入', () {
    // 60s 读一页 800 字：额度 = 60 × 40 = 2400 ≥ 800。
    final ReadChargeResult r = accumulateSessionCharsCapped(
      absoluteChars: 1800,
      highWaterMark: 1000,
      elapsedMs: 60000,
      creditMilliChars: 0,
      maxCreditMilliChars: bigBucket,
    );
    expect(r.charsAdded, 800);
    expect(r.highWaterMark, 1800);
    expect(r.creditMilliChars, 60000 * kMaxReadCharsPerSecond - 800 * 1000,
        reason: '没花掉的额度必须留在桶里');
  });

  test('快速连翻被封顶：只计额度内的字数，水位仍推进到位', () {
    // 0.3s 翻一页 800 字：额度 = 0.3 × 40 = 12。
    final ReadChargeResult r = accumulateSessionCharsCapped(
      absoluteChars: 1800,
      highWaterMark: 1000,
      elapsedMs: 300,
      creditMilliChars: 0,
      maxCreditMilliChars: bigBucket,
    );
    expect(r.charsAdded, 12);
    expect(r.highWaterMark, 1800, reason: '余量必须随水位静默抬走：掠过的内容视同跳转，回来重读也不再计');
    expect(r.creditMilliChars, 0, reason: '额度被花光');
  });

  // 回归锚：本条在「按距上次推进的时间收费」的旧实现下必红。
  test('上报被拆成多份不影响总计入量（连续模式 50ms 节流的形状）', () {
    // 读一屏 400 字用 60s，然后 0.5s 甩过下一屏 400 字，被拆成 8 次上报。
    ReadChargeResult r = accumulateSessionCharsCapped(
      absoluteChars: 400,
      highWaterMark: 0,
      elapsedMs: 60000,
      creditMilliChars: 0,
      maxCreditMilliChars: bigBucket,
    );
    int total = r.charsAdded;
    expect(total, 400, reason: '第一屏正常阅读，全额计入');

    for (int i = 1; i <= 8; i++) {
      r = accumulateSessionCharsCapped(
        absoluteChars: 400 + i * 50,
        highWaterMark: r.highWaterMark,
        elapsedMs: 62, // 8 × 62ms ≈ 0.5s
        creditMilliChars: r.creditMilliChars,
        maxCreditMilliChars: bigBucket,
      );
      total += r.charsAdded;
    }
    // 60s 攒下 2400 字额度，第一屏花掉 400，余 2000 足够覆盖后面 400 字。
    expect(total, 800, reason: '碎片化上报不得被惩罚：按上报节奏收费时这里只有 ~400+20');
    expect(r.highWaterMark, 800);
  });

  test('桶有容量上限：挂机不攒无限额度', () {
    // 挂机 10 分钟后甩过 100000 字，桶容量只按 kMaxReadingGap 折算。
    const int gapMs = 30000; // 代表 kMaxReadingGap
    const int bucket = gapMs * kMaxReadCharsPerSecond; // = 1200 字
    final ReadChargeResult r = accumulateSessionCharsCapped(
      absoluteChars: 100000,
      highWaterMark: 0,
      elapsedMs: 600000,
      creditMilliChars: 0,
      maxCreditMilliChars: bucket,
    );
    expect(r.charsAdded, 1200, reason: '额度被桶容量截断，不随挂机时长线性增长');
    expect(r.highWaterMark, 100000);
  });

  test('封顶后回读再前进不回补被封掉的余量（high-water 语义保持）', () {
    final ReadChargeResult first = accumulateSessionCharsCapped(
      absoluteChars: 9000,
      highWaterMark: 1000,
      elapsedMs: 300, // 快速掠过 8000 字 → 只计 12
      creditMilliChars: 0,
      maxCreditMilliChars: bigBucket,
    );
    expect(first.charsAdded, 12);
    // 回读到 5000 再「到达」9000：位置未超水位 → 0。
    final ReadChargeResult again = accumulateSessionCharsCapped(
      absoluteChars: 9000,
      highWaterMark: first.highWaterMark,
      elapsedMs: 600000,
      creditMilliChars: first.creditMilliChars,
      maxCreditMilliChars: bigBucket,
    );
    expect(again.charsAdded, 0);
    expect(again.highWaterMark, 9000);
  });

  test('未越过水位：0 计入、水位不动，但额度照常累积', () {
    final ReadChargeResult r = accumulateSessionCharsCapped(
      absoluteChars: 500,
      highWaterMark: 1000,
      elapsedMs: 60000,
      creditMilliChars: 0,
      maxCreditMilliChars: bigBucket,
    );
    expect(r.charsAdded, 0);
    expect(r.highWaterMark, 1000);
    expect(r.creditMilliChars, 60000 * kMaxReadCharsPerSecond,
        reason: '原地停留也在攒额度，否则长停留页翻过去时计不满');
  });

  test('异常时间窗（负值/零）：不计入但水位仍推进，额度不为负', () {
    for (final int elapsed in <int>[0, -500]) {
      final ReadChargeResult r = accumulateSessionCharsCapped(
        absoluteChars: 1800,
        highWaterMark: 1000,
        elapsedMs: elapsed,
        creditMilliChars: -1,
        maxCreditMilliChars: bigBucket,
      );
      expect(r.charsAdded, 0, reason: 'elapsed=$elapsed');
      expect(r.highWaterMark, 1800, reason: 'elapsed=$elapsed');
      expect(r.creditMilliChars, greaterThanOrEqualTo(0),
          reason: 'elapsed=$elapsed');
    }
  });
}
