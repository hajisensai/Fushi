import 'dart:io';
import 'dart:ui' as ui;

import 'package:crop_image/crop_image.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/crop_image_dialog_page.dart';
import 'package:fushi/src/utils/misc/app_icon_preferences.dart';
import 'package:flutter/painting.dart';

/// BUG-3601：Android 自定义应用图标链路（选图 → 裁剪 → 原生建快捷方式）此前
/// 全程按原图分辨率走：裁剪框全分辨率解码、裁剪输出全分辨率 PNG、原生
/// `decodeByteArray` 再全分辨率解一次，且 `createCustomShortcut` 会在
/// `createScaledBitmap` 直接返回入参时把要交给启动器的那张图提前回收。
void main() {
  String read(String relative) {
    final File f = File(relative);
    expect(f.existsSync(), isTrue, reason: '缺失文件: $relative');
    return f.readAsStringSync().replaceAll('\r\n', '\n');
  }

  test('裁剪源图：给上限就按长边等比解码且不放大，不给就是原图', () {
    final File file = File('does-not-matter.png');
    expect(cropSourceImageProvider(file), isA<FileImage>());

    final ImageProvider<Object> bounded = cropSourceImageProvider(
      file,
      maxDimension: appIconSourceMaxPixels,
    );
    expect(bounded, isA<ResizeImage>());
    final ResizeImage resize = bounded as ResizeImage;
    expect(resize.width, appIconSourceMaxPixels);
    expect(resize.height, appIconSourceMaxPixels);
    expect(resize.policy, ResizeImagePolicy.fit);
    expect(resize.allowUpscaling, isFalse);
    expect(resize.imageProvider, isA<FileImage>());
  });

  test('图标源图上限够各端最大用量（Android 512 / Windows 256）', () {
    expect(appIconSourceMaxPixels, greaterThanOrEqualTo(512));
    expect(appIconSourceMaxPixels, lessThanOrEqualTo(2048));
  });

  testWidgets('裁剪输出按 maxSize 封顶（与对话框传的上限同一语义）', (WidgetTester tester) async {
    await tester.runAsync(() async {
      final ui.PictureRecorder recorder = ui.PictureRecorder();
      ui.Canvas(recorder).drawRect(
        const ui.Rect.fromLTWH(0, 0, 3000, 2000),
        ui.Paint()..color = const ui.Color(0xFF336699),
      );
      final ui.Image big = await recorder.endRecording().toImage(3000, 2000);
      final ui.Image out = await CropController.getCroppedBitmap(
        maxSize: 256,
        crop: const ui.Rect.fromLTWH(0, 0, 1, 1),
        rotation: CropRotation.up,
        image: big,
      );
      expect(out.width, lessThanOrEqualTo(256));
      expect(out.height, lessThanOrEqualTo(256));
      big.dispose();
      out.dispose();
    });
  });

  test('对话框把上限同时用于源图解码与裁剪输出；设置页传图标上限', () {
    final String dialog = read(
      'lib/src/pages/implementations/crop_image_dialog_page.dart',
    );
    expect(
      RegExp(
        r'cropSourceImageProvider\(\s*widget\.imageFile,\s*maxDimension:\s*widget\.maxDimension',
      ).hasMatch(dialog),
      isTrue,
      reason: '源图必须按上限解码，否则大图仍整张进内存',
    );
    expect(
      RegExp(
        r'croppedBitmap\(\s*maxSize:\s*widget\.maxDimension',
      ).hasMatch(dialog),
      isTrue,
      reason: '裁剪输出必须按上限封顶，否则仍把原图尺寸 PNG 交给原生',
    );

    final String settings = read(
      'lib/src/pages/implementations/miscellaneous_settings_page.dart',
    );
    expect(
      RegExp(
        r'showCropImageDialog\([\s\S]*?maxDimension:\s*appIconSourceMaxPixels',
      ).hasMatch(settings),
      isTrue,
      reason: '应用图标裁剪必须带上限',
    );
  });

  test('原生 createCustomShortcut 降采样解码，且不回收要交给启动器的图', () {
    final String java = read(
      'android/app/src/main/java/app/fushi/reader/IconSwitchHelper.java',
    );
    final int start = java.indexOf(
      'public static boolean createCustomShortcut',
    );
    expect(start, isNonNegative);
    final String body = java.substring(start);

    expect(body, contains('inJustDecodeBounds = true'));
    expect(
      RegExp(r'inSampleSize\s*=\s*iconDecodeSampleSize\(').hasMatch(body),
      isTrue,
      reason: '必须按目标边长降采样解码',
    );
    // createScaledBitmap 无需缩放时返回入参本身；无条件 original.recycle()
    // 会把 scaled 一起回收，交给启动器的是一张已回收的图。
    expect(
      RegExp(r'^\s*original\.recycle\(\);', multiLine: true).hasMatch(body),
      isFalse,
      reason: 'original 可能就是 scaled，不能无条件回收',
    );
    expect(body, contains('if (original != scaled) original.recycle();'));
    expect(
      body,
      contains(
        'if (cropped != original && cropped != scaled) cropped.recycle();',
      ),
    );
  });
}
