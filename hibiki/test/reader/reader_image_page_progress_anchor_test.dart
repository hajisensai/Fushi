import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/reader_hibiki_page.dart'
    show imagePageProgressAnchor;

import '../pages/reader_hibiki_page_source_corpus.dart';

/// TODO-796 (Bug 1)：在目录里「导航到封面」时顶部阅读进度（百分比）不刷新。
///
/// 根因：封面/插图是纯图片页（`paginationMetrics.totalChars==0`）→ JS
/// `hoshiProgressDetails()` 返空串 → `parseReaderStableProgressDetails` 返 null →
/// `_refreshProgress` 旧逻辑 `if (snapshot == null) return;` 一律早退，
/// `_progressCurrentChars/_progressTotalChars` 保持上一章旧值，顶部百分比卡住。
///
/// 修复：snapshot==null 且当前章确实是纯图片页时，用该章在全书累计前缀里的章首
/// 字数 / 全书总字数给进度 UI 兜底（封面≈全书 0%），而不是沿用旧值。决策抽成纯函数
/// [imagePageProgressAnchor]，此处锁定其语义；Dart 端的接线由源码守卫锁定，防回归。
void main() {
  group('imagePageProgressAnchor（图片/封面页进度兜底锚点）', () {
    test('封面（章 0）锚到 0% —— current=章首=0，total=全书总字数', () {
      final anchor = imagePageProgressAnchor(
        chapterIndex: 0,
        cumulativeChars: const <int>[0, 1000, 3000],
        charCounts: const <int>[1000, 2000, 1500],
      );
      expect(anchor, isNotNull);
      expect(anchor!.currentChars, 0);
      // total = 末章累计 + 末章字数 = 3000 + 1500 = 4500
      expect(anchor.totalChars, 4500);
    });

    test('书末的图片页（插图）锚到该章章首累计字数，而非沿用旧值', () {
      final anchor = imagePageProgressAnchor(
        chapterIndex: 2,
        cumulativeChars: const <int>[0, 1000, 3000],
        charCounts: const <int>[1000, 2000, 1500],
      );
      expect(anchor, isNotNull);
      expect(anchor!.currentChars, 3000);
      expect(anchor.totalChars, 4500);
    });

    test('计数尚未算完（全书零字数）返回 null —— 不写脏进度', () {
      final anchor = imagePageProgressAnchor(
        chapterIndex: 0,
        cumulativeChars: const <int>[0, 0, 0],
        charCounts: const <int>[0, 0, 0],
      );
      expect(anchor, isNull);
    });

    test('累计前缀为空返回 null', () {
      expect(
        imagePageProgressAnchor(
          chapterIndex: 0,
          cumulativeChars: const <int>[],
          charCounts: const <int>[],
        ),
        isNull,
      );
    });

    test('章索引越界返回 null', () {
      const cumulative = <int>[0, 1000];
      const counts = <int>[1000, 500];
      expect(
        imagePageProgressAnchor(
          chapterIndex: -1,
          cumulativeChars: cumulative,
          charCounts: counts,
        ),
        isNull,
      );
      expect(
        imagePageProgressAnchor(
          chapterIndex: 2,
          cumulativeChars: cumulative,
          charCounts: counts,
        ),
        isNull,
      );
    });

    test('两列表长度不一致返回 null（保守，不读越界）', () {
      expect(
        imagePageProgressAnchor(
          chapterIndex: 0,
          cumulativeChars: const <int>[0, 1000],
          charCounts: const <int>[1000],
        ),
        isNull,
      );
    });
  });

  group('源码守卫：_refreshProgress 对图片页有进度兜底（防回归）', () {
    late String src;

    setUpAll(() {
      src = readReaderPageSource();
    });

    test('_refreshProgress 在 snapshot==null 时不再一律早退，走图片页兜底', () {
      final int idx = src.indexOf('Future<void> _refreshProgress() async');
      expect(idx, greaterThan(0), reason: '_refreshProgress 必须存在');
      final String body = src.substring(idx, idx + 1200);
      expect(
        body.contains('_applyImagePageProgressFallback();'),
        isTrue,
        reason: 'snapshot==null（图片/封面页）分支必须调图片页进度兜底，'
            '否则顶部百分比沿用上一章旧值（TODO-796 Bug1 回归）',
      );
    });

    test('_applyImagePageProgressFallback 经 isImageOnlyChapter 门控 + 纯函数锚点', () {
      final int idx =
          src.indexOf('void _applyImagePageProgressFallback() {');
      expect(idx, greaterThan(0),
          reason: '_applyImagePageProgressFallback 必须存在');
      final String body = src.substring(idx, idx + 900);
      // 只对真正的纯图片页兜底，普通章节走正常快照路径不受影响。
      expect(body.contains('isImageOnlyChapter(_currentChapter)'), isTrue,
          reason: '必须经 isImageOnlyChapter 门控，避免误伤普通无快照瞬态');
      expect(body.contains('imagePageProgressAnchor('), isTrue,
          reason: '落点必须走纯函数 imagePageProgressAnchor');
      // 只动进度 UI 字段，不碰 DB 落库 / session 累计。
      expect(body.contains('_progressCurrentChars = anchor.currentChars'),
          isTrue);
      expect(body.contains('_progressTotalChars = anchor.totalChars'), isTrue);
    });
  });
}
