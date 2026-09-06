import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_reading_stats.dart';
import 'package:fushi/src/media/manga/mokuro_payload.dart';

/// 守卫漫画的字数/页数换算（v60）：漫画此前 `charsRead` 恒 0，只记时长，统计页
/// 永远显示 0 字。现在按已读页的 OCR 文本计字数、按已读页计页数，两个量纲各自
/// 独立。「哪些页算读过」的去重由 `ReadUnitLedger` 会话并集负责（2026-09-06），
/// 本函数是无状态换算，不再持去重集合。
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

  group('mangaStatsForPages', () {
    final MokuroPayload payload = MokuroPayload(
      images: <MokuroImage>[
        _page(<String>['あいう']), // 3
        _page(<String>['かきくけ']), // 4
        _page(<String>['さ']), // 1
      ],
    );

    test('给定页的字数与页数：两个量纲独立', () {
      final ({int chars, int pages}) r = mangaStatsForPages(payload, <int>[
        0,
        1,
      ]);
      expect(r.chars, 7);
      expect(r.pages, 2);
    });

    test('无状态：同样的页再算一遍结果相同（去重在账本，不在这里）', () {
      expect(mangaStatsForPages(payload, <int>[1, 2]).chars, 5);
      expect(mangaStatsForPages(payload, <int>[1, 2]).chars, 5);
      expect(mangaStatsForPages(payload, <int>[2]), (chars: 1, pages: 1));
    });

    test('越界页码忽略，不抛也不计', () {
      final ({int chars, int pages}) r = mangaStatsForPages(payload, <int>[
        -1,
        99,
      ]);
      expect(r.chars, 0);
      expect(r.pages, 0);
    });

    test('空页表 → 0 / 0', () {
      expect(mangaStatsForPages(payload, const <int>[]), (chars: 0, pages: 0));
    });
  });
}
