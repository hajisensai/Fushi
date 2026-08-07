import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/media/video/video_book_repository.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/platform/platform_services.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/fake_anki_repository.dart';
import '../helpers/test_platform_services.dart';

void main() {
  testWidgets('missing book resolves to error state, not a stuck loader',
      (WidgetTester tester) async {
    final FushiDatabase db =
        FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final PlatformServices platformServices = testPlatformServices();
    final AppModel appModel = AppModel(platformServices)
      ..wireDatabaseForTesting(db);
    final FakeAnkiRepository ankiRepository = FakeAnkiRepository();
    await tester.pumpWidget(ProviderScope(
      overrides: <Override>[
        platformServicesProvider.overrideWithValue(platformServices),
        ankiRepositoryProvider.overrideWithValue(ankiRepository),
        appProvider.overrideWith((ref) => appModel),
      ],
      child: MaterialApp(
        home: VideoFushiPage(
          bookUid: 'video/none',
          repo: VideoBookRepository(db),
        ),
      ),
    ));
    // Let _init() complete (getByBookUid → null → error state).
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}
