import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_home_layout.dart';
import 'package:fushi/src/media/video/video_library_memo.dart';
import 'package:fushi_core/fushi_core.dart';

void main() {
  group('DerivationMemo', () {
    test('same inputs reuse the cached result', () {
      final DerivationMemo<List<int>> memo = DerivationMemo<List<int>>();
      final List<int> rows = <int>[1, 2, 3];
      int computes = 0;
      List<int> derive() {
        computes++;
        return <int>[for (final int r in rows) r * 2];
      }

      final List<int> first = memo.of(<Object?>[rows, 'q', 2], derive);
      final List<int> second = memo.of(<Object?>[rows, 'q', 2], derive);
      expect(computes, 1);
      expect(identical(first, second), isTrue);
    });

    test('changed input recomputes', () {
      final DerivationMemo<int> memo = DerivationMemo<int>();
      int computes = 0;
      final List<int> rows = <int>[1];
      memo.of(<Object?>[rows, 'a'], () => ++computes);
      memo.of(<Object?>[rows, 'b'], () => ++computes);
      expect(computes, 2);
      // 新集合对象（内容相同）按身份判为变化。
      memo.of(<Object?>[
        <int>[1],
        'b',
      ], () => ++computes);
      expect(computes, 3);
      // 值语义的键（这里是 VideoYearFilter）按值判等。
      memo.of(<Object?>[VideoYearFilter.year(2020)], () => ++computes);
      memo.of(<Object?>[VideoYearFilter.year(2020)], () => ++computes);
      expect(computes, 4);
      memo.of(<Object?>[const VideoYearFilter.unknown()], () => ++computes);
      expect(computes, 5);
    });

    test('clear forces a recompute', () {
      final DerivationMemo<int> memo = DerivationMemo<int>();
      int computes = 0;
      memo.of(<Object?>['k'], () => ++computes);
      memo.clear();
      memo.of(<Object?>['k'], () => ++computes);
      expect(computes, 2);
    });

    test('null cached value is still a hit', () {
      final DerivationMemo<int?> memo = DerivationMemo<int?>();
      int computes = 0;
      int? derive() {
        computes++;
        return null;
      }

      memo.of(<Object?>['k'], derive);
      memo.of(<Object?>['k'], derive);
      expect(computes, 1);
    });
  });

  test('entriesOfKind equals per-uid composite-key lookups', () {
    final Map<String, int> byComposite = <String, int>{
      MediaKind.video.compositeKey('a'): 1,
      MediaKind.video.compositeKey('b|x'): 2,
      MediaKind.epub.compositeKey('a'): 3,
    };
    final Map<String, int> byUid = entriesOfKind<int>(
      byComposite,
      MediaKind.video,
    );
    for (final String uid in <String>['a', 'b|x', 'c', '']) {
      expect(byUid[uid], byComposite[MediaKind.video.compositeKey(uid)]);
    }
    expect(byUid.length, 2);
  });

  group('videoRecentlyAddedNextChangeMicros', () {
    final DateTime now = DateTime.fromMillisecondsSinceEpoch(1700000000000);
    final int windowMs = kVideoRecentlyAddedWindow.inMilliseconds;

    test('in-window entry flips one microsecond past the window', () {
      final int imported = now.millisecondsSinceEpoch - 1000;
      final int? next = videoRecentlyAddedNextChangeMicros(
        importedAts: <int?>[imported, null, 0],
        now: now,
      );
      expect(next, (imported + windowMs) * 1000 + 1);
      final DateTime before = DateTime.fromMicrosecondsSinceEpoch(next! - 1);
      final DateTime after = DateTime.fromMicrosecondsSinceEpoch(next);
      expect(isVideoRecentlyAdded(importedAt: imported, now: before), isTrue);
      expect(isVideoRecentlyAdded(importedAt: imported, now: after), isFalse);
    });

    test('future entry flips at its import time; expired ones never', () {
      final int future = now.millisecondsSinceEpoch + 5000;
      final int expired = now.millisecondsSinceEpoch - windowMs - 1;
      expect(
        videoRecentlyAddedNextChangeMicros(
          importedAts: <int?>[future, expired],
          now: now,
        ),
        future * 1000,
      );
      expect(
        videoRecentlyAddedNextChangeMicros(
          importedAts: <int?>[expired],
          now: now,
        ),
        isNull,
      );
    });
  });
}
