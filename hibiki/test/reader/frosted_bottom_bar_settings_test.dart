import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/src/reader/reader_settings.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// TODO-1168（实验性）：悬浮底栏毛玻璃 + 半透明配置项的守卫。
/// - 默认关闭 + 默认不透明度 0.6（关闭时底栏行为完全同现状，零回归）。
/// - 不透明度经 [ReaderSettings.normalizeBottomBarOpacity] 归一夹在 [0.15, 1.0]。
/// - per-reader 分层：ReaderSettings ⟺ ReaderHibikiSource 读同一 key、值一致。
HibikiDatabase _testDb() =>
    HibikiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

void main() {
  group('bottom-bar opacity normalization (TODO-1168)', () {
    test('clamps below floor / above ceiling and default-on-NaN', () {
      expect(ReaderSettings.normalizeBottomBarOpacity(0.0), 0.15);
      expect(ReaderSettings.normalizeBottomBarOpacity(-1.0), 0.15);
      expect(ReaderSettings.normalizeBottomBarOpacity(2.0), 1.0);
      expect(ReaderSettings.normalizeBottomBarOpacity(0.6), 0.6);
      expect(ReaderSettings.normalizeBottomBarOpacity(double.nan), 0.6);
      expect(ReaderSettings.normalizeBottomBarOpacity(double.infinity), 0.6);
    });
  });

  group('frosted bottom bar setting (TODO-1168)', () {
    late HibikiDatabase db;

    setUp(() {
      db = _testDb();
      MediaSource.setDatabase(db);
      ReaderHibikiSource.readerSettings = null;
    });

    tearDown(() async {
      ReaderHibikiSource.readerSettings = null;
      await db.close();
    });

    test('frosted defaults to false and opacity to 0.6 (zero regression)',
        () async {
      final ReaderSettings settings = ReaderSettings(db);
      await settings.refreshFromDb();

      expect(settings.frostedBottomBar, isFalse);
      expect(settings.bottomBarOpacity, 0.6);
      expect(ReaderHibikiSource.instance.frostedBottomBar, isFalse);
      expect(ReaderHibikiSource.instance.bottomBarOpacity, 0.6);
    });

    test('frosted toggle persists through ReaderSettings', () async {
      final ReaderSettings settings = ReaderSettings(db);
      await settings.refreshFromDb();
      await settings.setFrostedBottomBar(true);

      final ReaderSettings restored = ReaderSettings(db);
      await restored.refreshFromDb();
      expect(restored.frostedBottomBar, isTrue);
    });

    test('opacity persists and is renormalized on read', () async {
      final ReaderSettings settings = ReaderSettings(db);
      await settings.refreshFromDb();
      await settings.setBottomBarOpacity(3.0); // out of range -> clamps to 1.0

      final ReaderSettings restored = ReaderSettings(db);
      await restored.refreshFromDb();
      expect(restored.bottomBarOpacity, 1.0);
    });

    test('uses independent per-reader keys', () async {
      final ReaderSettings settings = ReaderSettings(db);
      await settings.refreshFromDb();
      await settings.setFrostedBottomBar(true);
      await settings.setBottomBarOpacity(0.4);

      final Map<String, String> prefs = await db.getAllPrefs();
      expect(prefs.containsKey('src:reader_ttu:frosted_bottom_bar'), isTrue);
      expect(prefs.containsKey('src:reader_ttu:bottom_bar_opacity'), isTrue);
    });
  });
}
