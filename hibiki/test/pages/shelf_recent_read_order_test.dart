import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/media/collections/shelf_sort.dart';
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart';
import 'package:hibiki_core/hibiki_core.dart';

import '../helpers/test_platform_services.dart';

/// BUG-756：继续阅读 hero 与书架「最近阅读」曾按 provider 列表序（=
/// `getAllEpubBooks` 的 importedAt 倒序）当「最近访问序」用——刚读过的老书永远
/// 选不中/排不前。锁死修复的两层：
/// ① [mostRecentlyReadCandidate] 纯选择器（hero 选「最后阅读时间」最大者）；
/// ② [bookLastReadAtProvider] 从真 DB 读 `reader_positions.updatedAt` 建映射，
///    invalidate 后能拿到重读书的新时间戳（关书 onSourceExit 的失效语义）。
/// 页面接线（hero/排序都消费该映射、假名次 seq 不回潮）由
/// `unified_collections_architecture_guard_test.dart` 的源码守卫锁。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('mostRecentlyReadCandidate（hero 选书纯选择器）', () {
    test('选最后阅读时间最大者，而非列表首位（列表首位=最近导入）', () {
      final String? hero = mostRecentlyReadCandidate(
        <String>['新导入在读', '刚读过的老书'],
        (String s) => s == '刚读过的老书' ? 200 : 100,
      );
      expect(hero, '刚读过的老书', reason: '刚读的书必须赢过更晚导入的书（BUG-756 原症状）');
    });

    test('全部无时间戳（0）保留首个候选 = 旧行为退化（映射未加载时不闪变）', () {
      expect(
        mostRecentlyReadCandidate(<String>['a', 'b'], (String _) => 0),
        'a',
      );
    });

    test('空候选返回 null（无在读书 → 整块只剩统计）', () {
      expect(
        mostRecentlyReadCandidate(<String>[], (String _) => 0),
        isNull,
      );
    });
  });

  group('bookLastReadAtProvider（真 DB 读 reader_positions.updatedAt）', () {
    late HibikiDatabase db;
    late ProviderContainer container;

    setUp(() {
      db = HibikiDatabase.forTesting(NativeDatabase.memory());
      final AppModel appModel = AppModel(testPlatformServices())
        ..wireDatabaseForTesting(db);
      container = ProviderContainer(overrides: <Override>[
        appProvider.overrideWith((ref) => appModel),
      ]);
    });

    tearDown(() async {
      container.dispose();
      await db.close();
    });

    test('映射 = bookKey → updatedAt（EPUB/SRT 同走 bookKey，一次批量查询）', () async {
      await db.upsertReaderPosition(const ReaderPositionsCompanion(
        bookKey: Value('老书'),
        sectionIndex: Value(3),
        normCharOffset: Value(5000),
        updatedAt: Value(200),
      ));
      await db.upsertReaderPosition(const ReaderPositionsCompanion(
        bookKey: Value('新导入'),
        sectionIndex: Value(0),
        normCharOffset: Value(10),
        updatedAt: Value(100),
      ));

      final Map<String, int> map =
          await container.read(bookLastReadAtProvider.future);
      expect(map, <String, int>{'老书': 200, '新导入': 100});
    });

    test('重读后 invalidate 重取拿到新 updatedAt（关书 onSourceExit 失效语义）', () async {
      await db.upsertReaderPosition(const ReaderPositionsCompanion(
        bookKey: Value('书'),
        sectionIndex: Value(0),
        normCharOffset: Value(1),
        updatedAt: Value(1),
      ));
      expect(
        await container.read(bookLastReadAtProvider.future),
        containsPair('书', 1),
      );

      await db.upsertReaderPosition(const ReaderPositionsCompanion(
        bookKey: Value('书'),
        sectionIndex: Value(2),
        normCharOffset: Value(9),
        updatedAt: Value(999),
      ));
      container.invalidate(bookLastReadAtProvider);
      expect(
        await container.read(bookLastReadAtProvider.future),
        containsPair('书', 999),
        reason: '刚读完的书必须立即反映新时间戳，hero/最近阅读才不陈旧',
      );
    });
  });
}
