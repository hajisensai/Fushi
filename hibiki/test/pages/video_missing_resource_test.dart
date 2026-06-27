import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/media/video/video_book_repository.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki/src/pages/implementations/video_hibiki_page.dart';
import 'package:hibiki_core/hibiki_core.dart';

import '../helpers/test_platform_services.dart';

/// TODO-897 widget 行为守卫：本地视频文件缺失（被移动/删除/盘未挂载）时，页面进入
/// 「资源缺失」态而**不是无限转圈**，并给出重新导入 / 删除条目动作（无真 libmpv）。
///
/// 缺失分支在 `controller.load` 之前短路（video_resource_check.dart），全程不碰
/// libmpv；故能在 widget 环境跑通真实 `_init → _loadSingle → _applyLoad` 链。
class _MissingTestAppModel extends AppModel {
  _MissingTestAppModel() : super(testPlatformServices());

  @override
  double get appUiScale => 1.0;
}

void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late HibikiDatabase db;
  late PreferencesRepository prefs;
  late Directory storeDir;
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
    db = HibikiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    storeDir = Directory.systemTemp.createTempSync('hibiki_todo897');
    appModel = _MissingTestAppModel()
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
  });

  tearDown(() async {
    await db.close();
    if (storeDir.existsSync()) storeDir.deleteSync(recursive: true);
  });

  Future<void> insertVideoBook({
    required String bookUid,
    required String videoPath,
    String title = 'Missing Movie',
  }) async {
    await db.upsertVideoBook(VideoBooksCompanion(
      bookUid: Value(bookUid),
      title: Value(title),
      videoPath: Value(videoPath),
    ));
  }

  Widget wrap(String bookUid) => ProviderScope(
        overrides: <Override>[
          appProvider.overrideWith((ref) => appModel),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            home: VideoHibikiPage(
              bookUid: bookUid,
              repo: VideoBookRepository(db),
            ),
          ),
        ),
      );

  // 用 runAsync 驱动真实异步 IO（File.exists / getTemporaryDirectory / 目录扫描）——
  // `tester.pump` 只推假时钟、不推真 Future。视频页有控制条自动隐藏等周期定时器，
  // `pumpAndSettle` 等不到稳态会超时，故 runAsync 跑完 _init 异步链后用有界 pump
  // 落帧。缺失分支在 controller.load 之前短路，全程不碰 libmpv。
  Future<void> drive(WidgetTester tester) async {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    for (int i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('single video with non-existent path → missing state, no spinner',
      (WidgetTester tester) async {
    const String missing = r'D:\does\not\exist\gone.mp4';
    await insertVideoBook(bookUid: 'video/missing', videoPath: missing);

    await tester.pumpWidget(wrap('video/missing'));
    await drive(tester);

    // 关键：不停留在转圈。
    expect(find.byType(CircularProgressIndicator), findsNothing);
    // 缺失态正文图标（中性，非 generic error_outline）。
    expect(find.byIcon(Icons.video_file_outlined), findsWidgets);
    // 「重新导入」动作（缺失正文 + 对话框都含此文案）。
    expect(find.text(t.video_resource_missing_reimport), findsWidgets);

    // 卸载页面让其 dispose 干净跑完（appModel / prefs 由 GC 回收，不显式 dispose——
    // 页面生命周期已 dispose 关联监听，显式再 dispose 会触发 used-after-dispose）。
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
