import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/media/video/video_book_repository.dart';
import 'package:fushi/src/media/video/video_library_section.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/home_video_page.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/platform/platform_services.dart';
import 'package:fushi/src/utils/app_ui_scale.dart';
import 'package:fushi/src/utils/components/fushi_hover_lift.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_anki_repository.dart';
import '../helpers/test_platform_services.dart';

/// BUG-2124：视频墙格用鼠标滚轮滚动时，[FushiHoverLift] 的悬停放大残留在**已经
/// 滚走的那张卡**上（用户原话「另一个地方的卡片呈现被鼠标选中的样式」）。
///
/// 修复前实测：滚一档后那张卡偏离指针 120px，仍在屏幕上保持放大 **8 帧 / 128ms**
/// （1.050 缓降到 1.003），同时指针底下的新卡才刚开始涨——滚动全程没有一张放大的
/// 卡跟指针对齐。
///
/// 判据必须读**渲染矩阵**而不是 `AnimatedScale.scale`：后者是动画目标值，1 帧就
/// 归位，正是它把这个 bug 藏了整整 8 帧（先写的目标值版用例全绿，是空壳）。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir =
        Directory.systemTemp.createTempSync('fushi_wall_hover_pp');
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
      try {
        pathProviderDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  late FushiDatabase db;
  late PreferencesRepository prefs;
  late PlatformServices platformServices;
  late FakeAnkiRepository ankiRepository;
  late AppModel appModel;
  late Directory storeDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    LocaleSettings.setLocale(AppLocale.zhCn);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    storeDir = Directory.systemTemp.createTempSync('fushi_wall_hover_store');
    platformServices = testPlatformServices();
    ankiRepository = FakeAnkiRepository();
    appModel = AppModel(platformServices)
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
  });

  tearDown(() async {
    await db.close();
    if (storeDir.existsSync()) {
      storeDir.deleteSync(recursive: true);
    }
  });

  Widget buildApp(VideoLibrarySection section, {double uiScale = 1.0}) {
    final Widget page = Scaffold(
      body: HomeVideoPage(
        repo: VideoBookRepository(db),
        section: section,
      ),
    );
    return ProviderScope(
      overrides: <Override>[
        platformServicesProvider.overrideWithValue(platformServices),
        ankiRepositoryProvider.overrideWithValue(ankiRepository),
        appProvider.overrideWith((ref) => appModel),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          home: uiScale == 1.0
              ? page
              : FushiAppUiScale(scale: uiScale, child: page),
        ),
      ),
    );
  }

  Future<void> seedMany(int count) async {
    for (int i = 0; i < count; i++) {
      await db.upsertVideoBook(
        VideoBooksCompanion(
          bookUid: Value<String>('video/w$i'),
          title: Value<String>('Wall Show $i'),
          videoPath: Value<String>('/abs/wall_$i.mp4'),
          lastPositionMs: const Value<int>(60000),
        ),
      );
    }
  }

  /// 当前**屏幕上真的被放大**的卡（读缩放层 [Transform] 的实际矩阵，含缓动中间
  /// 值），而不是动画目标值——目标值 1 帧就归位，正是它把这个 bug 藏了 8 帧。
  List<Rect> visuallyLifted(WidgetTester tester) {
    final Finder lifts = find.byType(FushiHoverLift);
    final List<Rect> out = <Rect>[];
    for (int i = 0; i < lifts.evaluate().length; i++) {
      final Finder one = lifts.at(i);
      final Finder inner = find.descendant(
        of: one,
        matching: find.byType(Transform),
      );
      if (inner.evaluate().isEmpty) continue;
      final double sx =
          tester.widget<Transform>(inner.first).transform.getMaxScaleOnAxis();
      // 1.001 的门限只滤浮点噪声：真实抬升是 1.05，缓动尾巴也远在其上。
      if (sx > 1.001) out.add(tester.getRect(one));
    }
    return out;
  }

  /// 停在视口下半部的一张卡的中心（滚动后它会往上跑，指针不动）。
  Offset pickPointer(WidgetTester tester) {
    final Finder anyLift = find.byType(FushiHoverLift);
    expect(anyLift, findsWidgets, reason: '墙格必须有悬停壳');
    for (int i = 0; i < anyLift.evaluate().length; i++) {
      final Rect r = tester.getRect(anyLift.at(i));
      if (r.center.dy > 350 && r.center.dy < 650) return r.center;
    }
    fail('需要一张视口下半部的卡');
  }

  Future<void> runScrollCase(
    WidgetTester tester,
    VideoLibrarySection section, {
    double uiScale = 1.0,
  }) async {
    await seedMany(40);
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(buildApp(section, uiScale: uiScale));
    await tester.pumpAndSettle();

    final Offset pointerPos = pickPointer(tester);
    final TestPointer pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(pointer.hover(pointerPos));
    await tester.pumpAndSettle();

    expect(
      visuallyLifted(tester).length,
      1,
      reason: '悬停后应恰好一张卡放大',
    );
    expect(visuallyLifted(tester).single.contains(pointerPos), isTrue);

    final ScrollableState scrollable = tester.state<ScrollableState>(
      find.byType(Scrollable).last,
    );
    final double pixelsBefore = scrollable.position.pixels;

    // 鼠标一动不动，只滚滚轮；滚轮补间（kDesktopWheelScrollDuration 140ms）
    // 与抬升缓动（120ms）都在这些中间帧里，用户看到的正是它们。
    //
    // 判据是**每一帧**都不许有放大的卡落在指针之外：抬升走显式 controller，
    // 滚动通知一到就同帧 `value = 0`，没有隐式动画那种「目标值改了、渲染值下
    // 一帧才跟上」的窗口。修复前这里连续 8 帧（128ms，缩放从 1.050 可见地缓降
    // 到 1.003）都挂着一张已经滚走 120px 的放大卡。
    for (int step = 0; step < 4; step++) {
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, 120)));
      for (int frame = 0; frame < 14; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        final List<Rect> stray = visuallyLifted(
          tester,
        ).where((Rect r) => !r.contains(pointerPos)).toList();
        expect(
          stray,
          isEmpty,
          reason: '第${step + 1}档第${frame + 1}帧：屏幕上放大的卡 $stray 不在指针 '
              '$pointerPos 底下——抬升残留到了已经滚走的卡上（BUG-2124）',
        );
      }
    }
    await tester.pumpAndSettle();
    expect(
      scrollable.position.pixels,
      greaterThan(pixelsBefore),
      reason: '视口自始至终没有位移，本用例的不变式是空壳',
    );
  }

  testWidgets('全部视频墙格：滚动全程放大的卡必须在指针底下', (WidgetTester tester) async {
    await runScrollCase(tester, VideoLibrarySection.allVideos);
  });

  testWidgets('系列墙格：滚动全程放大的卡必须在指针底下', (WidgetTester tester) async {
    await runScrollCase(tester, VideoLibrarySection.series);
  });

  testWidgets('界面缩放 1.3 下同样成立（此 bug 与界面大小无关）', (WidgetTester tester) async {
    await runScrollCase(tester, VideoLibrarySection.allVideos, uiScale: 1.3);
  });

  testWidgets('滚动停下后指针仍在卡上，抬升要回来（压制不得吃掉 hover 真值）', (
    WidgetTester tester,
  ) async {
    await seedMany(40);
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(buildApp(VideoLibrarySection.allVideos));
    await tester.pumpAndSettle();

    final Offset pointerPos = pickPointer(tester);
    final TestPointer pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(pointer.hover(pointerPos));
    await tester.pumpAndSettle();
    expect(visuallyLifted(tester).length, 1);

    // 滚一点点：小到指针滚完仍落在某张卡上（不是行间隙）。
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 20)));
    await tester.pumpAndSettle();

    final List<Rect> after = visuallyLifted(tester);
    expect(
      after.length,
      1,
      reason: '滚动停止后指针底下的卡必须重新抬升——滚动压制只压视觉，不许清掉 '
          'hover 真值：MouseRegion 不会因为滚动结束补发 onEnter，清了就再也涨不回来',
    );
    expect(after.single.contains(pointerPos), isTrue);
  });
}
