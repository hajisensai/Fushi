import 'package:fushi_engine/leaderboard/leaderboard_models.dart';
import 'package:test/test.dart';

void main() {
  group('ShelfEntryUpload', () {
    test('三态 toJson：在读 / 读完日期未知 / 读完有日期', () {
      final ShelfEntryUpload reading = ShelfEntryUpload(
        kind: LeaderboardKind.video,
        refs: <String>['tmdb:tv:1'],
        title: 'V',
        finished: false,
        chars: 1,
        ms: 2,
      );
      expect(reading.toJson().containsKey('finishedAt'), isFalse);
      expect(reading.toJson()['finished'], isFalse);

      final ShelfEntryUpload unknown = ShelfEntryUpload(
        kind: LeaderboardKind.game,
        refs: <String>['vndb:v1'],
        title: 'G',
        finished: true,
      );
      expect(unknown.toJson()['finished'], isTrue);
      expect(unknown.toJson().containsKey('finishedAt'), isFalse);
      expect(unknown.toJson().containsKey('finishedDate'), isFalse);

      final ShelfEntryUpload dated = ShelfEntryUpload(
        kind: LeaderboardKind.book,
        refs: <String>['isbn:9784040000011'],
        title: 'B',
        author: 'X',
        coverUrl: 'https://lain.bgm.tv/c.jpg',
        nsfw: true,
        finished: true,
        finishedAt: 1790000000000,
        finishedDate: '2026-09-21',
      );
      expect(dated.toJson(), <String, dynamic>{
        'kind': 'book',
        'refs': <String>['isbn:9784040000011'],
        'title': 'B',
        'author': 'X',
        'coverUrl': 'https://lain.bgm.tv/c.jpg',
        'nsfw': true,
        'finished': true,
        'finishedAt': 1790000000000,
        'finishedDate': '2026-09-21',
        'chars': 0,
        'ms': 0,
      });
    });

    test('服务端必拒的形状在构造时就拒', () {
      expect(
        () => ShelfEntryUpload(
          kind: LeaderboardKind.book,
          refs: <String>[],
          title: 'B',
          finished: false,
        ),
        throwsArgumentError,
      );
      expect(
        () => ShelfEntryUpload(
          kind: LeaderboardKind.book,
          refs: <String>['t:b|'],
          title: 'B',
          finished: true,
          finishedAt: 1790000000000,
        ),
        throwsArgumentError,
      );
      expect(
        () => ShelfEntryUpload(
          kind: LeaderboardKind.book,
          refs: <String>['t:b|'],
          title: 'B',
          finished: false,
          finishedAt: 1790000000000,
          finishedDate: '2026-09-21',
        ),
        throwsArgumentError,
      );
      expect(
        () => ShelfEntryUpload(
          kind: LeaderboardKind.book,
          refs: <String>['t:b|'],
          title: 'B',
          finished: true,
          finishedAt: 1790000000000,
          finishedDate: '2026/09/21',
        ),
        throwsArgumentError,
      );
      expect(
        () => DailyCharsUpload(date: '2026-9-1', chars: 1),
        throwsArgumentError,
      );
      expect(
        () => DailyCharsUpload(date: '2026-09-01', chars: -1),
        throwsArgumentError,
      );
    });

    test('contentHash：同内容恒等，任一字段变化即变，与键序无关', () {
      ShelfEntryUpload make({int chars = 1, String title = 'T'}) =>
          ShelfEntryUpload(
            kind: LeaderboardKind.book,
            refs: <String>['t:t|'],
            title: title,
            finished: false,
            chars: chars,
          );
      final String h = make().contentHash();
      expect(h, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(make().contentHash(), h);
      expect(make(chars: 2).contentHash(), isNot(h));
      expect(make(title: 'U').contentHash(), isNot(h));
    });

    test('counted：默认计入时不上报该键（已有条目哈希不变），false 才上报（BUG-2870）', () {
      ShelfEntryUpload make({bool counted = true}) => ShelfEntryUpload(
        kind: LeaderboardKind.book,
        refs: <String>['t:t|'],
        title: 'T',
        finished: true,
        counted: counted,
      );
      expect(make().toJson().containsKey('counted'), isFalse);
      expect(make(counted: false).toJson()['counted'], isFalse);
      expect(make(counted: false).contentHash(), isNot(make().contentHash()));
    });
  });

  group('读侧 fromJson ↔ toJson', () {
    test('RankPage 往返（总榜 from 为 null、匿名 me 为 null）', () {
      final Map<String, dynamic> j = <String, dynamic>{
        'metric': 'book',
        'window': 'all',
        'scope': 'global',
        'from': null,
        'computedAt': null,
        'total': 1,
        'me': null,
        'rows': <Map<String, dynamic>>[
          <String, dynamic>{
            'rank': 1,
            'value': 3,
            'account': <String, dynamic>{
              'id': 'a',
              'nickname': 'N',
              'discriminator': 7,
              'avatar': '/img/a/a-x-1.jpg',
            },
          },
        ],
      };
      final RankPage p = RankPage.fromJson(j);
      expect(p.me, isNull);
      expect(p.computedAt, isNull, reason: '快照还没生成 → UI 显示「榜单生成中」');
      expect(p.rows.single.account.tag, 'N#0007');
      expect(p.toJson(), j);
    });

    test('未知枚举值抛 FormatException', () {
      expect(() => LeaderboardMetric.fromWire('pages'), throwsFormatException);
      expect(LeaderboardWindow.fromWire('week'), LeaderboardWindow.week);
      expect(LeaderboardScope.fromWire('friends'), LeaderboardScope.friends);
      expect(LeaderboardKind.fromWire('manga'), LeaderboardKind.manga);
    });

    test('LeaderboardSelf：shelfCount 可缺省', () {
      final LeaderboardSelf s = LeaderboardSelf.fromJson(<String, dynamic>{
        'id': 'a',
        'nickname': 'N',
        'discriminator': 0,
        'avatar': null,
        'visibility': 'public',
        'createdAt': 1,
      });
      expect(s.shelfCount, isNull);
      expect(s.toJson().containsKey('shelfCount'), isFalse);
      expect(s.emailVerified, isFalse);
      expect(s.uploadDevice, isNull);
    });

    test('LeaderboardSelf：emailVerified 往返', () {
      final Map<String, dynamic> j = <String, dynamic>{
        'id': 'a',
        'nickname': 'N',
        'discriminator': 0,
        'avatar': null,
        'visibility': 'public',
        'createdAt': 1,
        'shelfCount': 2,
        'emailVerified': true,
        'uploadDevice': false,
      };
      final LeaderboardSelf s = LeaderboardSelf.fromJson(j);
      expect(s.emailVerified, isTrue);
      expect(s.uploadDevice, isFalse);
      expect(s.toJson(), j);
    });
  });
}
