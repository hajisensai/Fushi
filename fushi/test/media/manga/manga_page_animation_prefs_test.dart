import 'dart:convert';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_reader_preferences.dart';
import 'package:fushi/src/media/manga/manga_view_prefs.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_core/fushi_core.dart';

/// 漫画翻页动画并进共享的四选一（无 / 平移 / 覆盖 / 淡入淡出）后的偏好映射：
/// `manga_page_animation` 是唯一真相源，旧的 `animateTransitions` 只剩读出投影与
/// 旧数据迁移；速度 / 跟手是两把新的全局键。
void main() {
  group('mangaPageAnimationFromKey', () {
    test('四个合法值原样解析，未知值回落 slide', () {
      for (final MangaPageAnimation a in MangaPageAnimation.values) {
        expect(mangaPageAnimationFromKey(a.key), a);
      }
      expect(mangaPageAnimationFromKey('flip'), MangaPageAnimation.slide);
      expect(mangaPageAnimationFromKey(null), MangaPageAnimation.slide);
      expect(kMangaPageAnimationDefault, PageTurnAnimation.slide);
    });
  });

  group('PreferencesRepository 翻页动画', () {
    late FushiDatabase db;
    late PreferencesRepository prefs;

    setUp(() async {
      db = FushiDatabase.forTesting(
        DatabaseConnection(NativeDatabase.memory()),
      );
      prefs = PreferencesRepository(db);
      await prefs.loadFromDb();
    });

    tearDown(() => db.close());

    test('默认：平移、标准速度、跟手开', () {
      expect(prefs.mangaPageAnimation, 'slide');
      expect(prefs.mangaPageAnimationSpeed, 'normal');
      expect(prefs.mangaPageTurnFollowDrag, isTrue);
      expect(prefs.mangaReaderPreferences.animateTransitions, isTrue);
    });

    test('新增取值 cover 可存可读，未知落盘值读出 slide', () async {
      await prefs.setMangaPageAnimation('cover');
      expect(prefs.mangaPageAnimation, 'cover');
      await prefs.setPref('manga_page_animation', 'curl');
      expect(prefs.mangaPageAnimation, 'slide');
    });

    test('速度：未知值回落 normal，合法值原样', () async {
      await prefs.setMangaPageAnimationSpeed('slow');
      expect(prefs.mangaPageAnimationSpeed, 'slow');
      await prefs.setPref('manga_page_animation_speed', 'warp');
      expect(prefs.mangaPageAnimationSpeed, 'normal');
    });

    test('旧数据只有 animateTransitions=false（键从未写过）：迁移为 none', () async {
      await prefs.setPref(
        'manga_reader_preferences',
        jsonEncode(<String, Object?>{'animateTransitions': false}),
      );
      expect(prefs.mangaPageAnimation, 'none');
      expect(prefs.mangaReaderPreferences.animateTransitions, isFalse);
      // 旧 JSON 里 true / 缺失 → 默认平移。
      await prefs.setPref(
        'manga_reader_preferences',
        jsonEncode(<String, Object?>{'animateTransitions': true}),
      );
      expect(prefs.mangaPageAnimation, 'slide');
    });

    test('键写过就以键为准，旧 JSON 不再覆盖', () async {
      await prefs.setPref(
        'manga_reader_preferences',
        jsonEncode(<String, Object?>{'animateTransitions': false}),
      );
      await prefs.setMangaPageAnimation('fade');
      expect(prefs.mangaPageAnimation, 'fade');
      expect(prefs.mangaReaderPreferences.animateTransitions, isTrue);
    });

    test('整份写回阅读器偏好不会把四选一打回 slide / none', () async {
      await prefs.setMangaPageAnimation('cover');
      // 拿着旧对象（animateTransitions 投影 = true）整份写回。
      await prefs.setMangaReaderPreferences(prefs.mangaReaderPreferences);
      expect(prefs.mangaPageAnimation, 'cover');
      // 即便写回的是 animateTransitions=false（旧备份 / 旧面板），也不反写。
      await prefs.setMangaReaderPreferences(
        const MangaReaderPreferences(animateTransitions: false),
      );
      expect(prefs.mangaPageAnimation, 'cover');
    });
  });
}
