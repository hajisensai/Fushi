import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_reading_mode.dart';
import 'package:fushi/src/media/manga/mokuro_payload.dart';

MokuroImage _img(double w, double h) =>
    MokuroImage(url: 'p', size: Size(w, h), blocks: const <MokuroBlock>[]);

void main() {
  group('detectReadingMode', () {
    test('threshold constant initial value is 2.0', () {
      expect(kWebtoonAspectThreshold, 2.0);
    });

    test('typical manga spread pages (ratio < 2) => spread', () {
      // 1200x1700 => ratio ~1.42 (< 2.0)
      final MokuroPayload payload = MokuroPayload(
        images: <MokuroImage>[
          _img(1200, 1700),
          _img(1200, 1700),
          _img(1200, 1700),
        ],
      );
      expect(detectReadingMode(payload), MangaReadingMode.spread);
    });

    test('tall webtoon strips (ratio > 2) => webtoon', () {
      // 800x4000 => ratio 5.0 (> 2.0)
      final MokuroPayload payload = MokuroPayload(
        images: <MokuroImage>[
          _img(800, 4000),
          _img(800, 4000),
        ],
      );
      expect(detectReadingMode(payload), MangaReadingMode.webtoon);
    });

    test('uses median so a single outlier does not flip the result', () {
      // ratios: 1.42, 1.42, 1.42, 10.0 => median of 4 = avg of 1.42 & 1.42
      final MokuroPayload payload = MokuroPayload(
        images: <MokuroImage>[
          _img(1200, 1700),
          _img(1200, 1700),
          _img(1200, 1700),
          _img(800, 8000),
        ],
      );
      expect(detectReadingMode(payload), MangaReadingMode.spread);
    });

    test('boundary: ratio exactly at threshold => spread (not > threshold)',
        () {
      // 1000x2000 => ratio exactly 2.0; 2.0 is NOT > 2.0
      final MokuroPayload payload = MokuroPayload(
        images: <MokuroImage>[_img(1000, 2000)],
      );
      expect(detectReadingMode(payload), MangaReadingMode.spread);
    });

    test('even page count median averages the two middle ratios', () {
      // ratios sorted: 1.5, 1.5, 3.0, 3.0 => median = (1.5 + 3.0)/2 = 2.25 > 2.0
      final MokuroPayload payload = MokuroPayload(
        images: <MokuroImage>[
          _img(1000, 1500),
          _img(1000, 1500),
          _img(1000, 3000),
          _img(1000, 3000),
        ],
      );
      expect(detectReadingMode(payload), MangaReadingMode.webtoon);
    });

    test('skips zero-width pages to avoid divide-by-zero', () {
      final MokuroPayload payload = MokuroPayload(
        images: <MokuroImage>[
          _img(0, 1700),
          _img(800, 4000),
        ],
      );
      // Only the valid 800x4000 page counts => ratio 5.0 => webtoon
      expect(detectReadingMode(payload), MangaReadingMode.webtoon);
    });

    test('empty / all-invalid payload falls back to spread', () {
      expect(
        detectReadingMode(const MokuroPayload(images: <MokuroImage>[])),
        MangaReadingMode.spread,
      );
      expect(
        detectReadingMode(
          MokuroPayload(images: <MokuroImage>[_img(0, 0)]),
        ),
        MangaReadingMode.spread,
      );
    });
  });
}
