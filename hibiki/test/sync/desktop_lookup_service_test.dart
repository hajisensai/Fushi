import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/desktop_lookup_service.dart';

void main() {
  setUp(() => DesktopLookupService.instance.debugReset());

  test('submitText sets pendingText and notifies, deduped', () {
    int n = 0;
    void l() => n++;
    DesktopLookupService.instance.addListener(l);
    DesktopLookupService.instance.submitText('  見る ');
    expect(DesktopLookupService.instance.pendingText, '見る');
    expect(n, 1);
    DesktopLookupService.instance.submitText('見る');
    expect(n, 1);
    DesktopLookupService.instance.submitText('読む');
    expect(DesktopLookupService.instance.pendingText, '読む');
    expect(n, 2);
    DesktopLookupService.instance.removeListener(l);
  });

  test('clearPending resets pendingText', () {
    DesktopLookupService.instance.submitText('見る');
    DesktopLookupService.instance.clearPending();
    expect(DesktopLookupService.instance.pendingText, isNull);
  });

  test('shouldTriggerOnClipboard: app 内复制(聚焦)不触发, 外部复制(失焦)触发', () {
    // Hibiki 在前台聚焦 = 本 app 内复制（制卡/选词复制），不弹查词。
    expect(shouldTriggerOnClipboard(true), isFalse);
    // Hibiki 不在前台 = 用户在别的 app 复制，剪贴板变化触发查词。
    expect(shouldTriggerOnClipboard(false), isTrue);
  });
}
