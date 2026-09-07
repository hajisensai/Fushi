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
import '../helpers/source_guard.dart';
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
  // 根本没挂载），本页又有意不挂 AppBar（BUG-102）。所以正文里的「返回」按钮是缺失态
  // 唯一**可见可点**的出口——鼠标用户在屏幕上找不到别的地方可按。
  // 它不是唯一的退出**路径**：PopScope 在 _buildScaffold 之外（系统返回键一直通），
  // globalBack 也被刻意分流在 controller == null 那道门之前（Esc / 手柄 B 一直通）。
  // 下面第二条用例把后者钉住，免得有人把那条分流当成多余删掉。
  // 这条守卫盯的是「按钮存在且真的退得出去」，不是「文案长什么样」。
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

    // 正文里必须有返回入口——鼠标用户在缺失态看得到的只有这一个。
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

  // 缺失态下 Esc 也必须退得出去 —— 这里用源码守卫，不是行为用例。
  //
  // 不变式本身成立：本页键盘主通道把 globalBack **刻意**分流在 `controller == null`
  // 那道门之前（加载态 / 缺失态下 controller 恒为 null，跟着整表被挡住就等于 Esc
  // 不再走本页阶梯）。但在 BUG-2229 之前没有任何测试钉它，而本 PR 的初稿注释还把它
  // 说成「不存在」——下一个人照注释办事，很可能把那条分流当多余删掉，删完全绿。
  //
  // 为什么不写成 widget 行为用例：本文件的 harness 是最小 MaterialApp，没有 app 根部
  // 的全局快捷键层，页面自身的 Focus 又是 canRequestFocus:false / skipTraversal，
  // 按键在这里根本没有接收者（实测：发 Esc 后页面仍在）。硬凑一个能收键的壳，测的
  // 就是那个壳而不是真接线。源码守卫是这条不变式在单测层最强的可落地形式。
  test('globalBack 必须分流在 controller == null 之前（缺失态/加载态的键盘出口）', () {
    final File f = File('lib/src/pages/implementations/video_fushi_page.dart');
    expect(f.existsSync(), isTrue, reason: '守卫目标文件不在了');
    final String src = maskComments(f.readAsStringSync());

    const String branch = 'if (action == ShortcutAction.globalBack) {';
    const String gate = 'if (controller == null) return false;';
    final int branchAt = src.indexOf(branch);
    final int gateAt = src.indexOf(gate);
    expect(branchAt, greaterThan(-1),
        reason: 'globalBack 的分流没了：缺失态/加载态下 Esc 会跟着整表被 controller '
            '门挡住，键盘和手柄都退不出去');
    expect(gateAt, greaterThan(-1), reason: 'controller 门改写了，守卫需更新');
    expect(branchAt, lessThan(gateAt),
        reason: 'globalBack 必须排在 controller == null 之前——它的执行体是本页的'
            '逐级退出阶梯，整条不碰播放器，没有理由被播放器就绪与否挡住');
  });
}
