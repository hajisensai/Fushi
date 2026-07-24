import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/stat_shared.dart';

/// 守卫统计页「按书/按视频 tile 显示所属合集名」的解析契约：
/// '<mediaType>|<entryKey>' 归属键（epub=bookKey / video=bookUid）经折叠归属主
/// collectionId 映到合集名，任一步缺失回退 null。
void main() {
  group('statCollectionName', () {
    final Map<String, int> primaryByEntry = <String, int>{
      'epub|book-a': 1,
      'video|uid-x': 2,
    };
    final Map<int, String> namesById = <int, String>{
      1: '夏目漱石全集',
      2: '进击的巨人 第一季',
    };

    test('书 entryKey=bookKey 命中合集名', () {
      expect(
        statCollectionName('epub|book-a', primaryByEntry, namesById),
        '夏目漱石全集',
      );
    });

    test('视频 entryKey=bookUid 命中合集名', () {
      expect(
        statCollectionName('video|uid-x', primaryByEntry, namesById),
        '进击的巨人 第一季',
      );
    });

    test('条目不属任何合集 → null', () {
      expect(
        statCollectionName('epub|orphan', primaryByEntry, namesById),
        isNull,
      );
    });

    test('归属到已被删除的合集（名字缺失）→ null 不崩', () {
      expect(
        statCollectionName(
          'epub|dangling',
          <String, int>{'epub|dangling': 99},
          namesById,
        ),
        isNull,
      );
    });

    test('媒体前缀区分：同 entryKey 不同 mediaType 不串', () {
      final Map<String, int> mixed = <String, int>{
        'epub|same': 1,
        'video|same': 2,
      };
      expect(statCollectionName('epub|same', mixed, namesById), '夏目漱石全集');
      expect(statCollectionName('video|same', mixed, namesById), '进击的巨人 第一季');
    });
  });

  // 显示名统一规则（非合集上下文拼「合集名 + 名字」，合集内部只显示名字）的
  // 纯函数层：resolveEntryDisplayTitle 供「标题=合集名、副标题=条目名」两行场景，
  // collectionQualifiedTitle 供活动时间轴等单行「合集名 - 名字」场景。
  group('resolveEntryDisplayTitle', () {
    final Map<String, int> primaryByEntry = <String, int>{
      'video|uid-x': 2,
    };
    final Map<int, String> namesById = <int, String>{
      2: '进击的巨人 第一季',
    };

    test('命中合集返回 (合集名, 原名)', () {
      final ({String? collectionName, String title}) r =
          resolveEntryDisplayTitle(
        entryKey: 'video|uid-x',
        rawTitle: 'S01E01',
        primaryByEntry: primaryByEntry,
        collectionNamesById: namesById,
      );
      expect(r.collectionName, '进击的巨人 第一季');
      expect(r.title, 'S01E01');
    });

    test('未命中返回 (null, 原名)', () {
      final ({String? collectionName, String title}) r =
          resolveEntryDisplayTitle(
        entryKey: 'video|orphan',
        rawTitle: 'S01E01',
        primaryByEntry: primaryByEntry,
        collectionNamesById: namesById,
      );
      expect(r.collectionName, isNull);
      expect(r.title, 'S01E01');
    });
  });

  group('collectionQualifiedTitle', () {
    final Map<String, int> primaryByEntry = <String, int>{
      'video|uid-x': 2,
      'epub|book-a': 1,
    };
    final Map<int, String> namesById = <int, String>{
      1: '夏目漱石全集',
      2: '进击的巨人 第一季',
    };

    test('命中合集拼「合集名 - 名字」（分隔符与制卡口径一致）', () {
      expect(
        collectionQualifiedTitle(
          entryKey: 'video|uid-x',
          rawTitle: 'S01E01',
          primaryByEntry: primaryByEntry,
          collectionNamesById: namesById,
        ),
        '进击的巨人 第一季 - S01E01',
      );
    });

    test('未命中原样返回条目名', () {
      expect(
        collectionQualifiedTitle(
          entryKey: 'epub|orphan',
          rawTitle: '吾輩は猫である',
          primaryByEntry: primaryByEntry,
          collectionNamesById: namesById,
        ),
        '吾輩は猫である',
      );
    });

    test('归属到已删除合集（名字缺失）→ 原样返回不崩', () {
      expect(
        collectionQualifiedTitle(
          entryKey: 'epub|dangling',
          rawTitle: '书名',
          primaryByEntry: <String, int>{'epub|dangling': 99},
          collectionNamesById: namesById,
        ),
        '书名',
      );
    });
  });
}
