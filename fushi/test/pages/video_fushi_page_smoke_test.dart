import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/platform/platform_services.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/fake_anki_repository.dart';
import '../helpers/video_quick_settings_harness.dart';

void main() {
  testWidgets('missing book resolves to error state, not a stuck loader', (
    WidgetTester tester,
  ) async {
    // 生产里 AppModel.initialise() 先装好 prefsRepo 才有任何页面；视频页与加载并行解析
    // 作品配置后会读生效的字幕样式（appModel.videoSubtitleStyle），所以替身必须带偏好。
    final VideoSheetHarness harness = await VideoSheetHarness.create();
    addTearDown(harness.dispose);
    final FushiDatabase db = harness.db;
    final AppModel appModel = harness.appModel;
    final PlatformServices platformServices = appModel.platformServices;
    final FakeAnkiRepository ankiRepository = FakeAnkiRepository();
    await tester.pumpWidget(
      ProviderScope(
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
      ),
    );
    // Let _init() complete (getByBookUid → null → error state).
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}
