import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/floating_dict_page.dart';
import 'package:fushi/src/utils/components/hibiki_material_components.dart';

import '../helpers/test_platform_services.dart';

void main() {
  test('floating dictionary page compiles with shared popup chrome', () {
    expect(
      const FloatingDictPage(channel: MethodChannel('hibiki.test/floating')),
      isA<FloatingDictPage>(),
    );
  });

  testWidgets('floating dictionary page uses shared overlay popup shell',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appProvider.overrideWith((ref) => AppModel(testPlatformServices())),
        ],
        child: const MaterialApp(
          home: FloatingDictPage(
            channel: MethodChannel('hibiki.test/floating'),
          ),
        ),
      ),
    );

    expect(find.byType(FushiOverlayScaffold), findsOneWidget);
    expect(find.byType(FushiPopupSurface), findsOneWidget);
    expect(find.byType(FushiCompactSearchRow), findsOneWidget);
  });
}
