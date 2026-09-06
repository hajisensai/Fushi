import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/current_app_icon.dart';
import 'package:fushi/src/utils/misc/app_icon_preferences.dart';

void main() {
  setUp(() {
    currentAppIconSelection.value = const AppIconSelection(
      presetKey: 'default',
    );
  });

  testWidgets('成功发布新选择后同一个品牌位立即切换 ImageProvider', (WidgetTester tester) async {
    // 预设只剩 default 一档，换档已无法触发重建；改用自定义图标走同一条发布路径，
    // 断言的仍是原不变式：品牌位监听 currentAppIconSelection，一发布就换 provider
    // 并 bump key（key 不变则 Flutter 会复用旧 element 和旧解码结果）。
    // 必须用同步版：testWidgets 跑在 FakeAsync 时区里，await 真实文件 I/O 的
    // Future 永远等不到完成（表现为用例 10 分钟超时）。
    final Directory tempDir = Directory.systemTemp.createTempSync(
      'current_app_icon_test',
    );
    addTearDown(() => tempDir.deleteSync(recursive: true));
    final File customIcon = File('${tempDir.path}/custom.png')
      ..writeAsBytesSync(<int>[0x89, 0x50, 0x4E, 0x47]);

    await tester.pumpWidget(
      const MaterialApp(
        home: Center(
          child: SizedBox.square(dimension: 48, child: CurrentAppIcon()),
        ),
      ),
    );

    Image image = tester.widget<Image>(find.byType(Image));
    expect((image.image as AssetImage).assetName, presetIconAssets['default']);
    final int initialRevision = (image.key! as ValueKey<int>).value;

    await publishAppIconSelection(
      AppIconSelection(presetKey: customIconKey, customPath: customIcon.path),
    );
    await tester.pump();

    image = tester.widget<Image>(find.byType(Image));
    final ResizeImage resized = image.image as ResizeImage;
    expect((resized.imageProvider as FileImage).file.path, customIcon.path);
    expect(resized.width, appIconDecodePixelWidth);
    expect((image.key! as ValueKey<int>).value, greaterThan(initialRevision));
  });

  testWidgets('已下线的老预设 key 回落到 default 的 asset，不画空图标', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(
          child: SizedBox.square(dimension: 48, child: CurrentAppIcon()),
        ),
      ),
    );

    // 老用户偏好里可能仍是 hibiki_full / hibiki_transparent，其 asset 已删除。
    currentAppIconSelection.value = const AppIconSelection(
      presetKey: 'hibiki_full',
      revision: 7,
    );
    await tester.pump();

    final Image image = tester.widget<Image>(find.byType(Image));
    expect((image.image as AssetImage).assetName, presetIconAssets['default']);
  });
}
