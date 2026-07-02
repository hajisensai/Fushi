import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// TODO-1108 持久化守卫：`pause_on_lookup`（查词时暂停）默认值改为 **开**。
///
/// 这是有意的默认值变更（用户诉求）：未设过该开关的新用户/老用户查词时默认暂停。
/// 守卫两件事：
///  ① 未写过存储值时 `pauseOnLookup` 返回 true（新默认）。
///  ② Never-break-userspace —— 已显式设过（哪怕设为 false）的用户，其存储值被读取
///     覆盖默认，改默认值不翻转他们的显式选择（getPreference 存储值优先，
///     media_source.dart getPreference 命中 `_preferences[key] is T` 直接返回）。
void main() {
  group('pauseOnLookup default (TODO-1108)', () {
    test('defaults to true when never set', () async {
      final HibikiDatabase db =
          HibikiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      MediaSource.setDatabase(db);

      final ReaderHibikiSource source = ReaderHibikiSource.instance;
      await source.refreshPreferencesFromDb();

      expect(source.pauseOnLookup, isTrue, reason: '未设过时默认开启（TODO-1108 用户诉求）');
    });

    test('an explicit stored false wins over the new default (userspace)',
        () async {
      final HibikiDatabase db =
          HibikiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      MediaSource.setDatabase(db);

      final ReaderHibikiSource source = ReaderHibikiSource.instance;
      await source.refreshPreferencesFromDb();

      // 老用户曾显式关闭：写穿存储再从 DB 重载，模拟应用重启后的读取路径。
      await source.setPauseOnLookup(value: false);
      await source.refreshPreferencesFromDb();

      expect(source.pauseOnLookup, isFalse,
          reason: '显式设过的存储值必须覆盖默认，改默认值不得翻转老用户选择');
      expect(
        await db.getPref('src:reader_ttu:pause_on_lookup'),
        'b:false',
      );
    });

    test('an explicit stored true round-trips', () async {
      final HibikiDatabase db =
          HibikiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      MediaSource.setDatabase(db);

      final ReaderHibikiSource source = ReaderHibikiSource.instance;
      await source.refreshPreferencesFromDb();

      await source.setPauseOnLookup(value: true);
      await source.refreshPreferencesFromDb();

      expect(source.pauseOnLookup, isTrue);
      expect(
        await db.getPref('src:reader_ttu:pause_on_lookup'),
        'b:true',
      );
    });
  });
}
