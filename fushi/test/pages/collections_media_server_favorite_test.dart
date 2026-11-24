import 'dart:io';

import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/collections_page.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

/// BUG-5379：从媒体服务器浏览页直接串流（没「加入媒体库」）时收藏的视频句，
/// bookKey 是服务器条目 id、本机没有 `video_books` 行。旧实现在收藏夹里点这一行
/// `getByBookUid` 得 null 就静默 return——用户看到的是「点了没反应」。
///
/// 现在没有库行时先到已登录的媒体服务器上找（`resolveMediaServerItemLaunch`，
/// 单测见 media_server_item_launch_test.dart）；哪台都没有时必须给出提示。本测试
/// pump 真 CollectionsPage（范式照抄 collections_page_source_kind_test.dart），不登录
/// 任何服务器，点那一行，断言出现「来源不可用 / 请登录服务器」提示。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir = Directory.systemTemp.createTempSync(
      'fushi_collections_ms_fav_pp',
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async => pathProviderDir.path,
    );
  });
  tearDownAll(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (pathProviderDir.existsSync()) {
      pathProviderDir.deleteSync(recursive: true);
    }
  });

  late FushiDatabase db;
  late AppModel appModel;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    appModel = AppModel(testPlatformServices())..wireDatabaseForTesting(db);
  });

  tearDown(() async {
    FushiToast.debugReset();
    await db.close();
  });

  testWidgets('tapping a streamed media-server favorite with no library row '
      'and no matching server shows a toast instead of doing nothing', (
    WidgetTester tester,
  ) async {
    await FavoriteSentenceRepository(db).add(
      FavoriteSentence(
        text: 'ストリームの文です。',
        bookTitle: 'JELLYFIN_EPISODE',
        createdAt: DateTime(2026, 11, 20, 10),
        // Jellyfin 条目 id（GUID），本机无对应 video_books 行。
        bookKey: '5f0c1a2b3c4d5e6f7a8b9c0d1e2f3a4b',
        normCharOffset: 61000,
        normCharLength: 2400,
        source: kFavoriteSentenceSourceVideo,
      ),
    );

    FushiToast.navigatorKey = appModel.navigatorKey;
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[appProvider.overrideWith((ref) => appModel)],
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: appModel.navigatorKey,
            home: const CollectionsPage(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('ストリームの文です。'), findsOneWidget);
    expect(find.text(t.video_favorite_source_unavailable), findsNothing);

    await tester.tap(find.text('ストリームの文です。'));
    await tester.pumpAndSettle();

    expect(find.text(t.video_favorite_source_unavailable), findsOneWidget);
    // 没有可打开的来源：不压任何新页面。
    expect(find.byType(CollectionsPage), findsOneWidget);

    // 让提示自己走完驻留，不留挂起的计时器。
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
  });
}
