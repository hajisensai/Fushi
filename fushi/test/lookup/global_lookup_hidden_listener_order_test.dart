import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/global_lookup_controller.dart';
import 'package:fushi/src/lookup/overlay_window_channel.dart'
    show GlobalLookupRoute;

/// PR #3020 审查：`_onOverlayHidden` 曾先通知「窗已关」的消费方、到 finally 才作废
/// desktop 路由。消费方在回调里重读 [GlobalLookupController.desktopLookupInFlight]
/// 读到的仍是「在途」，之后又没人再通知，结论停在旧值上。消费方必须看到关窗后的状态。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('关窗通知时 desktop 路由已作废：onHidden 与 hidden listener 都读到「不在途」', () {
    final GlobalLookupController lookup = GlobalLookupController.instance;
    final void Function()? previousOnHidden = lookup.onHidden;
    final List<bool> seen = <bool>[];
    void listener() => seen.add(lookup.desktopLookupInFlight);
    lookup.onHidden = () => seen.add(lookup.desktopLookupInFlight);
    lookup.addHiddenListener(listener);
    addTearDown(() {
      lookup.removeHiddenListener(listener);
      lookup.onHidden = previousOnHidden;
    });

    final GlobalLookupRoute route = lookup.debugActivateDesktopRoute();
    expect(lookup.desktopLookupInFlight, isTrue);
    lookup.debugDispatchOverlayHidden(route);

    expect(seen, <bool>[false, false]);
    expect(lookup.desktopLookupInFlight, isFalse);
  });

  test('路由所有者（onRoutedHidden）仍在路由有效时收到关窗（galgame 依赖）', () {
    final GlobalLookupController lookup = GlobalLookupController.instance;
    final void Function(GlobalLookupRoute)? previous = lookup.onRoutedHidden;
    final List<bool> seen = <bool>[];
    lookup.onRoutedHidden = (GlobalLookupRoute _) =>
        seen.add(lookup.desktopLookupInFlight);
    addTearDown(() => lookup.onRoutedHidden = previous);

    final GlobalLookupRoute route = lookup.debugActivateDesktopRoute();
    lookup.debugDispatchOverlayHidden(route);

    expect(seen, <bool>[true]);
    expect(lookup.desktopLookupInFlight, isFalse);
  });
}
