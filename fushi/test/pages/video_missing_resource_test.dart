import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/media/video/video_book_repository.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/platform/platform_services.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/fake_anki_repository.dart';
import '../helpers/test_platform_services.dart';

/// TODO-897 widget 行为守卫：本地视频文件缺失（被移动/删除/盘未挂载）时，页面进入
/// 「资源缺失」态而**不是无限转圈**，并给出重新导入 / 删除条目动作（无真 libmpv）。
///
/// 缺失分支在 `controller.load` 之前短路（video_resource_check.dart），全程不碰
/// libmpv；故能在 widget 环境跑通真实 `_init → _loadSingle → _applyLoad` 链。
class _MissingTestAppModel extends AppModel {
  _MissingTestAppModel(PlatformServices platformServices, this._db)
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
    storeDir = Directory.systemTemp.createTempSync('hibiki_todo897');
    platformServices = testPlatformServices();
    ankiRepository = FakeAnkiRepository();
    appModel = _MissingTestAppModel(platformServices, db)
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

  final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();

  /// BUG-2229 用：把视频页 **push 在一个占位根路由之上**，这样 `Navigator.pop`
  /// 有东西可退——只有可退的路由栈才能验「返回按钮真的退得出去」。
  Widget wrapPushable() => ProviderScope(
        overrides: <Override>[
          platformServicesProvider.overrideWithValue(platformServices),
          ankiRepositoryProvider.overrideWithValue(ankiRepository),
          appProvider.overrideWith((ref) => appModel),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: navKey,
            home: const Scaffold(body: Text('shelf-placeholder')),
          ),
        ),
      );

  Widget wrap(String bookUid) => ProviderScope(
        overrides: <Override>[
          platformServicesProvider.overrideWithValue(platformServices),
          ankiRepositoryProvider.overrideWithValue(ankiRepository),
          appProvider.overrideWith((ref) => appModel),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            home: VideoFushiPage(
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
  //
  // `_init → _loadSingle → _relocateSingleMediaPaths → _applyLoad` 是一串**顺序**
  // 真实 IO await（getByBookUid / relocateMissingAppDocumentPath×N / loadCues /
  // isLocalVideoResourceMissing）。单个固定时长的 runAsync 窗口只能推进落在窗口内
  // 那几跳；末尾的 isLocalVideoResourceMissing 若被排到窗口关闭之后，后续假时钟
  // pump 不驱动真实 dart:io，missing 短路永不触发、spinner 残留（PR 在链中加了
  // relocateMissingAppDocumentPath 的额外真实 IO 跳数后，Windows 上恰好越窗）。
  // 故交替 runAsync + pump 多轮：每一段顺序真实 IO 都拿到自己的 real-async 窗口，
  // 直到 spinner 消失（缺失态落定）或轮数耗尽——与「链里有几跳 IO」解耦，不再脆弱。
  Future<void> drive(WidgetTester tester) async {
    for (int round = 0; round < 12; round++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump(const Duration(milliseconds: 50));
      if (find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
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
    // BUG-805：缺失态收敛成两个真按钮 [重新导入] [删除]（缺失正文 + 对话框都含此文案）。
    expect(find.text(t.video_resource_missing_reimport), findsWidgets);
    // 单视频（canDelete）提供「删除」。
    expect(find.text(t.dialog_delete), findsWidgets);

    // 卸载页面让其 dispose 干净跑完（appModel / prefs 由 GC 回收，不显式 dispose——
    // 页面生命周期已 dispose 关联监听，显式再 dispose 会触发 used-after-dispose）。
    await tester.pumpWidget(const SizedBox.shrink());
  });

  // BUG-2229：缺失态是**没有视频内顶栏**的（没有 controller ⇒ media_kit controls
  // 根本没挂载），本页又有意不挂 AppBar（BUG-102）。所以正文里的「返回」按钮是唯一
  // 退出入口；桌面端没有系统返回键，少了它用户进来就出不去。这条守卫盯的是「按钮
  // 存在且真的退得出去」，不是「文案长什么样」。
  testWidgets('missing state offers a working back button (BUG-2229)',
      (WidgetTester tester) async {
    const String missing = r'D:\does\not\exist\gone.mp4';
    await insertVideoBook(bookUid: 'video/missing-back', videoPath: missing);

    await tester.pumpWidget(wrapPushable());
    await tester.pump();
    unawaited(navKey.currentState!.push<void>(MaterialPageRoute<void>(
      builder: (BuildContext _) => VideoFushiPage(
        bookUid: 'video/missing-back',
        repo: VideoBookRepository(db),
      ),
    )));
    await tester.pump();
    await drive(tester);

    expect(find.byType(VideoFushiPage), findsOneWidget);

    // 首帧的缺失提示对话框盖在正文之上，先按它的「取消」落到缺失态正文
    // （对话框的 cancel 分支就是「停在缺失态」）。
    expect(find.text(t.dialog_cancel), findsOneWidget);
    await tester.tap(find.text(t.dialog_cancel));
    await drive(tester);

    // 正文里必须有返回入口——缺失态此时没有任何其它出口。
    final Finder backButton = find.widgetWithText(TextButton, t.back);
    expect(backButton, findsOneWidget);

    // 点它必须真的退出视频页，回到占位根路由。
    await tester.tap(backButton);
    await drive(tester);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(VideoFushiPage), findsNothing);
    expect(find.text('shelf-placeholder'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
