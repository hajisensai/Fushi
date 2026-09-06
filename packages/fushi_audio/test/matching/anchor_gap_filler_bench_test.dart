import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_audio/fushi_audio.dart';

/// [AnchorGapFiller] 区间搜索的基准：复现上游审查 A1 的表（region × needle），
/// 对比旧实现（每个起点一次行 DP，O(R·n²)，逐字复制在下面）与现在的 Sellers
/// 半全局匹配（O(R·n)）。
///
/// 默认 skip；手动跑：
/// `flutter test test/matching/anchor_gap_filler_bench_test.dart --run-skipped`
/// （JIT，绝对值比审查者的 AOT 数字高，看相对比例。）
const String _pool = 'あいうえおかきくけこさしすせそたちつてとなにぬねのはひふへほ'
    'まみむめもやゆよらりるれろわをんがぎぐげござじずぜぞだぢづでど'
    '俺は三十四歳住所不定無職人生を後悔している真最中だ着のみまま家から叩き出された'
    '五人兄弟四番目として生まれ小学校成績も良かった周囲神童呼ばれていた';

String _corpus(int len, math.Random rng) {
  final StringBuffer b = StringBuffer();
  for (int i = 0; i < len; i++) {
    b.writeCharCode(_pool.codeUnitAt(rng.nextInt(_pool.length)));
  }
  return b.toString();
}

/// 从 [region] 中段取 needle 长的一段，替换掉两成字（模拟听写差）。
String _needle(String region, int n, math.Random rng) {
  final int at = region.length ~/ 2;
  final List<int> units = region.substring(at, at + n).codeUnits.toList();
  for (int i = 0; i < n; i += 5) {
    units[i] = _pool.codeUnitAt(rng.nextInt(_pool.length));
  }
  return String.fromCharCodes(units);
}

/// 旧实现（PR #1231 审查时的 `_bestSpan`，逐字复制，只把返回值换成 record）。
({int start, int end, double similarity})? _oldBestSpan(
  String needle,
  String gap,
  int cursor,
) {
  final int n = needle.length;
  if (n == 0 || cursor >= gap.length) return null;
  final int minLen = math.max(1, (n / 2).ceil());
  final int maxLen = math.min(2 * n, gap.length - cursor);
  if (maxLen < minLen) return null;
  ({int start, int end, double similarity})? best;
  for (int s = cursor; s + minLen <= gap.length; s++) {
    final int limit = math.min(maxLen, gap.length - s);
    List<int> prev = List<int>.generate(limit + 1, (int j) => j);
    List<int> curr = List<int>.filled(limit + 1, 0);
    for (int a = 1; a <= n; a++) {
      curr[0] = a;
      final int ca = needle.codeUnitAt(a - 1);
      for (int j = 1; j <= limit; j++) {
        final int cost = ca == gap.codeUnitAt(s + j - 1) ? 0 : 1;
        int v = prev[j - 1] + cost;
        final int del = prev[j] + 1;
        final int ins = curr[j - 1] + 1;
        if (del < v) v = del;
        if (ins < v) v = ins;
        curr[j] = v;
      }
      final List<int> tmp = prev;
      prev = curr;
      curr = tmp;
    }
    for (int len = minLen; len <= limit; len++) {
      final double sim = 1 - prev[len] / math.max(n, len);
      final bool better = best == null ||
          sim > best.similarity + 1e-9 ||
          (sim > best.similarity - 1e-9 &&
              _tieRank(n, len) < _tieRank(n, best.end - best.start));
      if (better) best = (start: s, end: s + len, similarity: sim);
    }
  }
  return best;
}

int _tieRank(int needleLen, int len) =>
    len <= needleLen ? needleLen - len : 1000 + (len - needleLen);

int _timeMs(void Function() body, {int repeat = 3}) {
  int best = 1 << 30;
  for (int r = 0; r < repeat; r++) {
    final Stopwatch sw = Stopwatch()..start();
    body();
    best = math.min(best, sw.elapsedMilliseconds);
  }
  return best;
}

void main() {
  test(
    'bestSpan 基准：旧 O(R·n²) vs Sellers O(R·n)',
    () {
      final math.Random rng = math.Random(20260906);
      final StringBuffer out = StringBuffer()
        ..writeln('| region | needle | old ms | new ms | same span |')
        ..writeln('|---|---|---|---|---|');
      for (final int region in <int>[1000, 10000, 40000]) {
        final String text = _corpus(region, rng);
        for (final int n in <int>[30, 60]) {
          final String needle = _needle(text, n, rng);
          ({int start, int end, double similarity})? oldR;
          ({int start, int end, double similarity})? newR;
          final int oldMs = _timeMs(() => oldR = _oldBestSpan(needle, text, 0));
          final int newMs = _timeMs(
            () => newR = AnchorGapFiller.bestSpanForTest(
              needle,
              text,
              0,
              text.length,
            ),
          );
          expect(newR, isNotNull);
          expect(oldR, isNotNull);
          // 植入的 needle 就在正文中段：两者都应找到它（相似度 ≥ 0.75）。
          expect(newR!.similarity, greaterThanOrEqualTo(0.75));
          final bool same = oldR!.start == newR!.start &&
              oldR!.end == newR!.end &&
              (oldR!.similarity - newR!.similarity).abs() < 1e-9;
          out.writeln('| $region | $n | $oldMs | $newMs | $same |');
        }
      }
      // ignore: avoid_print
      print(out);
    },
    skip: '手动基准：flutter test <本文件> --run-skipped',
  );
}
