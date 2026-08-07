import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/reader_hibiki_page.dart';

/// 收藏面板「阅读位置百分比」纯折算 [favoriteBookProgressFraction] 单测（用户反馈：
/// 收藏列表看不出每条在书里的位置）。section+章内偏移 → 全局偏移 → /总字符 = 全书分数。
void main() {
  // 3 章：每章 1000 字。cumulative=[0,1000,2000]，counts=[1000,1000,1000]，总 3000。
  const List<int> cumulative = [0, 1000, 2000];
  const List<int> counts = [1000, 1000, 1000];

  double? frac({required int section, required int? offset}) =>
      favoriteBookProgressFraction(
        cumulativeChars: cumulative,
        charCounts: counts,
        sectionIndex: section,
        normCharOffset: offset,
      );

  test('第 2 章章内偏移 500：全局 1500/3000 = 0.5', () {
    expect(frac(section: 1, offset: 500), closeTo(0.5, 1e-9));
  });

  test('第 3 章章内偏移 600：全局 2600/3000 ≈ 0.8667（用户示例式 % 就绪）', () {
    expect(frac(section: 2, offset: 600), closeTo(2600 / 3000, 1e-9));
  });

  test('章内偏移 null：落章起始（第 2 章 → 1000/3000）', () {
    expect(frac(section: 1, offset: null), closeTo(1000 / 3000, 1e-9));
  });

  test('章内偏移超章长：夹到章末（第 1 章 offset 9999 → 1000/3000）', () {
    expect(frac(section: 0, offset: 9999), closeTo(1000 / 3000, 1e-9));
  });

  test('末章末尾夹到 1.0（不超 1）', () {
    expect(frac(section: 2, offset: 100000), closeTo(1.0, 1e-9));
  });

  test('section 越界 → null（不显示位置）', () {
    expect(frac(section: 3, offset: 0), isNull);
    expect(frac(section: -1, offset: 0), isNull);
  });

  test('账本未就绪（空表 / 长度不匹配 / 总字符 0）→ null', () {
    expect(
      favoriteBookProgressFraction(
        cumulativeChars: const [],
        charCounts: const [],
        sectionIndex: 0,
        normCharOffset: 0,
      ),
      isNull,
    );
    expect(
      favoriteBookProgressFraction(
        cumulativeChars: const [0, 1000],
        charCounts: const [1000],
        sectionIndex: 0,
        normCharOffset: 0,
      ),
      isNull,
      reason: '长度不匹配 → null',
    );
    expect(
      favoriteBookProgressFraction(
        cumulativeChars: const [0],
        charCounts: const [0],
        sectionIndex: 0,
        normCharOffset: 0,
      ),
      isNull,
      reason: '总字符 0 → null',
    );
  });
}
