import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/misc/debug_log_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Verifies system/"Enable debug log" really takes effect: the toggle drives a
/// DebugLogService singleton (backed by SharedPreferences, NOT the settings DB),
/// and flipping it changes the observable capture behaviour of debugPrint.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await DebugLogService.instance.init();
    await DebugLogService.instance.setEnabled(false);
  });

  tearDown(() async {
    await DebugLogService.instance.setEnabled(false);
  });

  test('toggling enabled flips debugPrint capture and clears on disable',
      () async {
    final DebugLogService svc = DebugLogService.instance;

    expect(svc.enabled, isFalse);
    expect(svc.entries, isEmpty);

    debugPrint('captured-while-disabled-should-not-appear');
    expect(svc.entries, isEmpty);

    await svc.setEnabled(true);
    expect(svc.enabled, isTrue);
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('debug_log_enabled'), isTrue);

    const String marker = 'hibiki-debug-marker-7f3a';
    debugPrint(marker);
    expect(svc.entries, isNotEmpty);
    expect(svc.entries.last.message, marker);
    expect(svc.getFullLog(), contains(marker));

    final int countBeforeNull = svc.entries.length;
    debugPrint(null);
    expect(svc.entries.length, countBeforeNull);

    await svc.setEnabled(false);
    expect(svc.enabled, isFalse);
    expect(svc.entries, isEmpty);

    debugPrint('post-disable-should-not-capture');
    expect(svc.entries, isEmpty);
  });
}
