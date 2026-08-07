import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/focus/hibiki_focus_controller.dart';
import 'package:fushi/src/pages/implementations/media_collection_detail_page.dart';
import 'package:fushi/src/shortcuts/global_navigation.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';
import 'package:fushi_core/fushi_core.dart';

/// BUG-1349：合集详情页按 Esc 必须退出层级。
///
/// 核心故障态（修复前必现）：焦点导航开启且当前页**零受管焦点目标**时，焦点被
/// 回收链路 park 到 [HibikiFocusRoot] 的 fallbackNode——它挂在 Navigator **之上**，
/// `HibikiFocusController.activeContext` 与 `primaryFocus.context` 都解析不出
/// ModalRoute，旧 `_handleGlobalEscape` 把「解析不出」当弹窗吞掉，Esc 静默失效。
///
/// 本文件的防假护栏：核心用例先**断言故障态确实成立**（primaryFocus 落在
/// fallbackNode + activeContext 解析不出路由），再断言 Esc 仍能退页——测试若没
/// 逼出故障态会先在前置断言上红，不可能退化成「修不修都绿」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late HibikiDatabase db;
  late int collectionId;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.zhCn);
    db = HibikiDatabase.forTesting(NativeDatabase.memory());
    for (final (String uid, String title) in const <(String, String)>[
      ('video/e1', 'Show 01'),
      ('video/e2', 'Show 02'),
    ]) {
      await db.upsertVideoBook(VideoBooksCompanion(
        bookUid: Value(uid),
        title: Value(title),
        videoPath: Value('/v/$title.mkv'),
      ));
    }
    collectionId =
        await db.createMediaCollection('Show', collectionType: 'playlist');
    await db.addToCollection(collectionId, MediaKind.video, 'video/e1');
    await db.addToCollection(collectionId, MediaKind.video, 'video/e2');
  });

  tearDown(() => db.close());

  Future<List<VideoBookRow>> loadMembers() async {
    final List<MediaCollectionItemRow> items =
        await db.getCollectionItems(collectionId);
    final List<VideoBookRow> all = await db.allVideoBooks();
    final Map<String, VideoBookRow> byUid = <String, VideoBookRow>{
      for (final VideoBookRow r in all) r.bookUid: r,
    };
    return <VideoBookRow>[
      for (final MediaCollectionItemRow it in items)
        if (byUid[it.entryKey] case final VideoBookRow row) row,
    ];
  }

  Widget detailPage({Future<List<VideoBookRow>> Function()? members}) =>
      MediaCollectionDetailPage(
        database: db,
        collection: MediaCollectionRow(
          id: collectionId,
          name: 'Show',
          collectionType: 'playlist',
          coverSource: null,
          sortOrder: 0,
          createdAt: 0,
          orderUpdatedAt: 0,
        ),
        loadMembers: members ?? loadMembers,
        onOpenEpisode: (VideoBookRow _) {},
        onChanged: () {},
      );

  /// 零受管焦点目标的详情页（空成员 → 占位形态，一张集卡都不注册）：形态 (b)
  /// 的载体——ensureFocus 在这样的页面上才会真的 park 到 fallbackNode。
  Widget emptyDetailPage() =>
      detailPage(members: () async => const <VideoBookRow>[]);

  void useTallSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(1280, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  /// 与 main.dart 同构接线：MaterialApp.builder 内 [wrapWithGlobalNavigation]
  /// 包 [HibikiFocusRoot]。**顺序是 BUG-1349 第二处根因的一部分**：fallbackNode
  /// 必须位于全局导航层之内，其键事件才冒泡得到全局处理器（修复前顺序相反，
  /// 焦点 park 到兜底节点后所有全局键静默失效）。
  Future<GlobalKey<NavigatorState>> pumpApp(
    WidgetTester tester, {
    required bool focusNavigationEnabled,
  }) async {
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    final HibikiShortcutRegistry registry = HibikiShortcutRegistry()
      ..loadDefaults(TargetPlatform.windows);
    await tester.pumpWidget(TranslationProvider(
      child: MaterialApp(
        navigatorKey: navKey,
        builder: (BuildContext context, Widget? child) =>
            wrapWithGlobalNavigation(
          navigatorKey: navKey,
          focusNavigationEnabled: focusNavigationEnabled,
          registry: registry,
          child: HibikiFocusRoot(
            enabled: focusNavigationEnabled,
            child: child!,
          ),
        ),
        home: const Scaffold(body: Center(child: Text('library-home'))),
      ),
    ));
    await tester.pumpAndSettle();
    return navKey;
  }

  HibikiFocusController controllerOf(GlobalKey<NavigatorState> navKey) {
    final HibikiFocusController? controller = HibikiFocusRoot.maybeControllerOf(
      navKey.currentContext!,
      listen: false,
    );
    expect(controller, isNotNull,
        reason: '焦点导航开启时 Navigator 子树必须拿得到控制器（harness 前提）');
    return controller!;
  }

  /// 故障形态 (a)「遮蔽态」护栏：进页后没有任何受管目标被聚焦（_activeId 空），
  /// `activeContext` 回落到 Navigator 之上的兜底 context、解析不出 ModalRoute，
  /// 而 primaryFocus 明明落在路由内——旧代码 `activeContext ?? primaryFocus` 让
  /// 无效候选遮蔽有效候选，Esc 被吞。这是用户实际场景：开着焦点导航、用鼠标
  /// 进详情页（从未键盘聚焦任何卡）、按 Esc。
  void assertShadowFaultState(HibikiFocusController controller) {
    final BuildContext? activeContext = controller.activeContext;
    expect(activeContext, isNotNull,
        reason: '前置：activeContext 回落到兜底 context（非 null 才会遮蔽 primaryFocus）');
    expect(
      ModalRoute.of(activeContext!),
      isNull,
      reason: '前置：兜底 context 位于 Navigator 之上、解析不出任何 ModalRoute——'
          'BUG-1349 里被旧代码当成弹窗吞掉的正是这个状态',
    );
    final BuildContext? primaryContext =
        FocusManager.instance.primaryFocus?.context;
    expect(primaryContext, isNotNull);
    expect(
      ModalRoute.of(primaryContext!),
      isNotNull,
      reason: '前置：primaryFocus 是**能**解析出路由的有效候选（被遮蔽的那一个）',
    );
  }

  /// 故障形态 (b)「双失效态」：零受管目标的页面上走真实回收链路
  /// （[HibikiFocusController.ensureFocus] 的「无目标 → fallbackNode
  /// .requestFocus()」分支，TODO-900 回收范式），primaryFocus 也被 park 到
  /// Navigator 之上——两个候选都解析不出路由。
  Future<void> parkFocusOnFallback(
    WidgetTester tester,
    HibikiFocusController controller,
  ) async {
    controller.ensureFocus();
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus,
      same(controller.fallbackNode),
      reason: '前置：焦点必须真的被回收到 Navigator 之上的 fallbackNode（本页必须'
          '零受管目标，否则 ensureFocus 会落到真实目标上）',
    );
    final BuildContext? activeContext = controller.activeContext;
    expect(activeContext, isNotNull);
    expect(ModalRoute.of(activeContext!), isNull,
        reason: '前置：activeContext 解析不出路由');
  }

  testWidgets('注册表接线（焦点导航关闭）：详情页按 Esc 退出层级', (WidgetTester tester) async {
    useTallSurface(tester);
    final GlobalKey<NavigatorState> navKey =
        await pumpApp(tester, focusNavigationEnabled: false);

    navKey.currentState!
        .push(MaterialPageRoute<void>(builder: (_) => detailPage()));
    await tester.pumpAndSettle();
    expect(find.text('library-home'), findsNothing, reason: '详情页已压上');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.byType(MediaCollectionDetailPage), findsNothing,
        reason: 'Esc 必须退出详情页层级');
    expect(find.text('library-home'), findsOneWidget);
  });

  testWidgets('BUG-1349 核心（遮蔽态）：进页未聚焦任何受管目标，activeContext 解析不出路由仍能 Esc 退页',
      (WidgetTester tester) async {
    useTallSurface(tester);
    final GlobalKey<NavigatorState> navKey =
        await pumpApp(tester, focusNavigationEnabled: true);

    navKey.currentState!
        .push(MaterialPageRoute<void>(builder: (_) => emptyDetailPage()));
    await tester.pumpAndSettle();
    assertShadowFaultState(controllerOf(navKey));

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.byType(MediaCollectionDetailPage), findsNothing,
        reason: 'BUG-1349：无效的 activeContext 候选不得遮蔽能解析出路由的 '
            'primaryFocus——Esc 必须退页');
    expect(find.text('library-home'), findsOneWidget);
  });

  testWidgets('BUG-1349 双失效态：零受管目标页焦点被回收到 fallbackNode，两候选都解析不出路由仍能 Esc 退页',
      (WidgetTester tester) async {
    useTallSurface(tester);
    final GlobalKey<NavigatorState> navKey =
        await pumpApp(tester, focusNavigationEnabled: true);

    navKey.currentState!
        .push(MaterialPageRoute<void>(builder: (_) => emptyDetailPage()));
    await tester.pumpAndSettle();
    await parkFocusOnFallback(tester, controllerOf(navKey));

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    // 钉住 _handleGlobalEscape 的行为翻转面：两个候选 context 都解析不出路由 →
    // 不再视作弹窗吞掉，maybePop 顶层页面。
    expect(find.byType(MediaCollectionDetailPage), findsNothing,
        reason: 'BUG-1349：焦点 park 在 Navigator 之上的兜底节点时 Esc 必须仍能退页');
    expect(find.text('library-home'), findsOneWidget);
  });

  testWidgets('负向：弹窗开着（焦点在弹窗内）按 Esc 只关弹窗，不误退详情页', (WidgetTester tester) async {
    useTallSurface(tester);
    final GlobalKey<NavigatorState> navKey =
        await pumpApp(tester, focusNavigationEnabled: true);

    navKey.currentState!
        .push(MaterialPageRoute<void>(builder: (_) => detailPage()));
    await tester.pumpAndSettle();

    showDialog<void>(
      context: navKey.currentContext!,
      builder: (_) => const AlertDialog(content: Text('detail-dialog')),
    );
    await tester.pumpAndSettle();
    expect(find.text('detail-dialog'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.text('detail-dialog'), findsNothing, reason: 'Esc 关掉弹窗');
    expect(find.byType(MediaCollectionDetailPage), findsOneWidget,
        reason: '弹窗消费 Esc 后详情页必须原地不动');
  });

  testWidgets('负向（翻转面）：弹窗开着且焦点 park 在 fallbackNode，Esc 只弹掉顶层弹窗、不退页',
      (WidgetTester tester) async {
    useTallSurface(tester);
    final GlobalKey<NavigatorState> navKey =
        await pumpApp(tester, focusNavigationEnabled: true);

    navKey.currentState!
        .push(MaterialPageRoute<void>(builder: (_) => emptyDetailPage()));
    await tester.pumpAndSettle();

    showDialog<void>(
      context: navKey.currentContext!,
      builder: (_) => const AlertDialog(content: Text('detail-dialog')),
    );
    await tester.pumpAndSettle();
    // 弹窗开着时把焦点 park 到兜底节点：框架的弹窗 Esc 处理（焦点驱动）此时
    // 收不到键，只剩全局处理器——「解析不出路由 → maybePop」必须只弹掉**顶层**
    // （弹窗），绝不能越级把详情页也退了。
    await parkFocusOnFallback(tester, controllerOf(navKey));

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.text('detail-dialog'), findsNothing,
        reason: '解析不出路由时 maybePop 作用于顶层路由 = 弹窗');
    expect(find.byType(MediaCollectionDetailPage), findsOneWidget,
        reason: '一次 Esc 只动一层：弹窗关、详情页在');
  });

  test('源码守卫：main.dart 的焦点导航层必须挂在 wrapWithGlobalNavigation 之内', () {
    // widget 测试自建 harness、不加载 main.dart——真实接线只能靠源码锚点钉住。
    // 变异实测：把 main.dart 换回旧接线（_wrapFocusNavigation 包在
    // wrapWithGlobalNavigation 外）后本用例必红（child: _wrapFocusNavigation(
    // 形态消失）。
    final String mainSrc = File('lib/main.dart').readAsStringSync();
    // 判别性锚：从 wrapWithGlobalNavigation 调用起、到其后 macOS 分支之前的这段
    // 实参文本里必须出现 _wrapFocusNavigation ——旧接线里它在 HibikiAppUiScale
    // 的 child（macOS 分支**之后**），裸 contains 会两种接线都绿（假防护）。
    final int wrapperStart =
        mainSrc.indexOf('Widget navigation = wrapWithGlobalNavigation(');
    final int macosBranch =
        mainSrc.indexOf('if (isMacosPlatform', wrapperStart);
    expect(wrapperStart, greaterThanOrEqualTo(0));
    expect(macosBranch, greaterThan(wrapperStart));
    expect(
      mainSrc
          .substring(wrapperStart, macosBranch)
          .contains('_wrapFocusNavigation('),
      isTrue,
      reason: 'BUG-1349 第二处根因：HibikiFocusRoot（fallbackNode）必须作为 '
          'wrapWithGlobalNavigation 的 child 挂载（即出现在其实参段内），否则'
          '兜底节点的键事件冒泡不到全局处理器，零受管目标页的 Esc/全局快捷键'
          '整体失效',
    );
  });
}
