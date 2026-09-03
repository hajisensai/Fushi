import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/gal_attached_text_controller.dart';
import 'package:fushi/src/lookup/gal_lookup_surface_profile.dart';
import 'package:fushi/src/pages/implementations/gal_attached_lookup_workbench.dart';
import 'package:fushi/src/platform/gal_hook_text_overlay_channel.dart';

const String _sha =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

class _PartialNativeSurfacePort implements GalAttachedTextSurfacePort {
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

void main() {
  test('probe plan keeps UTF-16 offsets at Unicode scalar starts', () {
    final GalAttachedProbePlan? plan = buildGalAttachedProbePlan('A𠮷BC');
    expect(plan, isNotNull);
    expect(plan!.startIndex, 0);
    expect(plan.middleIndex, 3);
    expect(plan.endIndex, 4);
    expect(plan.startText, 'A');
    expect(plan.middleText, 'B');
    expect(plan.endText, 'C');
    expect(buildGalAttachedProbePlan('𠮷A'), isNull);
  });

  test('provider label preserves known and future wire identities', () {
    expect(
      galAttachedProviderLabel(
        providerKind: 4,
        providerId: 11,
        providerStatus: 2,
        fallbackStatus: GalAttachedTextStatus.activeAttached,
        unknownLabel: 'unknown',
      ),
      'attached_calibrated · active',
    );
    expect(
      galAttachedProviderLabel(
        providerKind: 99,
        providerId: 77,
        providerStatus: 88,
        fallbackStatus: GalAttachedTextStatus.disabled,
        unknownLabel: 'unknown',
      ),
      'provider#77 · status#88',
    );
  });

  testWidgets('workbench is persistent and calibration is body-thread gated', (
    WidgetTester tester,
  ) async {
    final GalAttachedTextController controller = GalAttachedTextController(
      preferenceReader: (_) => null,
      preferenceWriter: (_, __) async {},
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GalAttachedLookupWorkbench(
            controller: controller,
            hasSelectedBodyThread: false,
            bodyPreview: '',
          ),
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey<String>('game-attached-lookup-workbench')),
      findsOneWidget,
    );
    final IconButton calibrate = tester.widget<IconButton>(
      find.byKey(const ValueKey<String>('game-attached-lookup-calibrate')),
    );
    expect(calibrate.onPressed, isNull);
    expect(find.textContaining('Select one body-text thread'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('game-attached-lookup-risk-status')),
      findsOneWidget,
    );
  });

  testWidgets('partial native without profile exposes risk acceptance', (
    WidgetTester tester,
  ) async {
    final GalAttachedTextController controller = GalAttachedTextController(
      preferenceReader: (_) => null,
      preferenceWriter: (_, __) async {},
      surfacePort: _PartialNativeSurfacePort(),
    );
    addTearDown(() async {
      await controller.detach();
      controller.dispose();
    });
    await controller.syncSession(
      active: true,
      sessionEpoch: 1,
      targetPid: 2,
      targetHwnd: 3,
      sourceText: '本文です',
    );
    expect(controller.profile, isNull);
    expect(controller.status, GalAttachedTextStatus.needsRiskAcceptance);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GalAttachedLookupWorkbench(
            controller: controller,
            hasSelectedBodyThread: true,
            bodyPreview: '本文です',
          ),
        ),
      ),
    );
    expect(
      find.byKey(const ValueKey<String>('game-attached-lookup-accept-risk')),
      findsOneWidget,
    );

    controller.handleSurfaceStateChanged(
      GalAttachedSurfaceStateEvent(
        target: controller.target!,
        state: 'suspended',
        status: 'targetBackground',
        shield: const GalAttachedShieldStatus(
          available: true,
          statusFlags: 0x02,
        ),
      ),
    );
    await tester.pump();

    expect(controller.status, GalAttachedTextStatus.suspended);
    expect(controller.needsUnsafeRiskAcceptance, isTrue);
    final Finder acceptRisk = find.byKey(
      const ValueKey<String>('game-attached-lookup-accept-risk'),
    );
    final int requestToken = controller.unsafeRiskAcceptanceRequest!.token;
    expect(acceptRisk, findsOneWidget);
    expect(
      tester.getTopLeft(acceptRisk).dx,
      lessThan(
        tester
            .getTopLeft(
              find.byKey(
                const ValueKey<String>('game-attached-lookup-calibrate'),
              ),
            )
            .dx,
      ),
      reason: '风险入口必须固定在左侧，不能再被游戏窗口遮住',
    );

    await tester.tap(acceptRisk);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('game-attached-lookup-risk-confirm')),
      findsOneWidget,
      reason: 'targetBackground 期间风险确认仍须可达',
    );

    await controller.syncSession(
      active: true,
      sessionEpoch: 2,
      targetPid: 4,
      targetHwnd: 5,
      sourceText: '別の本文です',
    );
    await tester.pumpAndSettle();
    // `?.` 在 request 整个消失时给 null，而 null != requestToken 照样通过——
    // 本意是「换 target 要换新 token」，光这一条连「request 没了」都判绿。
    expect(controller.unsafeRiskAcceptanceRequest, isNotNull);
    expect(controller.unsafeRiskAcceptanceRequest!.token, isNot(requestToken));
    expect(
      find.byKey(const ValueKey<String>('game-attached-lookup-risk-confirm')),
      findsOneWidget,
      reason: 'target 变化不应让旧对话框偷偷变成新请求',
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('game-attached-lookup-risk-confirm')),
    );
    await tester.pumpAndSettle();
    expect(controller.profile, isNull);
    expect(controller.needsUnsafeRiskAcceptance, isTrue);
    expect(acceptRisk, findsOneWidget);
  });

  test('Texthooker page constructs attached workbench only on Windows', () {
    final String source = File(
      'lib/src/pages/implementations/texthooker_page.dart',
    ).readAsStringSync();
    expect(
      RegExp(
        r'if\s*\(Platform\.isWindows\)\s*GalAttachedLookupWorkbench\(',
      ).hasMatch(source),
      isTrue,
    );
  });
}
