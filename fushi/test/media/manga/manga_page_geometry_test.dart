import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/manga/manga_page_geometry.dart';
import 'package:fushi/src/media/manga/manga_reader_preferences.dart';

void main() {
  test('all six scale modes produce deterministic dimensions', () {
    const double w = 1000;
    const double h = 1500;
    const double vw = 800;
    const double vh = 800;
    const MangaPageGeometry fit = MangaPageGeometry(
      imageWidth: w,
      imageHeight: h,
      viewportWidth: vw,
      viewportHeight: vh,
    );
    expect(fit.displayedWidth, closeTo(533.3333333333334, 0.0001));
    expect(fit.displayedHeight, 800);
    expect(
      const MangaPageGeometry(
        imageWidth: w,
        imageHeight: h,
        viewportWidth: vw,
        viewportHeight: vh,
        scaleType: MangaScaleType.fitWidth,
      ).displayedWidth,
      vw,
    );
    expect(
      const MangaPageGeometry(
        imageWidth: w,
        imageHeight: h,
        viewportWidth: vw,
        viewportHeight: vh,
        scaleType: MangaScaleType.fitHeight,
      ).displayedHeight,
      vh,
    );
    expect(
      const MangaPageGeometry(
        imageWidth: w,
        imageHeight: h,
        viewportWidth: vw,
        viewportHeight: vh,
        scaleType: MangaScaleType.original,
      ).displayedWidth,
      w,
    );
    expect(
      const MangaPageGeometry(
        imageWidth: w,
        imageHeight: h,
        viewportWidth: vw,
        viewportHeight: vh,
        scaleType: MangaScaleType.stretch,
      ).displayedHeight,
      vh,
    );
    expect(
      const MangaPageGeometry(
        imageWidth: w,
        imageHeight: h,
        viewportWidth: vw,
        viewportHeight: vh,
        scaleType: MangaScaleType.smart,
      ).scale,
      fit.scale,
    );
  });

  test('rotation maps points round trip', () {
    const MangaPageGeometry geometry = MangaPageGeometry(
      imageWidth: 100,
      imageHeight: 200,
      viewportWidth: 400,
      viewportHeight: 400,
      rotateQuarterTurns: 1,
    );
    final MangaViewportPoint viewport = geometry.imageToViewport(20, 40);
    final MangaImagePoint image = geometry.viewportToImage(
      viewport.x,
      viewport.y,
    );
    expect(image.x, closeTo(20, 0.0001));
    expect(image.y, closeTo(40, 0.0001));
  });

  test('crop borders uses cover scale and clamps source coordinates', () {
    const MangaPageGeometry geometry = MangaPageGeometry(
      imageWidth: 1000,
      imageHeight: 500,
      viewportWidth: 500,
      viewportHeight: 500,
      cropBorders: true,
    );
    expect(geometry.scale, 1);
    final MangaImagePoint point = geometry.viewportToImage(0, 0);
    expect(point.x, 250);
    expect(point.y, 0);
  });
}
