import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_chrome_controller.dart';

void main() {
  test('reveal 武装自动收起，到点收起并通知', () {
    fakeAsync((FakeAsync async) {
      final ReaderChromeController c = ReaderChromeController();
      int notified = 0;
      c.addListener(() => notified++);
      c.reveal(const Duration(seconds: 3));
      expect(c.transientVisible, isTrue);
      expect(c.autoHideArmed, isTrue);
      async.elapse(const Duration(seconds: 2));
      expect(c.transientVisible, isTrue);
      async.elapse(const Duration(seconds: 2));
      expect(c.transientVisible, isFalse);
      expect(c.autoHideArmed, isFalse);
      expect(notified, 2);
      c.dispose();
    });
  });

  test('重复 reveal = 重新计时；hideTransient 立即收起并取消计时', () {
    fakeAsync((FakeAsync async) {
      final ReaderChromeController c = ReaderChromeController();
      c.reveal(const Duration(seconds: 3));
      async.elapse(const Duration(seconds: 2));
      c.reveal(const Duration(seconds: 3));
      async.elapse(const Duration(seconds: 2));
      expect(c.transientVisible, isTrue, reason: '第二次 reveal 重新计时');
      c.hideTransient();
      expect(c.transientVisible, isFalse);
      expect(c.autoHideArmed, isFalse);
      async.elapse(const Duration(seconds: 5));
      expect(c.transientVisible, isFalse);
      c.dispose();
    });
  });

  test('同值写入不通知；showChrome / appearanceSheetOpen 变更通知', () {
    final ReaderChromeController c = ReaderChromeController();
    int notified = 0;
    c.addListener(() => notified++);
    c.showChrome = true; // 默认已是 true
    expect(notified, 0);
    c.showChrome = false;
    c.appearanceSheetOpen = true;
    expect(notified, 2);
    c.dispose();
  });
}
