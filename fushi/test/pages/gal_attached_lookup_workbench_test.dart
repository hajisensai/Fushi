import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/lookup/gal_attached_text_controller.dart';
import 'package:fushi/src/lookup/gal_lookup_surface_profile.dart';
import 'package:fushi/src/pages/implementations/gal_attached_lookup_workbench.dart';
import 'package:fushi/src/platform/gal_hook_text_overlay_channel.dart';

const String _sha =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

/// 让 `setMode` 有 profile 可改：模式只能落在已识别的 exe 上，而 exe 身份来自一次
/// 真实的 inspect。BUG-2154 删「确认点击风险」按钮时把这个桩一起删了，但它服务的
/// 不是那个按钮，而是「让控制器进入有 profile 的状态」——#1371 的模式门控断言
/// 离不开它。
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

class _CalibrationSurfacePort extends _PartialNativeSurfacePort {
  int cancelCalls = 0;
  GalAttachedCallResult liveResult = const GalAttachedCallResult(
    status: 'shieldHandshakePending',
  );

  @override
  Future<GalAttachedCallResult> calibrationStart({
    required GalAttachedSurfaceTarget target,
    required GalLookupNormalizedRectV1 bodyRect,
    required GalLookupReferenceClientV1 referenceClient,
    required GalLookupTextLayoutV1 layout,
    required bool riskAccepted,
  }) async => liveResult;

  @override
  Future<GalAttachedCallResult> updateText({
    required GalAttachedSurfaceTarget target,
    required String sourceText,
    required int textGeneration,
  }) async => liveResult;

  @override
  Future<GalAttachedCallResult> calibrationCancel(
    GalAttachedSurfaceTarget target,
  ) async {
    cancelCalls++;
    return const GalAttachedCallResult(status: 'cancelled');
  }
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

  testWidgets(
    'workbench is persistent and calibration entry is manual-mode gated',
    (WidgetTester tester) async {
      final GalAttachedTextController controller = GalAttachedTextController(
        preferenceReader: (_) => null,
        preferenceWriter: (_, __) async {},
        surfacePort: _PartialNativeSurfacePort(),
      );
      addTearDown(() async {
        await controller.detach();
        controller.dispose();
      });

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
      expect(
        find.byKey(
          const ValueKey<String>('game-attached-lookup-dialogue-samples'),
        ),
        findsOneWidget,
        reason: '自动模式也应保留对话校准入口',
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('game-attached-lookup-mode')),
      );
      await tester.pumpAndSettle();
      final PopupMenuItem<String> automaticCalibrate = tester
          .widget<PopupMenuItem<String>>(
            find.byKey(
              const ValueKey<String>('game-attached-lookup-calibrate'),
            ),
          );
      expect(
        automaticCalibrate.enabled,
        isFalse,
        reason: '自动模式下没有正文线程时校准入口仍应禁用',
      );
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Select one body-text thread'),
        findsNothing,
        reason: '这条提示只为校准服务，校准不露面时它也不该占位',
      );
      expect(
        find.byKey(const ValueKey<String>('game-attached-lookup-details')),
        findsOneWidget,
      );
      // BUG-2154：「确认点击风险」那个按钮不能再出现。它原本是通用覆盖下**每个**游戏的
      // 必经之门（shield 结论永远只能是 Partial），而游戏里没有任何提示指向它。
      expect(
        find.byKey(const ValueKey<String>('game-attached-lookup-accept-risk')),
        findsNothing,
      );

      await controller.syncSession(
        active: true,
        sessionEpoch: 1,
        targetPid: 2,
        targetHwnd: 3,
        sourceText: '本文です',
      );
      await controller.setMode(GalLookupSurfaceMode.attachedOnly);
      await tester.pump();

      await tester.tap(
        find.byKey(const ValueKey<String>('game-attached-lookup-mode')),
      );
      await tester.pumpAndSettle();
      final PopupMenuItem<String> calibrate = tester
          .widget<PopupMenuItem<String>>(
            find.byKey(
              const ValueKey<String>('game-attached-lookup-calibrate'),
            ),
          );
      expect(calibrate.enabled, isFalse, reason: '手动模式下入口出现，但未选正文线程时仍然禁用');
      expect(
        find.textContaining('Select one body-text thread'),
        findsOneWidget,
      );
    },
  );

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

  testWidgets(
    'live calibration shows readiness, rejects changed text and cancels while paused',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final _CalibrationSurfacePort port = _CalibrationSurfacePort();
      final GalAttachedTextController controller = GalAttachedTextController(
        preferenceReader: (_) => jsonEncode(
          GalLookupSurfaceProfileV1(
            exePath: r'c:\games\sample\game.exe',
            exeSha256: _sha,
            mode: GalLookupSurfaceMode.attachedOnly,
            unsafeLeftClickAccepted: true,
            variants: const <GalLookupSurfaceVariantV1>[],
          ).toJson(),
        ),
        preferenceWriter: (_, __) async {},
        surfacePort: port,
        calibrationLog: (_) {},
      );
      await controller.syncSession(
        active: true,
        sessionEpoch: 1,
        targetPid: 2,
        targetHwnd: 3,
        sourceText: 'テスト本文です',
      );
      addTearDown(() async {
        await controller.detach();
        controller.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GalAttachedLookupWorkbench(
              controller: controller,
              hasSelectedBodyThread: true,
              bodyPreview: 'テスト本文です',
            ),
          ),
        ),
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('game-attached-lookup-mode')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('game-attached-lookup-calibrate')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(GalAttachedCalibrationDialog), findsOneWidget);
      expect(
        find.text(t.game_lookup_attached_calibration_preparing),
        findsOneWidget,
      );
      expect(find.text(t.game_lookup_attached_probes_hint), findsNothing);

      void emit(String status, {bool visible = false, bool observed = false}) {
        controller.handleSurfaceStateChanged(
          GalAttachedSurfaceStateEvent(
            target: controller.target!,
            state: visible ? 'calibrating' : 'suspended',
            status: status,
            surfaceVisible: visible,
            probeStartObservedIndex: observed ? 0 : null,
            probeMiddleObservedIndex: observed ? 3 : null,
            probeEndObservedIndex: observed ? 6 : null,
          ),
        );
      }

      emit('targetBackground');
      await tester.pump();
      expect(
        find.text(t.game_lookup_attached_calibration_paused),
        findsOneWidget,
      );
      expect(controller.calibrationActive, isTrue);
      emit('calibrating', visible: true);
      await tester.pump();
      expect(
        find.text(t.game_lookup_attached_calibration_ready),
        findsOneWidget,
      );
      emit('inputShieldUnavailable');
      await tester.pump();
      expect(
        find.text(t.game_lookup_attached_calibration_unavailable),
        findsOneWidget,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(
                const ValueKey<String>('game-attached-calibration-commit'),
              ),
            )
            .onPressed,
        isNull,
      );
      emit('calibrating', visible: true, observed: true);
      await tester.pump();
      final Finder probeCheckboxes = find.descendant(
        of: find.byType(GalAttachedCalibrationDialog),
        matching: find.byType(Checkbox),
      );
      expect(probeCheckboxes, findsNWidgets(3));
      expect(
        tester
            .widgetList<Checkbox>(probeCheckboxes)
            .every((Checkbox checkbox) => checkbox.onChanged != null),
        isTrue,
      );
      await controller.syncSession(
        active: true,
        sessionEpoch: 1,
        targetPid: 2,
        targetHwnd: 3,
        sourceText: '次の新本文です',
      );
      emit('calibrating', visible: true, observed: true);
      await tester.pump();
      expect(
        find.text(t.game_lookup_attached_calibration_text_changed),
        findsOneWidget,
      );
      expect(find.text(t.game_lookup_attached_probes_hint), findsNothing);
      expect(
        tester
            .widgetList<Checkbox>(probeCheckboxes)
            .every((Checkbox checkbox) => checkbox.onChanged == null),
        isTrue,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(
                const ValueKey<String>('game-attached-calibration-commit'),
              ),
            )
            .onPressed,
        isNull,
      );
      await controller.syncSession(
        active: true,
        sessionEpoch: 1,
        targetPid: 2,
        targetHwnd: 3,
        sourceText: 'テスト本文です',
      );
      await tester.pump();
      expect(
        find.text(t.game_lookup_attached_calibration_text_changed),
        findsOneWidget,
      );
      emit('targetBackground');
      await tester.pump();
      tester
          .widget<TextButton>(
            find.byKey(
              const ValueKey<String>('game-attached-calibration-cancel'),
            ),
          )
          .onPressed!();
      await tester.pumpAndSettle();
      expect(port.cancelCalls, 1);
      expect(controller.calibrationActive, isFalse);
      expect(find.byType(GalAttachedCalibrationDialog), findsNothing);
    },
  );
}
