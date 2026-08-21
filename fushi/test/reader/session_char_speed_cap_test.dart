import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart';

/// BUG-1762：[accumulateSessionCharsCapped] 的速度封顶语义。
///
/// high-water 只挡「重复计入」，不挡「首次快速掠过」——按住翻页键扫到书末，每页
/// 都在到达瞬间全额入账。封顶把单次推进可计入的字数限制在「距上次水位推进的时间
/// × kMaxReadCharsPerSecond」内；超出的余量随水位静默抬走、不回补（掠过视同跳转，
/// 回来重读也不再计）。
void main() {
  test('正常阅读节奏够不到封顶：整页全额计入', () {
    // 60s 读一页 800 字：cap = 60 × 40 = 2400 ≥ 800。
    final ReadProgressResult r = accumulateSessionCharsCapped(
      absoluteChars: 1800,
      highWaterMark: 1000,
      elapsedMs: 60000,
    );
    expect(r.charsAdded, 800);
    expect(r.highWaterMark, 1800);
  });

  test('快速连翻被封顶：只计时间额度内的字数，水位仍推进到位', () {
    // 0.3s 翻一页 800 字：cap = 0.3 × 40 = 12。
    final ReadProgressResult r = accumulateSessionCharsCapped(
      absoluteChars: 1800,
      highWaterMark: 1000,
      elapsedMs: 300,
    );
    expect(r.charsAdded, 12);
    expect(r.highWaterMark, 1800, reason: '余量必须随水位静默抬走：掠过的内容视同跳转，回来重读也不再计');
  });

  test('封顶后回读再前进不回补被封掉的余量（high-water 语义保持）', () {
    final ReadProgressResult first = accumulateSessionCharsCapped(
      absoluteChars: 9000,
      highWaterMark: 1000,
      elapsedMs: 300, // 快速掠过 8000 字 → 只计 12
    );
    expect(first.charsAdded, 12);
    // 回读到 5000 再「到达」9000：位置未超水位 → 0。
    final ReadProgressResult again = accumulateSessionCharsCapped(
      absoluteChars: 9000,
      highWaterMark: first.highWaterMark,
      elapsedMs: 600000,
    );
    expect(again.charsAdded, 0);
    expect(again.highWaterMark, 9000);
  });

  test('未越过水位：0 计入、水位不动（与未封顶版一致）', () {
    final ReadProgressResult r = accumulateSessionCharsCapped(
      absoluteChars: 500,
      highWaterMark: 1000,
      elapsedMs: 60000,
    );
    expect(r.charsAdded, 0);
    expect(r.highWaterMark, 1000);
  });

  test('异常时间窗（负值/零）：0 计入但水位仍推进', () {
    for (final int elapsed in <int>[0, -500]) {
      final ReadProgressResult r = accumulateSessionCharsCapped(
        absoluteChars: 1800,
        highWaterMark: 1000,
        elapsedMs: elapsed,
      );
      expect(r.charsAdded, 0, reason: 'elapsed=$elapsed');
      expect(r.highWaterMark, 1800, reason: 'elapsed=$elapsed');
    }
  });
}
