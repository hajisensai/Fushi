import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/gal_attached_text_controller.dart';
import 'package:fushi/src/lookup/gal_lookup_surface_profile.dart';
import 'package:fushi/src/mining/gal_hook_session_controller.dart';
import 'package:fushi/src/pages/implementations/gal_attached_lookup_workbench.dart';
import 'package:fushi/src/pages/implementations/gal_capture_setup_dialog.dart';
import 'package:fushi/src/platform/gal_hook_text_overlay_channel.dart';
import 'package:fushi/src/sync/texthooker_service.dart';
import 'package:fushi/src/sync/texthooker_ws_client.dart';

const String _sha =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

class _RiskPendingSurfacePort implements GalAttachedTextSurfacePort {
  @override
  Future<GalAttachedCallResult> inspectTarget(
    GalAttachedSurfaceTarget target, {
    String? launchExePath,
  }) async => const GalAttachedCallResult(
    status: 'activeNative',
    exePath: r'C:\Games\Sample\game.exe',
    exeSha256: _sha,
    referenceClient: GalLookupReferenceClientV1(
      widthPx: 1280,
      heightPx: 720,
      dpi: 96,
    ),
    providerKind: 1,
    providerId: 1,
    providerStatus: 2,
    shield: GalAttachedShieldStatus(available: true, statusFlags: 0x02),
  );

  @override
  Future<GalAttachedCallResult> detach(GalAttachedSurfaceTarget target) async =>
      const GalAttachedCallResult(status: 'detached');

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      Future<GalAttachedCallResult>.value(
        const GalAttachedCallResult(status: 'ready'),
      );
}

class _RecordingNavigatorObserver extends NavigatorObserver {
  final List<Route<dynamic>> poppedRoutes = <Route<dynamic>>[];

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    poppedRoutes.add(route);
    super.didPop(route, previousRoute);
  }
}

void main() {
  // BUG-2154 之前：会话一活跃就要求逐 exe 确认「裸左击风险」，捕获设置弹窗为此
  // 自动让位、工具条上冒出确认按钮。那道门已经整个去掉（风险恒定接受），所以本
  // 用例反过来守新契约——**弹窗不再被顶掉、确认按钮不再出现**。
  //
  // 保留而不是删掉的理由：这两条正是用户实际抱怨的症状（每个游戏每次启动都被顶
  // 一次、而游戏里没有任何提示指向那个按钮）。断言反向之后它就是那道门不许悄悄
  // 回来的锚。
  testWidgets('lookup session no longer demands per-exe risk consent', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final TexthookerService textService = TexthookerService.test();
    final ValueNotifier<int> endpointSignal = ValueNotifier<int>(0);
    final GalHookSessionController session = GalHookSessionController(
      textService: textService,
      isWindows: false,
      endpointListenable: endpointSignal,
      endpointStatusLoader: () => const <TexthookerEndpointStatus>[],
    );
    final GalAttachedTextController attachedText = GalAttachedTextController(
      preferenceReader: (_) => null,
      preferenceWriter: (_, __) async {},
      surfacePort: _RiskPendingSurfacePort(),
    );
    addTearDown(() async {
      await attachedText.detach();
      attachedText.dispose();
      session.dispose();
      endpointSignal.dispose();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => Column(
              children: <Widget>[
                GalAttachedLookupWorkbench(
                  controller: attachedText,
                  hasSelectedBodyThread: true,
                  bodyPreview: '本文です',
                ),
                FilledButton(
                  key: const ValueKey<String>('open-capture-setup'),
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (BuildContext context) => GalCaptureSetupDialog(
                      session: session,
                      attachedText: attachedText,
                      onSelectThread: (_) async => true,
                    ),
                  ),
                  child: const Text('open'),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey<String>('open-capture-setup')));
    await tester.pumpAndSettle();
    expect(find.byType(GalCaptureSetupDialog), findsOneWidget);

    await attachedText.syncSession(
      active: true,
      sessionEpoch: 1,
      targetPid: 2,
      targetHwnd: 3,
      sourceText: '本文です',
    );
    expect(
      attachedText.needsUnsafeRiskAcceptance,
      isFalse,
      reason: '风险恒定接受：不再向用户索要逐 exe 确认',
    );
    expect(attachedText.unsafeRiskAcceptanceRequest, isNull);
    await tester.pumpAndSettle();

    expect(
      find.byType(GalCaptureSetupDialog),
      findsOneWidget,
      reason: '没有风险确认要让位了，用户打开的捕获设置弹窗必须留在原地',
    );
    expect(
      find.byKey(const ValueKey<String>('game-attached-lookup-accept-risk')),
      findsNothing,
      reason: '那个按钮是这道门的唯一 UI 出口，门没了它就不该再出现',
    );
  });

  for (final bool dismissWithBack in <bool>[false, true]) {
    // 原来由「风险请求」触发这条排队的自动关闭；那道门去掉后，还活着的触发者是
    // 「用户选中了文本线程」。守的东西没变：**已经被关掉的弹窗留下的自动关闭，
    // 不得把它下面那层工作台路由也弹掉**。
    testWidgets('queued auto-close does not pop workbench after '
        '${dismissWithBack ? 'back' : 'barrier'} dismissal', (
      WidgetTester tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final TexthookerService textService = TexthookerService.test();
      final ValueNotifier<int> endpointSignal = ValueNotifier<int>(0);
      final GalHookSessionController session = GalHookSessionController(
        textService: textService,
        isWindows: false,
        endpointListenable: endpointSignal,
        endpointStatusLoader: () => const <TexthookerEndpointStatus>[],
      );
      final GalAttachedTextController attachedText = GalAttachedTextController(
        preferenceReader: (_) => null,
        preferenceWriter: (_, __) async {},
        surfacePort: _RiskPendingSurfacePort(),
      );
      final _RecordingNavigatorObserver observer =
          _RecordingNavigatorObserver();
      addTearDown(() async {
        await attachedText.detach();
        attachedText.dispose();
        session.dispose();
        endpointSignal.dispose();
      });

      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: <NavigatorObserver>[observer],
          home: Scaffold(
            body: Builder(
              builder: (BuildContext rootContext) => FilledButton(
                key: const ValueKey<String>('open-workbench-route'),
                onPressed: () => Navigator.of(rootContext).push<void>(
                  MaterialPageRoute<void>(
                    builder: (BuildContext pageContext) => Scaffold(
                      body: Column(
                        children: <Widget>[
                          const Text(
                            'workbench',
                            key: ValueKey<String>('workbench-route'),
                          ),
                          FilledButton(
                            key: const ValueKey<String>(
                              'open-racy-capture-setup',
                            ),
                            onPressed: () => showDialog<void>(
                              context: pageContext,
                              builder: (BuildContext context) =>
                                  GalCaptureSetupDialog(
                                    session: session,
                                    attachedText: attachedText,
                                    onSelectThread: (_) async => true,
                                  ),
                            ),
                            child: const Text('open setup'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                child: const Text('open workbench'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('open-workbench-route')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('open-racy-capture-setup')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(GalCaptureSetupDialog), findsOneWidget);

      // 让弹窗排上一次自动关闭：用户选中线程是这条路径现存的唯一触发者。
      // 线程必须真的在目录里，`selectedTextThreadKey` 的 getter 会按
      // `textThreads` 过滤掉不存在的 key。
      textService.appendLine(
        '台詞です',
        textThreadKey: 'luna:pick',
        textThreadLabel: 'Sample 0x1000',
        textHookCode: 'HS932@1000',
        nativeTextThreadId: 0x1000,
      );
      await session.selectTextThread(0x1000, threadKey: 'luna:pick');
      expect(session.selectedTextThreadKey, 'luna:pick');

      // Dismiss the DialogRoute before the dirty ListenableBuilder gets its
      // next frame. Its queued auto-close must not pop the page underneath.
      if (dismissWithBack) {
        await tester.binding.handlePopRoute();
      } else {
        await tester.tapAt(const Offset(8, 8));
      }
      await tester.pumpAndSettle();

      expect(observer.poppedRoutes, hasLength(1));
      expect(find.byType(GalCaptureSetupDialog), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('workbench-route')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }
}
