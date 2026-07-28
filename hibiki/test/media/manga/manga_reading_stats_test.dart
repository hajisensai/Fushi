import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/manga/manga_reading_stats.dart';
import 'package:hibiki/src/media/manga/mokuro_payload.dart';

/// 守卫漫画的字数/页数记账（v60）：漫画此前 `charsRead` 恒 0，只记时长，统计页
/// 永远显示 0 字。现在按已读页的 OCR 文本计字数、按已读页计页数，两个量纲各自
/// 独立，且同一页在一次会话里只记一次。
MokuroImage _page(List<String> lines) => MokuroImage(
      url: 'p.jpg',
      size: const Size(800, 1200),
      blocks: <MokuroBlock>[
        MokuroBlock(
          rectangle: const Rect.fromLTRB(0, 0, 10, 10),
          isVertical: true,
          fontSize: 12,
          zIndex: 0,
          lines: lines,
        ),
      ],
    );

void main() {
  group('mangaPageCharCount', () {
    test('口径与 EPUB 同源：剔除标点/括号/空白，只数假名与汉字', () {
      // 「こんにちは、世界。」→ こんにちは(5) + 世界(2) = 7。
      expect(mangaPageCharCount(_page(<String>['「こんにちは、', '世界。」'])), 7);
    });

    test('无 OCR 的纯图页为 0', () {
      expect(
        mangaPageCharCount(const MokuroImage(
          url: 'p.jpg',
          size: Size(800, 1200),
          blocks: <MokuroBlock>[],
        )),
        0,
      );
    });
  });

  group('mangaAccumulateReadingStats', () {
    final MokuroPayload payload = MokuroPayload(
      images: <MokuroImage>[
        _page(<String>['あいう']), // 3
        _page(<String>['かきくけ']), // 4
        _page(<String>['さ']), // 1
      ],
    );

    test('首次经过的页计字数与页数', () {
      final Set<int> counted = <int>{};
      final ({int chars, int pages}) r = mangaAccumulateReadingStats(
        payload: payload,
        pageIndices: <int>[0, 1],
        counted: counted,
      );
      expect(r.chars, 7);
      expect(r.pages, 2);
      expect(counted, <int>{0, 1});
    });

    test('同一页翻回来不重复计（来回翻页刷不出数）', () {
      final Set<int> counted = <int>{};
      mangaAccumulateReadingStats(
        payload: payload,
        pageIndices: <int>[0, 1],
        counted: counted,
      );
      final ({int chars, int pages}) again = mangaAccumulateReadingStats(
        payload: payload,
        pageIndices: <int>[1, 0],
        counted: counted,
      );
      expect(again.chars, 0);
      expect(again.pages, 0);

      final ({int chars, int pages}) fresh = mangaAccumulateReadingStats(
        payload: payload,
        pageIndices: <int>[1, 2],
        counted: counted,
      );
      expect(fresh.chars, 1, reason: '只有新页 2 计入');
      expect(fresh.pages, 1);
    });

    test('越界页码忽略，不抛也不计', () {
      final Set<int> counted = <int>{};
      final ({int chars, int pages}) r = mangaAccumulateReadingStats(
        payload: payload,
        pageIndices: <int>[-1, 99],
        counted: counted,
      );
      expect(r.chars, 0);
      expect(r.pages, 0);
      expect(counted, isEmpty);
    });
  });
}
