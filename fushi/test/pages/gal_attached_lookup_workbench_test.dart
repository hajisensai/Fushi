import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/gal_attached_text_controller.dart';
import 'package:fushi/src/pages/implementations/gal_attached_lookup_workbench.dart';

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
    // BUG-2154：「确认点击风险」那个按钮不能再出现。它原本是通用覆盖下**每个**游戏的
    // 必经之门（shield 结论永远只能是 Partial），而游戏里没有任何提示指向它。
    expect(
      find.byKey(const ValueKey<String>('game-attached-lookup-accept-risk')),
      findsNothing,
    );
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
