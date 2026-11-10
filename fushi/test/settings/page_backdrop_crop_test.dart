import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/settings/settings_schema_page_backdrop.dart';
import 'package:material_ui/material_ui.dart';

/// 反馈 nYjjaLYlfn：自定义背景选完图后先裁剪再设为背景。
void main() {
  group('pageBackdropCropAspectRatio', () {
    test('横屏槽取屏幕长边 / 短边，与屏幕方向无关', () {
      expect(
        pageBackdropCropAspectRatio(const Size(1920, 1080), portrait: false),
        closeTo(1920 / 1080, 1e-9),
      );
      expect(
        pageBackdropCropAspectRatio(const Size(1080, 2400), portrait: false),
        closeTo(2400 / 1080, 1e-9),
      );
    });

    test('竖屏槽取短边 / 长边（宽 < 高，与背景层「高 > 宽用竖屏图」一致）', () {
      final double? landscapeDevice = pageBackdropCropAspectRatio(
        const Size(1920, 1080),
        portrait: true,
      );
      final double? portraitDevice = pageBackdropCropAspectRatio(
        const Size(1080, 2400),
        portrait: true,
      );
      expect(landscapeDevice, closeTo(1080 / 1920, 1e-9));
      expect(portraitDevice, closeTo(1080 / 2400, 1e-9));
      expect(landscapeDevice!, lessThan(1));
      expect(portraitDevice!, lessThan(1));
    });

    test('拿不到屏幕尺寸时自由裁剪', () {
      expect(pageBackdropCropAspectRatio(Size.zero, portrait: false), isNull);
      expect(
        pageBackdropCropAspectRatio(const Size(1920, 0), portrait: true),
        isNull,
      );
    });
  });

  group('pageBackdropCropMaxDimension', () {
    test('解码 / 输出长边封顶到屏幕物理长边（向上取整）', () {
      expect(pageBackdropCropMaxDimension(const Size(1080, 2400)), 2400);
      expect(pageBackdropCropMaxDimension(const Size(2559.5, 1600)), 2560);
    });

    test('拿不到屏幕尺寸时用原图', () {
      expect(pageBackdropCropMaxDimension(Size.zero), isNull);
    });
  });

  testWidgets('pageBackdropDisplaySize 返回非空的物理尺寸', (WidgetTester tester) async {
    late Size size;
    await tester.pumpWidget(
      Builder(
        builder: (BuildContext context) {
          size = pageBackdropDisplaySize(context);
          return const SizedBox.shrink();
        },
      ),
    );
    expect(size.isEmpty, isFalse);
  });

  test('选图链路：选完先走裁剪框，导入的是裁剪结果，取消裁剪不导入', () {
    final String source = File(
      'lib/src/settings/settings_schema_page_backdrop.dart',
    ).readAsStringSync().replaceAll('\r\n', '\n');
    final int start = source.indexOf('Future<void> pickPageBackdropImage(');
    expect(start, isNonNegative);
    final int end = source.indexOf('\n}\n', start);
    final String body = source.substring(start, end);

    final int pick = body.indexOf('pickGalleryImageFile()');
    final int crop = body.indexOf('showCropImageDialog(');
    final int importGlobal = body.indexOf('importPageBackdropImage(');
    final int importModule = body.indexOf('importPageBackdropModuleImage(');
    expect(pick, isNonNegative);
    expect(crop, greaterThan(pick), reason: '选完图要先弹裁剪框');
    expect(importGlobal, greaterThan(crop));
    expect(importModule, greaterThan(crop));
    expect(body, contains('if (cropped == null) return;'));
    expect(body, contains('importPageBackdropImage(cropped,'));
    expect(body, contains('        cropped,\n'));
    expect(body, isNot(contains('importPageBackdropImage(picked')));
  });
}
