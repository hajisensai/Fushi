import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki/src/sync/desktop_lookup_service.dart';
import 'package:hibiki/src/pages/implementations/desktop_lookup_overlay.dart';

void main() {
  setUp(() => DesktopLookupService.instance.debugReset());

  testWidgets('shows pending clipboard text reactively, closeable',
      (tester) async {
    await tester.pumpWidget(const ProviderScope(
        child: MaterialApp(home: Scaffold(body: DesktopLookupOverlay()))));
    await tester.pump();
    expect(find.textContaining('見'), findsNothing);

    DesktopLookupService.instance.submitText('見る');
    await tester.pump();
    expect(find.textContaining('見'), findsWidgets);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(find.textContaining('見'), findsNothing);
  });
}
