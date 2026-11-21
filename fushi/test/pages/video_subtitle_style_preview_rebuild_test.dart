// video-36f：设置面板的字幕样式滑条每个采样都经 [VideoQuickSettingsHost.onSubtitleStylePreview]
// 发给播放页，原先那里 `setState` 整页重建（控制条、侧栏、浮层全部重算）。改成
// `ValueNotifier`，只有字幕 overlay 经 `ValueListenableBuilder` 订阅。
//
// 钉子（经真实开页路径 + 页面交给设置面板的同一份能力槽）：
// - 预览一次样式，播放页 State 的 element 不重建，样式快照已更新；
// - 定稿（commit）落偏好、更新快照，同样不靠整页 setState。
import 'dart:io';

import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/media/video/video_quick_settings_host.dart';
import 'package:fushi/src/media/video/video_subtitle_style.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/platform/platform_services.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';

import '../helpers/fake_anki_repository.dart';
import '../helpers/test_platform_services.dart';

class _TestAppModel extends AppModel {
  _TestAppModel(PlatformServices platformServices, this._db)
    : super(platformServices);

  final FushiDatabase _db;

  @override
  double get appUiScale => 1.0;

  @override
  FushiDatabase get database => _db;
}

void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late FushiDatabase db;
  late PreferencesRepository prefs;
  late Directory storeDir;
  late PlatformServices platformServices;
  late FakeAnkiRepository ankiRepository;
  late AppModel appModel;

  setUpAll(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async => Directory.systemTemp.path,
    );
  });

  tearDownAll(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
  });

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    storeDir = Directory.systemTemp.createTempSync('fushi_video_sub_style');
    platformServices = testPlatformServices();
    ankiRepository = FakeAnkiRepository();
    appModel = _TestAppModel(platformServices, db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
  });

  tearDown(() async {
    await db.close();
    try {
      if (storeDir.existsSync()) storeDir.deleteSync(recursive: true);
    } on FileSystemException {
      // 失败态页面可能还握着句柄（Windows），留给系统临时目录回收。
    }
  });

  Widget wrap(Widget page) => ProviderScope(
    overrides: <Override>[
      platformServicesProvider.overrideWithValue(platformServices),
      ankiRepositoryProvider.overrideWithValue(ankiRepository),
      appProvider.overrideWith((ref) => appModel),
    ],
    child: TranslationProvider(child: MaterialApp(home: page)),
  );

  /// 开一个不存在的视频页、等它越过载入（落到失败态，页面 State 稳定）。
  Future<VideoFushiTestHooks> openPage(WidgetTester tester) async {
    await tester.pumpWidget(
      wrap(VideoFushiPage(bookUid: 'missing', repo: VideoBookRepository(db))),
    );
    final VideoFushiTestHooks hooks =
        tester.state(find.byType(VideoFushiPage)) as VideoFushiTestHooks;
    for (int round = 0; round < 30; round++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump(const Duration(milliseconds: 20));
    }
    return hooks;
  }

  /// 在 [body] 期间统计播放页 element 的重建次数。
  Future<int> countPageRebuilds(
    WidgetTester tester,
    Future<void> Function() body,
  ) async {
    int rebuilds = 0;
    final RebuildDirtyWidgetCallback? previous = debugOnRebuildDirtyWidget;
    debugOnRebuildDirtyWidget = (Element element, bool builtOnce) {
      if (element.widget is VideoFushiPage) rebuilds++;
    };
    try {
      await body();
      await tester.pump();
      await tester.pump();
    } finally {
      debugOnRebuildDirtyWidget = previous;
    }
    return rebuilds;
  }

  testWidgets('滑条预览字幕样式不整页重建，快照即时更新', (WidgetTester tester) async {
    final VideoFushiTestHooks hooks = await openPage(tester);
    final VideoQuickSettingsHost host = hooks.debugQuickSettingsHost();
    final VideoSubtitleStyle next = hooks.debugSubtitleStyle.copyWith(
      fontSize: hooks.debugSubtitleStyle.fontSize + 7,
    );

    final int rebuilds = await countPageRebuilds(tester, () async {
      // 模拟一次拖动里的多个采样。
      for (int i = 0; i < 5; i++) {
        host.onSubtitleStylePreview(next.copyWith(fontSize: next.fontSize + i));
      }
    });

    expect(rebuilds, 0, reason: '预览只该重建字幕 overlay，不该 setState 整个播放页');
    expect(hooks.debugSubtitleStyle.fontSize, next.fontSize + 4);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('定稿落偏好并更新快照，不整页重建', (WidgetTester tester) async {
    final VideoFushiTestHooks hooks = await openPage(tester);
    final VideoQuickSettingsHost host = hooks.debugQuickSettingsHost();
    final VideoSubtitleStyle next = hooks.debugSubtitleStyle.copyWith(
      bottomPadding: hooks.debugSubtitleStyle.bottomPadding + 11,
    );

    final int rebuilds = await countPageRebuilds(tester, () async {
      await tester.runAsync(() => host.onSubtitleStyleCommit(next));
    });

    expect(rebuilds, 0);
    expect(hooks.debugSubtitleStyle.bottomPadding, next.bottomPadding);
    expect(
      VideoSubtitleStyle.decode(appModel.videoSubtitleStyle).bottomPadding,
      next.bottomPadding,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
