import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/media.dart';
import 'package:fushi/src/reader/reader_content_styles.dart';
import 'package:fushi/src/reader/reader_settings.dart';
import 'package:fushi_core/fushi_core.dart';

/// 锁定两个阅读器显示项的**默认开启**，以及「显式关过的用户不被默认值覆盖」。
///
/// 这两个键各有两处默认字面量（[ReaderSettings] 的 `_get` 真值 + reader 未
/// 初始化时 [ReaderFushiSource] 的 `getPreference` 兜底）。两处漂开时用户会
/// 看到「设置页显示开着、阅读器却按关的渲染」，所以这里逐项对比两条读路径，
/// 而不是只断言其中一条。
FushiDatabase _testDb() {
  return FushiDatabase.forTesting(
    DatabaseConnection(NativeDatabase.memory()),
  );
}

void main() {
  group('reader display defaults (merge_image_pages / reader_styles)', () {
    late FushiDatabase db;

    setUp(() {
      db = _testDb();
      MediaSource.setDatabase(db);
      ReaderFushiSource.readerSettings = null;
    });

    tearDown(() async {
      ReaderFushiSource.readerSettings = null;
      await db.close();
    });

    test('merge illustration pages into text defaults to ON', () async {
      final ReaderSettings settings = ReaderSettings(db);
      await settings.refreshFromDb();

      expect(settings.mergeImagePages, isTrue);
      // reader 未初始化时的兜底读路径必须给出同一个答案。
      expect(ReaderFushiSource.instance.readerMergeImagePages, isTrue);
    });

    test('prioritize book styles defaults to ON', () async {
      final ReaderSettings settings = ReaderSettings(db);
      await settings.refreshFromDb();

      expect(settings.prioritizeReaderStyles, isTrue);
      expect(ReaderFushiSource.instance.readerPrioritizeReaderStyles, isTrue);
    });

    test('an explicit user OFF survives the new default', () async {
      final ReaderSettings settings = ReaderSettings(db);
      await settings.refreshFromDb();
      await settings.setMergeImagePages(false);
      await settings.setPrioritizeReaderStyles(false);

      final ReaderSettings restored = ReaderSettings(db);
      await restored.refreshFromDb();

      expect(restored.mergeImagePages, isFalse);
      expect(restored.prioritizeReaderStyles, isFalse);
    });

    test('defaults are not written to the DB (so they stay changeable)',
        () async {
      final ReaderSettings settings = ReaderSettings(db);
      await settings.refreshFromDb();
      // 触发读取，走 _get 的缺键分支。
      settings.mergeImagePages;
      settings.prioritizeReaderStyles;

      final Map<String, String> prefs = await db.getAllPrefs();
      expect(prefs.containsKey('src:reader_fushi:merge_image_pages'), isFalse);
      expect(prefs.containsKey('src:reader_fushi:reader_styles'), isFalse);
    });
  });

  group('prioritize book styles: CSS effect of the new default', () {
    late FushiDatabase db;

    setUp(() {
      db = _testDb();
      MediaSource.setDatabase(db);
      ReaderFushiSource.readerSettings = null;
    });

    tearDown(() async {
      ReaderFushiSource.readerSettings = null;
      await db.close();
    });

    test('by default the reader no longer forces image sizing with !important',
        () async {
      final ReaderSettings settings = ReaderSettings(db);
      await settings.refreshFromDb();
      final String css = ReaderContentStyles.css(settings: settings);

      // 这几条是 readerStylePriority 后缀的实际落点；默认开启 = 书自带 CSS 赢。
      expect(css, contains('width: auto;'));
      expect(css, isNot(contains('width: auto !important;')));
      expect(css, contains('object-fit: contain;'));
      expect(css, isNot(contains('object-fit: contain !important;')));
      // 与本开关无关的强制项不受影响（同一条规则内的分栏/断页保护）。
      expect(css, contains('break-inside: avoid !important;'));
    });

    test('turning it off restores the !important overrides', () async {
      final ReaderSettings settings = ReaderSettings(db);
      await settings.refreshFromDb();
      await settings.setPrioritizeReaderStyles(false);
      final String css = ReaderContentStyles.css(settings: settings);

      expect(css, contains('width: auto !important;'));
      expect(css, contains('object-fit: contain !important;'));
    });
  });
}
