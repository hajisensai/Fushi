import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki/src/reader/reader_settings.dart';

/// TODO-728 持久化守卫：三项阅读器 chrome 偏好。
///  ② showBottomBarCue —— per-reader，默认 true。
/// （③ topProgressPosition / ① gamepadAutoimmersive 在各自提交追加 group。）
///
/// 复用 reader_hibiki_source_test 的 per-reader 分层断言范式（同一 DB key，
/// ReaderSettings._set 用 value.toString() 编码 'true'，与 source.setPreference
/// 的 'b:true' 区分，坐实写经哪条路径）。
void main() {
  group('showBottomBarCue is per-reader (TODO-728②)', () {
    setUp(() {
      ReaderHibikiSource.readerSettings = null;
    });
    tearDown(() {
      ReaderHibikiSource.readerSettings = null;
    });

    test('defaults to true and round-trips through the global source pref',
        () async {
      final db = HibikiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      MediaSource.setDatabase(db);

      final source = ReaderHibikiSource.instance;
      await source.refreshPreferencesFromDb();

      // 默认 true = 现状（始终显示 cue）。
      expect(source.showBottomBarCue, isTrue);

      source.toggleShowBottomBarCue();
      await Future<void>.delayed(Duration.zero);
      expect(source.showBottomBarCue, isFalse);
      expect(
        await db.getPref('src:reader_ttu:show_bottom_bar_cue'),
        'b:false',
      );
    });

    test('reads/writes through ReaderSettings (per-reader) when open',
        () async {
      final db = HibikiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      MediaSource.setDatabase(db);

      final source = ReaderHibikiSource.instance;
      await source.refreshPreferencesFromDb();

      final ReaderSettings perBook = ReaderSettings(db);
      await perBook.refreshFromDb();
      ReaderHibikiSource.readerSettings = perBook;

      expect(source.showBottomBarCue, isTrue);

      source.toggleShowBottomBarCue();
      await Future<void>.delayed(Duration.zero);
      expect(perBook.showBottomBarCue, isFalse);
      expect(source.showBottomBarCue, isFalse);
      // 走 per-reader 分层：ReaderSettings._set 用 'false'（非 'b:false'）。
      expect(
        await db.getPref('src:reader_ttu:show_bottom_bar_cue'),
        'false',
      );
    });

    test('two ReaderSettings instances (two books) do not cross-contaminate',
        () async {
      // per-reader 隔离用两个独立 DB 模拟两本书各自的 profile 快照。
      final dbA = HibikiDatabase.forTesting(NativeDatabase.memory());
      final dbB = HibikiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(dbA.close);
      addTearDown(dbB.close);

      final ReaderSettings bookA = ReaderSettings(dbA);
      final ReaderSettings bookB = ReaderSettings(dbB);
      await bookA.refreshFromDb();
      await bookB.refreshFromDb();

      // Book A 关闭 cue；Book B 不动（保持默认 true）。
      await bookA.toggleShowBottomBarCue();
      expect(bookA.showBottomBarCue, isFalse);
      expect(bookB.showBottomBarCue, isTrue,
          reason: 'per-reader pref must not leak across books');
    });
  });

  group('topProgressPosition is per-reader (TODO-728 3)', () {
    setUp(() {
      ReaderHibikiSource.readerSettings = null;
    });
    tearDown(() {
      ReaderHibikiSource.readerSettings = null;
    });

    test('defaults to center and round-trips through the global source pref',
        () async {
      final db = HibikiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      MediaSource.setDatabase(db);

      final source = ReaderHibikiSource.instance;
      await source.refreshPreferencesFromDb();

      expect(source.topProgressPosition, 'center');

      source.setTopProgressPosition('right');
      await Future<void>.delayed(Duration.zero);
      expect(source.topProgressPosition, 'right');
      expect(
        await db.getPref('src:reader_ttu:top_progress_position'),
        's:right',
      );
    });

    test('an unknown stored value degrades to center', () async {
      final db = HibikiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      MediaSource.setDatabase(db);

      final source = ReaderHibikiSource.instance;
      await source.refreshPreferencesFromDb();
      await db.setPref('src:reader_ttu:top_progress_position', 's:bottom');
      await source.refreshPreferencesFromDb();
      expect(source.topProgressPosition, 'center');
    });

    test('reads/writes through ReaderSettings (per-reader) when open',
        () async {
      final db = HibikiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      MediaSource.setDatabase(db);

      final source = ReaderHibikiSource.instance;
      await source.refreshPreferencesFromDb();

      final ReaderSettings perBook = ReaderSettings(db);
      await perBook.refreshFromDb();
      ReaderHibikiSource.readerSettings = perBook;

      expect(source.topProgressPosition, 'center');

      source.setTopProgressPosition('left');
      await Future<void>.delayed(Duration.zero);
      expect(perBook.topProgressPosition, 'left');
      expect(source.topProgressPosition, 'left');
      // per-reader path: ReaderSettings._set uses value.toString() ('left'),
      // not the source PrefCodec ('s:left').
      expect(
        await db.getPref('src:reader_ttu:top_progress_position'),
        'left',
      );
    });

    test('two books do not cross-contaminate', () async {
      final dbA = HibikiDatabase.forTesting(NativeDatabase.memory());
      final dbB = HibikiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(dbA.close);
      addTearDown(dbB.close);

      final ReaderSettings bookA = ReaderSettings(dbA);
      final ReaderSettings bookB = ReaderSettings(dbB);
      await bookA.refreshFromDb();
      await bookB.refreshFromDb();

      await bookA.setTopProgressPosition('right');
      expect(bookA.topProgressPosition, 'right');
      expect(bookB.topProgressPosition, 'center',
          reason: 'per-reader pref must not leak across books');
    });
  });
}
