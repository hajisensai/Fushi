import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/media_item_edit_dialog_page.dart';
import 'package:hibiki/src/utils/components/hibiki_material_components.dart';
import 'package:hibiki/src/utils/spacing.dart';
import 'package:transparent_image/transparent_image.dart';

void main() {
  Widget buildApp(Widget child) {
    return MaterialApp(
      builder: (context, appChild) => Spacing(
        dataBuilder: (context) => SpacingData.generate(10),
        child: appChild ?? const SizedBox.shrink(),
      ),
      home: Scaffold(body: Center(child: child)),
    );
  }

  testWidgets('media item cover field fits compact dialog content width', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 240);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      buildApp(
        SizedBox(
          width: 232,
          child: MediaItemCoverOverrideField(
            imageProvider: MemoryImage(kTransparentImage),
            onPickImage: null,
            onUndo: null,
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.byType(HibikiCard), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.byIcon(Icons.file_upload_outlined), findsOneWidget);
    expect(find.byIcon(Icons.undo_outlined), findsOneWidget);
  });

  testWidgets('media item edit dialog frame fits compact content', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 240);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      buildApp(
        MediaItemEditDialogFrame(
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(width: double.maxFinite, height: 1),
              const TextField(maxLines: null),
              MediaItemCoverOverrideField(
                imageProvider: MemoryImage(kTransparentImage),
                onPickImage: null,
                onUndo: null,
              ),
            ],
          ),
          actions: const [
            TextButton(onPressed: null, child: Text('Cancel')),
            TextButton(onPressed: null, child: Text('Save')),
          ],
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Save'), findsOneWidget);
  });
}
