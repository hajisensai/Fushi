import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/home_dashboard_derived.dart';
import 'package:fushi_core/fushi_core.dart' show VideoBookRow;

VideoBookRow _row(String uid, {String? cover}) => VideoBookRow(
  bookUid: uid,
  title: uid,
  videoPath: '/v/$uid.mkv',
  lastPositionMs: 0,
  currentEpisode: 0,
  delayMs: 0,
  coverPath: cover,
);

void main() {
  group('HomeDashboardMemo', () {
    test('同一组依赖复用结果，任一依赖换对象就重算', () {
      final HomeDashboardMemo<int> memo = HomeDashboardMemo<int>();
      int calls = 0;
      int compute() => ++calls;
      final List<int> a = <int>[1];
      final Map<String, int> m = <String, int>{};

      expect(memo.get(<Object?>[a, m, 'x', 3, true], compute), 1);
      expect(memo.get(<Object?>[a, m, 'x', 3, true], compute), 1);
      // 值类型按值比对：内容相同的新字符串不算变化。
      expect(memo.get(<Object?>[a, m, 'x' * 1, 3, true], compute), 1);
      expect(calls, 1);

      // 集合按身份：内容相同的新对象也要重算。
      expect(
        memo.get(<Object?>[
          <int>[1],
          m,
          'x',
          3,
          true,
        ], compute),
        2,
      );
      expect(memo.get(<Object?>[a, m, 'y', 3, true], compute), 3);
      expect(memo.get(<Object?>[a, m, 'y', 4, true], compute), 4);
      expect(memo.get(<Object?>[a, m, 'y', 4], compute), 5);
      memo.clear();
      expect(memo.get(<Object?>[a, m, 'y', 4], compute), 6);
    });

    test('null 结果也能缓存', () {
      final HomeDashboardMemo<int?> memo = HomeDashboardMemo<int?>();
      int calls = 0;
      int? compute() {
        calls++;
        return null;
      }

      final Object dep = Object();
      expect(memo.get(<Object?>[dep], compute), isNull);
      expect(memo.get(<Object?>[dep], compute), isNull);
      expect(calls, 1);
    });
  });

  group('HomeDashboardVideoIndex', () {
    final List<VideoBookRow> videos = <VideoBookRow>[
      _row('s1'),
      _row('b2', cover: '/c/b2.jpg'),
      _row('a1', cover: '/c/a1.jpg'),
      _row('b1', cover: '/c/b1.jpg'),
      _row('s2'),
      _row('a2'),
      _row('b3'),
    ];
    final Map<String, int> primary = <String, int>{
      'video|b2': 20,
      'video|a1': 10,
      'video|b1': 20,
      'video|a2': 10,
      'video|b3': 20,
      'epub|s1': 99,
    };
    final Map<String, int> sortIndex = <String, int>{
      'video|b1': 0,
      'video|b2': 1,
      'video|a2': 0,
      'video|a1': 1,
    };
    final HomeDashboardVideoIndex index = HomeDashboardVideoIndex.build(
      videos: videos,
      primaryCollectionByEntry: primary,
      memberSortIndex: sortIndex,
    );

    test('散视频 / 合集成员保持原顺序，合集按首次出现排列', () {
      expect(index.standalone.map((VideoBookRow v) => v.bookUid), <String>[
        's1',
        's2',
      ]);
      expect(index.collectionIds.toList(), <int>[20, 10]);
      expect(index.membersOf(20).map((VideoBookRow v) => v.bookUid), <String>[
        'b2',
        'b1',
        'b3',
      ]);
      expect(index.membersOf(77), isEmpty);
      expect(index.collectionOf('a1'), 10);
      expect(index.collectionOf('s1'), isNull);
    });

    test('组内序排序：sortIndex 升序，缺失沉底，再按 bookUid', () {
      expect(
        index.sortedMembersOf(20).map((VideoBookRow v) => v.bookUid),
        <String>['b1', 'b2', 'b3'],
      );
      expect(
        index.sortedMembersOf(10).map((VideoBookRow v) => v.bookUid),
        <String>['a2', 'a1'],
      );
      expect(
        identical(index.sortedMembersOf(20), index.sortedMembersOf(20)),
        isTrue,
      );
      expect(index.sortIndexOf('b3'), HomeDashboardVideoIndex.missingSortIndex);
    });

    test('同合集其它集封面排除自身、保持原顺序', () {
      expect(index.memberCoversOf(20, except: 'b1'), <String?>[
        '/c/b2.jpg',
        null,
      ]);
      expect(index.memberCoversOf(10, except: 'a2'), <String?>['/c/a1.jpg']);
    });

    test('isFor 按三份输入的身份判定', () {
      expect(index.isFor(videos, primary, sortIndex), isTrue);
      expect(
        index.isFor(List<VideoBookRow>.of(videos), primary, sortIndex),
        isFalse,
      );
      expect(
        index.isFor(videos, Map<String, int>.of(primary), sortIndex),
        isFalse,
      );
      expect(
        index.isFor(videos, primary, Map<String, int>.of(sortIndex)),
        isFalse,
      );
    });
  });
}
