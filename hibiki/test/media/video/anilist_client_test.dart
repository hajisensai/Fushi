// AniList 搜索关键词 macron 归一化（BUG：带官方 romaji 长音的番剧名搜不到）。
//
// 根因（curl 实证）：AniList search 索引用双元音拼法（Chuunibyou），对 macron
// 长音（Chūnibyō）不做归一化匹配 → 用户打/复制带 macron 的官方 romaji 得 0
// 结果。normalizeAniListSearch 把 macron 展开成双元音（Chūnibyō→Chuunibyou）让其命中。

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/anilist_client.dart';

void main() {
  group('normalizeAniListSearch', () {
    test('strips macron vowels to their base latin letters', () {
      // 用户复制的官方 romaji（带 macron）→ AniList 认得的拼法基础。
      expect(normalizeAniListSearch('Chūnibyō Demo Koi ga Shitai!'),
          'Chuunibyou Demo Koi ga Shitai!');
      expect(normalizeAniListSearch('Tōkyō Gūru'), 'Toukyou Guuru');
      expect(normalizeAniListSearch('Frieren'), 'Frieren'); // no-op
    });

    test('handles all five long vowels, both cases', () {
      expect(normalizeAniListSearch('ĀāĒēĪīŌōŪū'), 'AaaaEeeeIiiiOuouUuuu');
    });

    test('drops combining macron (NFD decomposed form, U+0304)', () {
      // 分解形式：字母 + U+0304（combining macron）→ 基础字母（丢弃 macron）。
      expect(normalizeAniListSearch('Chūnibyō'), 'Chuunibyoo');
    });

    test('empty / plain queries are unchanged', () {
      expect(normalizeAniListSearch(''), '');
      expect(normalizeAniListSearch('bocchi the rock'), 'bocchi the rock');
    });
  });
}
