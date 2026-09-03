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

  testWidgets('成功发布新预设后同一个品牌位立即切换 ImageProvider', (WidgetTester tester) async {
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
      const AppIconSelection(presetKey: 'hibiki_full'),
    );
    await tester.pump();

    image = tester.widget<Image>(find.byType(Image));
    expect(
      (image.image as AssetImage).assetName,
      presetIconAssets['hibiki_full'],
    );
    expect((image.key! as ValueKey<int>).value, greaterThan(initialRevision));
  });
}
