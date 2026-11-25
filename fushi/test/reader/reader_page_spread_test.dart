import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_page_spread.dart';

/// 单双页判据（2026-11-07 「每页列数」改为自动 / 单页 / 双页）：横排双页 = 两栏，
/// 竖排双页 = 对开；「自动」看折叠屏折痕与窗口宽。
void main() {
  const Size phone = Size(400, 860);
  const Size phoneLandscape = Size(860, 400);
  const Size tabletLandscape = Size(1280, 800);
  const Size tabletPortrait = Size(800, 1280);
  // 折叠屏内屏展开接近正方形（如 Galaxy Z Fold 系列内屏约 880×920dp）。
  const Size foldInner = Size(880, 920);

  ReaderSpreadLayout resolve({
    ReaderPageSpread preference = ReaderPageSpread.auto,
    String viewMode = 'paginated',
    String writingMode = 'horizontal-tb',
    bool fold = false,
    Size window = phone,
  }) => resolveReaderSpreadLayout(
    preference: preference,
    viewMode: viewMode,
    writingMode: writingMode,
    hasFoldSpine: fold,
    window: window,
  );

  group('偏好值域与存量值', () {
    test('page_columns 0 / 1 / ≥2 → 自动 / 单页 / 双页（旧 3、4 栏归双页）', () {
      expect(ReaderPageSpread.fromStored(0), ReaderPageSpread.auto);
      expect(ReaderPageSpread.fromStored(-1), ReaderPageSpread.auto);
      expect(ReaderPageSpread.fromStored(1), ReaderPageSpread.single);
      expect(ReaderPageSpread.fromStored(2), ReaderPageSpread.double);
      expect(ReaderPageSpread.fromStored(3), ReaderPageSpread.double);
      expect(ReaderPageSpread.fromStored(4), ReaderPageSpread.double);
      for (final ReaderPageSpread v in ReaderPageSpread.values) {
        expect(ReaderPageSpread.fromStored(v.storedValue), v);
      }
    });
  });

  group('横排', () {
    test('双页 = 两栏，单页 = 一栏，与窗口无关', () {
      expect(
        resolve(preference: ReaderPageSpread.double),
        ReaderSpreadLayout.horizontalDouble,
      );
      expect(
        resolve(preference: ReaderPageSpread.single, window: tabletLandscape),
        ReaderSpreadLayout.single,
      );
      expect(
        resolve(preference: ReaderPageSpread.single, fold: true),
        ReaderSpreadLayout.single,
        reason: '用户显式单页就尊重用户，折叠屏也不强改',
      );
    });

    test('自动：宽屏横向窗口双页，手机（含横屏）与竖向平板单页', () {
      expect(resolve(window: tabletLandscape).isDouble, isTrue);
      expect(resolve(window: const Size(1920, 1080)).isDouble, isTrue);
      expect(resolve(window: phone).isDouble, isFalse);
      expect(resolve(window: phoneLandscape).isDouble, isFalse);
      expect(resolve(window: tabletPortrait).isDouble, isFalse);
      expect(
        resolve(window: const Size(kReaderAutoSpreadMinWindowWidth, 700)),
        ReaderSpreadLayout.horizontalDouble,
      );
    });

    test('自动：窗口有竖向折痕（书本姿态 / 展开内屏）就双页，不论宽高', () {
      expect(
        resolve(fold: true, window: foldInner),
        ReaderSpreadLayout.horizontalDouble,
      );
      expect(resolve(window: foldInner).isDouble, isFalse);
    });
  });

  group('竖排', () {
    test('双页 = 对开（不是上下两段）', () {
      final ReaderSpreadLayout layout = resolve(
        preference: ReaderPageSpread.double,
        writingMode: 'vertical-rl',
      );
      expect(layout, ReaderSpreadLayout.verticalDouble);
      expect(layout.columns, 1, reason: '竖排不再发 column-count:2（上下两段）');
      expect(layout.verticalSpread, isTrue);
    });

    test('自动：默认单页，宽屏也单页；只有折叠屏折痕才对开', () {
      expect(
        resolve(writingMode: 'vertical-rl', window: tabletLandscape),
        ReaderSpreadLayout.single,
      );
      expect(
        resolve(writingMode: 'vertical-lr', window: const Size(1920, 1080)),
        ReaderSpreadLayout.single,
      );
      expect(
        resolve(writingMode: 'vertical-rl', fold: true, window: foldInner),
        ReaderSpreadLayout.verticalDouble,
      );
    });
  });

  test('滚动 / VN 恒单页（没有「页」）', () {
    for (final String mode in <String>['continuous', 'vn']) {
      for (final String wm in <String>['horizontal-tb', 'vertical-rl']) {
        expect(
          resolve(
            preference: ReaderPageSpread.double,
            viewMode: mode,
            writingMode: wm,
            fold: true,
            window: tabletLandscape,
          ),
          ReaderSpreadLayout.single,
        );
      }
    }
  });
}
