import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/pages/implementations/floating_dict_page.dart';
import 'package:hibiki/src/utils/components/hibiki_material_components.dart';

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
          appProvider.overrideWith((ref) => AppModel()),
        ],
        child: const MaterialApp(
          home: FloatingDictPage(
            channel: MethodChannel('hibiki.test/floating'),
          ),
        ),
      ),
    );

    expect(find.byType(HibikiOverlayScaffold), findsOneWidget);
    expect(find.byType(HibikiPopupSurface), findsOneWidget);
    expect(find.byType(HibikiCompactSearchRow), findsOneWidget);
  });
}
