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
  testWidgets('lookup risk request dismisses an open capture setup dialog', (
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
    expect(attachedText.needsUnsafeRiskAcceptance, isTrue);
    await tester.pumpAndSettle();

    expect(find.byType(GalCaptureSetupDialog), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('game-attached-lookup-accept-risk')),
      findsOneWidget,
      reason: '捕获设置让位后必须暴露真实的逐 exe 风险确认入口',
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('game-attached-lookup-accept-risk')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('game-attached-lookup-risk-confirm')),
      findsOneWidget,
      reason: '透明模态 barrier 不能再拦截工作台点击',
    );
  });

  for (final bool dismissWithBack in <bool>[false, true]) {
    testWidgets('risk auto-close does not pop workbench after '
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

      await attachedText.syncSession(
        active: true,
        sessionEpoch: 1,
        targetPid: 2,
        targetHwnd: 3,
        sourceText: '本文です',
      );
      expect(attachedText.needsUnsafeRiskAcceptance, isTrue);

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
