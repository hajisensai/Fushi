import 'package:test/test.dart';
import 'package:fushi/src/media/audiobook/lyrics_cue_window_slide.dart';

/// BUG-4004 复审：歌词滑动窗口的上限对「锚点」生效。
///
/// 原失败：裁剪量只按播放句前后各留 [kLyricsWindowKeep] 来定。有声书暂停（播放句钉在
/// start+300）后用户一路往后滑，第一次拼接后 limit = cur-150-newStart = 0，此后每段
/// 净加 200 句：650 → 850 → 1050 … 一直涨到整书。修法：手动浏览时锚点是视口中线句；
/// 补装量受「另一端最多能卸多少」约束，窗口常驻永不超过 [kLyricsModeMaxInitialCues]。
typedef _Window = ({int start, int end});

_Window _apply(_Window w, LyricsWindowSlide plan) =>
    (start: plan.loadStart + plan.trimHead, end: plan.loadEnd - plan.trimTail);

/// 视口：中线句 ± 20 句在屏上（远小于 [kLyricsWindowKeep]）。
const int _viewHalf = 20;

void main() {
  const int total = 20000;
  const int paused = 5000;
  // LyricsCueWindow.select 的初始窗口：播放句居中、600 句。
  const _Window initial = (start: paused - 300, end: paused + 300);

  test('暂停后手动一路往后浏览 N 次：窗口条数恒 ≤ 上限、视口内的行一直在窗口里', () {
    _Window w = initial;
    for (int i = 0; i < 40; i++) {
      // 末句进入「视口外扩一屏」才请求：视口中线离窗口末尾几十句。
      final int view = w.end - 40;
      final LyricsWindowSlide? plan = planLyricsWindowSlide(
        total: total,
        start: w.start,
        end: w.end,
        forward: true,
        anchor: view,
      );
      expect(plan, isNotNull, reason: '第 $i 次：视口贴着末尾时必须能往后补');
      final _Window next = _apply(w, plan!);
      expect(
        next.end - next.start,
        lessThanOrEqualTo(kLyricsModeMaxInitialCues),
        reason: '第 $i 次拼接后窗口 ${next.end - next.start} 句，超过常驻上限',
      );
      expect(next.end, greaterThan(w.end), reason: '第 $i 次：浏览方向必须真的往前推');
      // 视口内的行不被卸掉（JS 按中线句补偿滚动后，它们在屏上不动）。
      expect(next.start, lessThanOrEqualTo(view - _viewHalf));
      expect(next.end, greaterThan(view + _viewHalf));
      // 中线句前后各 keep 句都留着。
      expect(next.start, lessThanOrEqualTo(view - kLyricsWindowKeep));
      w = next;
    }
    // 40 段之后窗口已远离暂停的播放句：上限不随浏览距离变化。
    expect(w.start, greaterThan(paused + kLyricsWindowKeep));
    expect(w.end - w.start, kLyricsModeMaxInitialCues);
  });

  test('暂停后手动一路往前浏览 N 次：对称地有上限、视口不丢', () {
    _Window w = initial;
    for (int i = 0; i < 20; i++) {
      final int view = w.start + 40;
      final LyricsWindowSlide? plan = planLyricsWindowSlide(
        total: total,
        start: w.start,
        end: w.end,
        forward: false,
        anchor: view,
      );
      expect(plan, isNotNull, reason: '第 $i 次');
      final _Window next = _apply(w, plan!);
      expect(
        next.end - next.start,
        lessThanOrEqualTo(kLyricsModeMaxInitialCues),
      );
      expect(next.start, lessThan(w.start));
      expect(next.end, greaterThan(view + kLyricsWindowKeep));
      expect(next.start, lessThanOrEqualTo(view - _viewHalf));
      w = next;
    }
  });

  test('锚点钉在暂停的播放句时也守住上限：卸不动就不再补（旧码在这里无上限变大）', () {
    _Window w = initial;
    int grown = 0;
    for (int i = 0; i < 20; i++) {
      final LyricsWindowSlide? plan = planLyricsWindowSlide(
        total: total,
        start: w.start,
        end: w.end,
        forward: true,
        anchor: paused,
      );
      if (plan == null) break;
      w = _apply(w, plan);
      grown++;
      expect(w.end - w.start, lessThanOrEqualTo(kLyricsModeMaxInitialCues));
      expect(w.start, lessThanOrEqualTo(paused - kLyricsWindowKeep));
    }
    expect(grown, 1, reason: '第一段卸掉播放句身后多出的 150 句后就到顶，不能再涨');
    expect(w, (start: paused - kLyricsWindowKeep, end: paused + 450));
  });

  test('跟随播放：锚点是播放句，走近边缘时滑一段、长度不变、播放句前后都留着', () {
    const _Window w = (start: 1000, end: 1600);
    const int cur = 1600 - kLyricsWindowEdgeMargin;
    final LyricsWindowSlide plan = planLyricsWindowSlide(
      total: total,
      start: w.start,
      end: w.end,
      forward: true,
      anchor: cur,
    )!;
    expect(plan.trimHead, kLyricsWindowChunk);
    expect(plan.trimTail, 0);
    final _Window next = _apply(w, plan);
    expect(next, (start: 1200, end: 1800));
    expect(next.start, lessThanOrEqualTo(cur - kLyricsWindowKeep));
  });

  test('无锚点（播放句暂不可解析）时随意卸，仍守上限', () {
    final LyricsWindowSlide plan = planLyricsWindowSlide(
      total: total,
      start: 0,
      end: 600,
      forward: true,
      anchor: -1,
    )!;
    expect(_apply((start: 0, end: 600), plan), (start: 200, end: 800));
  });

  test('窗口没满时只补不卸；到整书首 / 尾返回 null', () {
    final LyricsWindowSlide grow = planLyricsWindowSlide(
      total: total,
      start: 0,
      end: 300,
      forward: true,
      anchor: 290,
    )!;
    expect(grow.trimHead, 0);
    expect(_apply((start: 0, end: 300), grow), (start: 0, end: 500));
    expect(
      planLyricsWindowSlide(
        total: 700,
        start: 100,
        end: 700,
        forward: true,
        anchor: 650,
      ),
      isNull,
    );
    expect(
      planLyricsWindowSlide(
        total: 700,
        start: 0,
        end: 600,
        forward: false,
        anchor: 50,
      ),
      isNull,
    );
    // 尾部只剩 50 句：补 50、卸 50。
    final LyricsWindowSlide tail = planLyricsWindowSlide(
      total: 700,
      start: 50,
      end: 650,
      forward: true,
      anchor: 640,
    )!;
    expect(_apply((start: 50, end: 650), tail), (start: 100, end: 700));
  });
}
