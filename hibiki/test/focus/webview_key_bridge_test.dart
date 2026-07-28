// 覆盖边界（勿误读）：本文件只验 reader 侧 JS 载荷的**语义**——生成函数返回的那个字符串
// 里有什么、行为契约对不对。它证明不了这个载荷真的被拼进最终注入 WebView 的 setup 脚本。
// 「装配完整性」（每个子载荷都被拼进去、压缩后还在）由
// test/reader/reader_script_compactor_test.dart 的「setup 装配完整性」一组集中守——
// 那里删掉模板中的 $caretJs / $selectionJs / $longPressDragJs 会立刻转红，本文件不会。
// 改这里前先分清你要锁的是语义还是注入，别在本文件里重造装配断言。
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/focus/webview_key_bridge.dart';

void main() {
  group('webViewKeyBridgeScript', () {
    final String spaceBridge = webViewKeyBridgeScript(
      handlerName: 'onSpaceKey',
      keys: const <String>[' '],
    );

    test('capture 阶段监听 keydown（早于页面自身 handler）', () {
      expect(spaceBridge, contains("addEventListener('keydown'"));
      expect(spaceBridge, contains('{capture: true}'));
    });

    test('命中才 preventDefault 并回传 handler + 命中的 key', () {
      expect(spaceBridge, contains('e.preventDefault()'));
      expect(spaceBridge, contains("callHandler('onSpaceKey', e.key)"));
    });

    test('放行修饰键组合（否则吃掉 Shift+Space / Ctrl+Space 的改键语义）', () {
      expect(
        spaceBridge,
        contains('e.ctrlKey || e.shiftKey || e.altKey || e.metaKey'),
      );
    });

    test('放行 IME 组字（否则破坏日文输入）', () {
      expect(spaceBridge, contains('e.isComposing'));
    });

    test('放行输入框 / contenteditable（否则打不出空格）', () {
      expect(spaceBridge, contains("tag === 'INPUT'"));
      expect(spaceBridge, contains("tag === 'TEXTAREA'"));
      expect(spaceBridge, contains('t.isContentEditable'));
    });

    test('只拦声明的键', () {
      expect(spaceBridge, contains("_hoshiBridgeKeys = [' ']"));
      expect(spaceBridge, contains('_hoshiBridgeKeys.indexOf(e.key) === -1'));
    });

    test('多键宿主生成完整键表', () {
      final String multi = webViewKeyBridgeScript(
        handlerName: 'onMangaKey',
        keys: const <String>['ArrowLeft', 'ArrowRight', ' '],
      );
      expect(multi,
          contains("_hoshiBridgeKeys = ['ArrowLeft', 'ArrowRight', ' ']"));
      expect(multi, contains("callHandler('onMangaKey', e.key)"));
    });

    test('默认转发长按（阅读器语义），forwardRepeats:false 时丢弃', () {
      expect(spaceBridge, isNot(contains('e.repeat')),
          reason: '默认不加 repeat 门，保持阅读器既有连发行为');
      final String noRepeat = webViewKeyBridgeScript(
        handlerName: 'onMangaNavigationKey',
        keys: const <String>['ArrowLeft'],
        forwardRepeats: false,
      );
      expect(noRepeat, contains('if (e.repeat) return;'),
          reason: '漫画要「按住方向键不堆翻页风暴」');
    });

    test('stopPropagation 可选，默认不独占', () {
      expect(spaceBridge, isNot(contains('stopImmediatePropagation')));
      final String exclusive = webViewKeyBridgeScript(
        handlerName: 'onX',
        keys: const <String>['Escape'],
        stopPropagation: true,
      );
      expect(exclusive, contains('e.stopImmediatePropagation();'));
    });

    test('幂等安装守卫按 handlerName 派生（宿主可反复注入）', () {
      // 漫画每次换加载窗口都重新 evaluate 一次；没有守卫就会叠加 listener，
      // 一次按键回传多次 → 翻页翻两页。
      expect(spaceBridge,
          contains("window['__hoshiKeyBridgeInstalled_onSpaceKey']"));
      final String other = webViewKeyBridgeScript(
        handlerName: 'onMangaNavigationKey',
        keys: const <String>['ArrowLeft'],
      );
      expect(other,
          contains("window['__hoshiKeyBridgeInstalled_onMangaNavigationKey']"),
          reason: 'flag 必须按 handler 区分，否则同文档里两份桥互相把对方挡掉');
    });

    test('键名里的引号 / 反斜杠被转义（不产生语法坏掉的 JS）', () {
      final String weird = webViewKeyBridgeScript(
        handlerName: 'onWeird',
        keys: const <String>["'", r'\'],
      );
      expect(weird, contains(r"_hoshiBridgeKeys = ['\'', '\\']"));
    });

    test('键表关在 IIFE 闭包里，不是脚本级全局 var', () {
      // 全局 var 时后注入的桥会把先注入的键表整个覆盖掉（两个 listener 却都还在），
      // 表现为「某一页的键突然全不响应」。闭包隔离是这条不变式的唯一保证。
      expect(
        spaceBridge.trimLeft(),
        startsWith(';(function () {'),
        reason: '前导 `;` 保拼接安全：前一条语句缺分号时裸 `(function` 会被当成调用',
      );
      expect(spaceBridge.trimRight(), endsWith('})();'));
      final int open = spaceBridge.indexOf('(function () {');
      final int decl = spaceBridge.indexOf('var _hoshiBridgeKeys');
      final int close = spaceBridge.lastIndexOf('})();');
      expect(decl, greaterThan(open));
      expect(decl, lessThan(close), reason: '键表声明必须落在 IIFE 体内');
    });

    test('同一 document 注入两份桥时，两份键表互不覆盖', () {
      // 漫画页规划中要注入第二份桥（PR 描述），这是那一刻的回归守卫。
      final String reader = webViewKeyBridgeScript(
        handlerName: 'onSpaceKey',
        keys: const <String>[' '],
      );
      final String manga = webViewKeyBridgeScript(
        handlerName: 'onMangaKey',
        keys: const <String>['ArrowLeft', 'ArrowRight'],
      );
      final String both = '$reader\n$manga';
      expect(both, contains("_hoshiBridgeKeys = [' ']"));
      expect(both, contains("_hoshiBridgeKeys = ['ArrowLeft', 'ArrowRight']"));
      expect('(function () {'.allMatches(both).length, 2,
          reason: '每份桥各自一个闭包，键表不共享作用域');
      expect('})();'.allMatches(both).length, 2);
    });
  });
}
