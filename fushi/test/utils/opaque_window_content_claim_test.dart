import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/opaque_window_content_claim.dart';
import 'package:fushi/src/utils/window_caption_channel.dart';
import 'package:material_ui/material_ui.dart';

/// BUG-5591: the opaque-content claim may only be held while the route has
/// fully covered the window (its entrance animation completed) and must be
/// dropped the moment the exit starts, before any translucent frame of the
/// page below. The runner composes the Mica surface opaque while it is held.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const MethodChannel channel = MethodChannel('app.fushi/window');
  final List<bool> sent = <bool>[];

  setUp(() {
    sent.clear();
    WindowCaptionChannel.debugWindowsOverride = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          if (call.method == 'setContentOpaque') {
            sent.add(
              (call.arguments as Map<Object?, Object?>)['opaque']! as bool,
            );
          }
          return null;
        });
  });

  tearDown(() {
    WindowCaptionChannel.debugWindowsOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<NavigatorState> pumpHome(WidgetTester tester) async {
    final GlobalKey<NavigatorState> navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(navigatorKey: navigator, home: const SizedBox.expand()),
    );
    return navigator.currentState!;
  }

  Route<void> claimRoute(ValueNotifier<bool> enabled) =>
      MaterialPageRoute<void>(
        builder: (BuildContext _) => ValueListenableBuilder<bool>(
          valueListenable: enabled,
          builder: (BuildContext _, bool on, Widget? _) =>
              OpaqueWindowContentClaim(
                enabled: on,
                child: const SizedBox.expand(),
              ),
        ),
      );

  testWidgets('claimed only after the entrance animation, released at pop', (
    WidgetTester tester,
  ) async {
    final NavigatorState navigator = await pumpHome(tester);
    final ValueNotifier<bool> enabled = ValueNotifier<bool>(true);
    unawaited(navigator.push(claimRoute(enabled)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(
      WindowCaptionChannel.debugOpaqueContentClaims,
      0,
      reason: 'the translucent page below is still visible mid-transition',
    );
    await tester.pumpAndSettle();
    expect(WindowCaptionChannel.debugOpaqueContentClaims, 1);
    expect(sent, <bool>[true]);

    navigator.pop();
    expect(
      WindowCaptionChannel.debugOpaqueContentClaims,
      0,
      reason: 'released synchronously when the exit starts, before its frame',
    );
    await tester.pumpAndSettle();
    expect(sent, <bool>[true, false]);
  });

  testWidgets('follows enabled while settled, releases on dispose', (
    WidgetTester tester,
  ) async {
    final NavigatorState navigator = await pumpHome(tester);
    final ValueNotifier<bool> enabled = ValueNotifier<bool>(false);
    unawaited(navigator.push(claimRoute(enabled)));
    await tester.pumpAndSettle();
    expect(WindowCaptionChannel.debugOpaqueContentClaims, 0);

    enabled.value = true;
    await tester.pump();
    await tester.pump();
    expect(WindowCaptionChannel.debugOpaqueContentClaims, 1);

    enabled.value = false;
    await tester.pump();
    expect(WindowCaptionChannel.debugOpaqueContentClaims, 0);

    enabled.value = true;
    await tester.pump();
    await tester.pump();
    expect(WindowCaptionChannel.debugOpaqueContentClaims, 1);

    await tester.pumpWidget(const SizedBox());
    expect(WindowCaptionChannel.debugOpaqueContentClaims, 0);
    await tester.pump();
    expect(sent, <bool>[true, false, true, false]);
  });

  testWidgets('outside any route it claims once a frame is drawn', (
    WidgetTester tester,
  ) async {
    final ValueNotifier<bool> enabled = ValueNotifier<bool>(true);
    await tester.pumpWidget(
      ValueListenableBuilder<bool>(
        valueListenable: enabled,
        builder: (BuildContext _, bool on, Widget? _) =>
            OpaqueWindowContentClaim(enabled: on, child: const SizedBox()),
      ),
    );
    await tester.pump();
    expect(WindowCaptionChannel.debugOpaqueContentClaims, 1);
    enabled.value = false;
    await tester.pump();
    expect(WindowCaptionChannel.debugOpaqueContentClaims, 0);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(sent, <bool>[true, false]);
  });
}
