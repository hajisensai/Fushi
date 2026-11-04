import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/sync/desktop_lookup_service.dart';

import '../helpers/test_platform_services.dart';

/// BUG-4103：app 外来的显式查词（`fushi://lookup` 深链、`fushi_cli lookup`）以前只
/// 排队不切 tab。唯一消费者 HomeDictionaryPage 不保活，用户不在查词 tab 上时词就
/// 一直挂着、什么都不显示。现在统一走 [AppModel.queueExternalLookup]。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => DesktopLookupService.instance.debugReset());
  tearDown(() => DesktopLookupService.instance.debugReset());

  test('queues the word and requests the dictionary tab', () {
    final AppModel appModel = AppModel(testPlatformServices());
    final int before = appModel.homeDictionaryTabRequest.value.seq;

    appModel.queueExternalLookup('食べる');

    expect(DesktopLookupService.instance.pendingText, '食べる');
    expect(appModel.homeDictionaryTabRequest.value.seq, before + 1);
    // 携带待查词：不抢搜索框焦点，页面要把词填进去出词卡。
    expect(appModel.homeDictionaryTabRequest.value.focusSearch, isFalse);
  });

  test('blank text queues nothing and leaves the tab alone', () {
    final AppModel appModel = AppModel(testPlatformServices());
    final int before = appModel.homeDictionaryTabRequest.value.seq;

    appModel.queueExternalLookup('   ');

    expect(DesktopLookupService.instance.pendingText, isNull);
    expect(appModel.homeDictionaryTabRequest.value.seq, before);
  });

  test(
    'main.dart routes every external lookup through queueExternalLookup',
    () {
      final String source = File('lib/main.dart').readAsStringSync();
      expect(
        RegExp(
          r'DesktopLookupService\.instance\.triggerLookup\(',
        ).hasMatch(source),
        isFalse,
        reason:
            'deep link / ctl lookups must also request the dictionary tab; '
            'call AppModel.queueExternalLookup instead',
      );
      expect(
        RegExp(r'queueExternalLookup\(').allMatches(source).length,
        3,
        reason: 'handoff deep link, ctl lookupWord, cold-start deep link',
      );
    },
  );
}
