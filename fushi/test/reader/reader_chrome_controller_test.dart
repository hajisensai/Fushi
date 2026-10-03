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

  group('顶栏和底栏被关掉', () {
    test('关掉即收起已唤出的悬浮栏并停掉收起计时', () {
      fakeAsync((FakeAsync async) {
        final ReaderChromeController c = ReaderChromeController();
        c.reveal(const Duration(seconds: 3));
        expect(c.transientVisible, isTrue);
        c.toolbarsHidden = true;
        expect(c.transientVisible, isFalse);
        expect(c.autoHideArmed, isFalse);
        c.dispose();
      });
    });

    test('开着时任何唤出都无效：setter / showTransient / reveal', () {
      fakeAsync((FakeAsync async) {
        final ReaderChromeController c = ReaderChromeController();
        c.toolbarsHidden = true;
        c.transientVisible = true;
        expect(c.transientVisible, isFalse);
        c.showTransient();
        expect(c.transientVisible, isFalse);
        c.reveal(const Duration(seconds: 3));
        expect(c.transientVisible, isFalse);
        expect(c.autoHideArmed, isFalse);
        c.dispose();
      });
    });

    test('不改 showChrome（点词门控镜像）；开回来后唤出恢复', () {
      final ReaderChromeController c = ReaderChromeController();
      c.showChrome = false;
      c.toolbarsHidden = true;
      expect(c.showChrome, isFalse, reason: '关栏不得翻用户的挤压态意图');
      c.toolbarsHidden = false;
      expect(c.showChrome, isFalse, reason: '开回来后回到关掉前的状态');
      c.showTransient();
      expect(c.transientVisible, isTrue);
      c.dispose();
    });

    test('翻转通知监听者，重复置同值不通知', () {
      final ReaderChromeController c = ReaderChromeController();
      int notified = 0;
      c.addListener(() => notified++);
      c.toolbarsHidden = true;
      c.toolbarsHidden = true;
      c.toolbarsHidden = false;
      expect(notified, 2);
      c.dispose();
    });
  });
}
