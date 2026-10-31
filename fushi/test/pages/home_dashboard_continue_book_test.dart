import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/media.dart';
import 'package:fushi/src/media/collections/collection_continue.dart';
import 'package:fushi/src/pages/implementations/home_dashboard_page.dart';
import 'package:fushi_engine/media/collections/book_series_key.dart';

/// BUG-2918：首页「继续」区曾只按 `0 < position < duration` 判「在读」，而阅读器
/// 存的位置是末页首个可见字符——读到最后一页 position 永远 < duration、百分比四舍五入
/// 显示 100%，于是读完的书（`EpubBooks.completedAt` 已置）照样挂在「继续」里。
/// 判据收敛到书架同一条 `classifyShelfReadStatus`：已完成一律不进。
MediaItem _book(String key, {required int position, required int duration}) =>
    MediaItem(
      mediaIdentifier: ReaderFushiSource.mediaIdentifierFor(key),
      title: key,
      mediaTypeIdentifier: ReaderFushiSource.instance.mediaType.uniqueKey,
      mediaSourceIdentifier: ReaderFushiSource.instance.uniqueKey,
      position: position,
      duration: duration,
      canDelete: false,
      canEdit: true,
    );

void main() {
  test('已标记完成的书即使末页位置 < duration 也不进「继续」区', () {
    // 用户报告的原样形态：位置停在末页首字（99.6% → 显示 100%），completedAt 已置。
    final MediaItem finished = _book('done', position: 9960, duration: 10000);
    expect(isDashboardContinueBook(finished, <String>{'done'}), isFalse);
  });

  test('未完成、0 < position < duration 的书仍进「继续」区', () {
    final MediaItem reading = _book('reading', position: 50, duration: 100);
    expect(isDashboardContinueBook(reading, <String>{'other'}), isTrue);
    expect(isDashboardContinueBook(reading, const <String>{}), isTrue);
  });

  test('未开读（position 0）或未知总长（duration 0）不进「继续」区', () {
    expect(
      isDashboardContinueBook(
        _book('fresh', position: 0, duration: 100),
        const <String>{},
      ),
      isFalse,
    );
    expect(
      isDashboardContinueBook(
        _book('nolen', position: 10, duration: 0),
        const <String>{},
      ),
      isFalse,
    );
  });

  test('位置到达 duration 视为读完，不进「继续」区', () {
    expect(
      isDashboardContinueBook(
        _book('end', position: 100, duration: 100),
        const <String>{},
      ),
      isFalse,
    );
  });

  test('完成集合按 bookKey 命中，不受同前缀 key 干扰', () {
    final MediaItem item = _book('book', position: 5, duration: 10);
    expect(isDashboardContinueBook(item, <String>{'book2', 'boo'}), isTrue);
  });

  group('dashboardBookCollectionContinueIndex（书合集续读目标）', () {
    CollectionMemberProgress vol({
      int position = 0,
      bool completed = false,
      int readAt = 0,
    }) => CollectionMemberProgress(
      positionMs: position,
      completed: completed,
      lastPlayedAt: readAt,
    );

    test('用户实报：读完第 1 卷 → 推进到第 2 卷', () {
      expect(
        dashboardBookCollectionContinueIndex(<CollectionMemberProgress>[
          vol(position: 100, completed: true, readAt: 10),
          vol(),
          vol(),
        ]),
        1,
      );
    });

    test('锚点按最近阅读时刻，不按卷序最靠后', () {
      expect(
        dashboardBookCollectionContinueIndex(<CollectionMemberProgress>[
          vol(position: 30, readAt: 50),
          vol(),
          vol(position: 60, readAt: 10),
        ]),
        0,
      );
    });

    test('整套读完 / 一卷都没开读 / 空合集 → null', () {
      expect(
        dashboardBookCollectionContinueIndex(<CollectionMemberProgress>[
          vol(position: 100, completed: true, readAt: 1),
          vol(position: 100, completed: true, readAt: 2),
        ]),
        isNull,
      );
      expect(
        dashboardBookCollectionContinueIndex(<CollectionMemberProgress>[
          vol(),
          vol(),
        ]),
        isNull,
      );
      expect(
        dashboardBookCollectionContinueIndex(
          const <CollectionMemberProgress>[],
        ),
        isNull,
      );
    });
  });

  group('collectionMemberVolumeNumber（续读卡「第 N 卷」/ 书架「读到第 N 卷」）', () {
    const String dm = '絶対に働きたくないダンジョンマスターが惰眠をむさぼるまで';
    // 原样书名：1、2 卷 dc:title 用全角空格 + 全角数字，3 卷起半角。
    final List<String> dmTitles = <String>[
      '$dm　１',
      '$dm　２',
      for (int n = 3; n <= 17; n++) '$dm $n',
    ];

    test('用户实报：第 2 卷排在合集第 17 位时徽标仍是卷号 2，不是位置 17', () {
      expect(
        collectionMemberVolumeNumber(
          title: '$dm　２',
          memberTitles: dmTitles,
          memberOrdinal: 17,
        ),
        2,
      );
      expect(
        collectionMemberVolumeNumber(
          title: '$dm 17',
          memberTitles: dmTitles,
          memberOrdinal: 1,
        ),
        17,
      );
    });

    test('主题合集（成员不同系列）里书名尾数不当卷号：Fahrenheit 451 不是 Vol. 451', () {
      const List<String> theme = <String>[
        'Fahrenheit 451',
        '1984',
        'Brave New World',
      ];
      expect(
        collectionMemberVolumeNumber(
          title: 'Fahrenheit 451',
          memberTitles: theme,
          memberOrdinal: 1,
        ),
        1,
      );
      expect(
        collectionMemberVolumeNumber(
          title: '$dm　２',
          memberTitles: <String>['$dm　２', '安達としまむら10'],
          memberOrdinal: 2,
        ),
        2,
        reason: '混了别的系列同样退回位置',
      );
      expect(
        collectionMemberVolumeNumber(
          title: '安達としまむら10',
          memberTitles: <String>['$dm　２', '安達としまむら10'],
          memberOrdinal: 1,
        ),
        1,
      );
    });

    test('书名没有卷号：同系列兄弟都带卷号且无第 1 卷时是第 1 卷，否则退回位置', () {
      expect(
        collectionMemberVolumeNumber(
          title: '安達としまむら',
          memberTitles: <String>['安達としまむら2', 'しまむらSS', '安達としまむら'],
          memberOrdinal: 3,
        ),
        1,
        reason: '无卷号的首卷存在位置 3 也是第 1 卷',
      );
      expect(
        collectionMemberVolumeNumber(
          title: '安達としまむら',
          memberTitles: <String>['安達としまむら1', '安達としまむら'],
          memberOrdinal: 2,
        ),
        2,
        reason: '已有卷自称第 1 卷，无卷号的那本认不出第几卷',
      );
      expect(
        collectionMemberVolumeNumber(
          title: '86',
          memberTitles: <String>['86', '86'],
          memberOrdinal: 3,
        ),
        3,
      );
    });

    // BUG continue-card-volume-number：用户实报「安達としまむら3」续读卡显示
    // 「第 13 卷」——合集混了番外（系列键与正篇不同），旧判据要求全体同系列，一混
    // 番外就退回存储位置，而合集顺序又乱，第 3 卷排在第 13 位。
    test('用户实报：正篇 + 番外合集里第 3 卷存在位置 13 仍是第 3 卷', () {
      final List<String> members = <String>[
        '安達としまむら5',
        '安達としまむら8',
        '安達としまむらSS',
        '安達としまむら',
        '安達としまむら2',
        '安達としまむら4',
        '安達としまむら6',
        '安達としまむら7',
        '安達としまむら9',
        '安達としまむら10',
        '安達としまむら11',
        '安達としまむら12',
        '安達としまむら3',
        '安達としまむら13 (電撃文庫)',
      ];
      expect(members.indexOf('安達としまむら3') + 1, 13);
      expect(
        collectionMemberVolumeNumber(
          title: '安達としまむら3',
          memberTitles: members,
          memberOrdinal: 13,
        ),
        3,
      );
      expect(
        collectionMemberVolumeNumber(
          title: '安達としまむら13 (電撃文庫)',
          memberTitles: members,
          memberOrdinal: 14,
        ),
        13,
      );
      expect(
        collectionMemberVolumeNumber(
          title: '安達としまむら',
          memberTitles: members,
          memberOrdinal: 4,
        ),
        1,
        reason: '无卷号的首卷',
      );
      expect(
        collectionMemberVolumeNumber(
          title: '安達としまむらSS',
          memberTitles: members,
          memberOrdinal: 3,
        ),
        3,
        reason: '番外不是正篇的卷，退回合集内序号（与合集详情页同序）',
      );
    });
  });
}
