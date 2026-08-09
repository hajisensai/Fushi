import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_spread_model.dart';

void main() {
  group('resolveMangaPageLayout', () {
    test('auto：横屏双页、竖屏单页', () {
      expect(
        resolveMangaPageLayout(
          preference: MangaSpreadPreference.auto,
          isLandscape: true,
        ),
        MangaPageLayout.double,
      );
      expect(
        resolveMangaPageLayout(
          preference: MangaSpreadPreference.auto,
          isLandscape: false,
        ),
        MangaPageLayout.single,
      );
    });

    test('single / double 覆盖视口判定', () {
      for (final bool landscape in <bool>[true, false]) {
        expect(
          resolveMangaPageLayout(
            preference: MangaSpreadPreference.single,
            isLandscape: landscape,
          ),
          MangaPageLayout.single,
        );
        expect(
          resolveMangaPageLayout(
            preference: MangaSpreadPreference.double,
            isLandscape: landscape,
          ),
          MangaPageLayout.double,
        );
      }
    });
  });
}
