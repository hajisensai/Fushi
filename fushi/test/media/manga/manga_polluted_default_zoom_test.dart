import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_view_prefs.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_core/fushi_core.dart';

/// BUG-2833：BUG-2782 之前页内捏合把 108%、113% 这种会话缩放回写成「默认缩放」，
/// 修了写入方之后存量坏值仍让 16:10 笔记本上「适应屏幕」装不下整页。设置滑块只写
/// 10 的倍数，读取端把非 10 倍数的存量值当作未设置。
void main() {
  group('normalizeStoredMangaZoomPercent', () {
    test('非 10 倍数的存量值只可能来自旧捏合回写，回到 100', () {
      for (final int polluted in <int>[108, 113, 97, 51, 399]) {
        expect(
          normalizeStoredMangaZoomPercent(polluted),
          100,
          reason: '$polluted',
        );
      }
    });

    test('设置滑块能写出的值原样保留', () {
      for (int v = kMangaZoomMinPercent; v <= kMangaZoomMaxPercent; v += 10) {
        expect(normalizeStoredMangaZoomPercent(v), v);
      }
    });

    test('越界的 10 倍数仍钳进合法范围', () {
      expect(normalizeStoredMangaZoomPercent(40), kMangaZoomMinPercent);
      expect(normalizeStoredMangaZoomPercent(500), kMangaZoomMaxPercent);
    });
  });

  group('PreferencesRepository.mangaZoomPercent', () {
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

    test('落盘的捏合坏值读出 100，开书按 100 起步', () async {
      await prefs.setPref('manga_zoom_percent', 108);
      expect(prefs.mangaZoomPercent, 100);
      expect(prefs.mangaReaderPreferences.zoomStart, 100);
    });

    test('设置里有意选的 120% 不受影响', () async {
      await prefs.setMangaZoomPercent(120);
      expect(prefs.mangaZoomPercent, 120);
      expect(prefs.mangaReaderPreferences.zoomStart, 120);
    });
  });
}
