// 覆盖边界（勿误读）：本文件只验 reader 侧 JS 载荷的**语义**——生成函数返回的那个字符串
// 里有什么、行为契约对不对。它证明不了这个载荷真的被拼进最终注入 WebView 的 setup 脚本。
// 「装配完整性」（每个子载荷都被拼进去、压缩后还在）由
// test/reader/reader_script_compactor_test.dart 的「setup 装配完整性」一组集中守——
// 那里删掉模板中的 $caretJs / $selectionJs / $longPressDragJs 会立刻转红，本文件不会。
// 改这里前先分清你要锁的是语义还是注入，别在本文件里重造装配断言。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/focus/webview_key_bridge.dart';

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

    test('命中才 preventDefault 并回传 handler + 命中的 token', () {
      expect(spaceBridge, contains('e.preventDefault()'));
      expect(spaceBridge, contains("callHandler('onSpaceKey', _hit)"));
    });

    test('修饰键并入 token 前缀（裸表天然放行组合键，组合表能真拦到）', () {
      // 契约变更（非回归）：旧版用「带任一修饰键就 return」的独立分支放行，代价是
      // 绑成 Ctrl+D 之类的动作在 WebView 持焦时**永远**收不到。现在修饰键拼进
      // token 前缀，裸表放行组合键只是「不命中」的自然结果，而 'Ctrl+KeyD' 这样的
      // 表能真正拦到。两侧行为由 webview_key_bridge_behavior_test 真跑 JS 验证。
      expect(spaceBridge, contains("if (e.ctrlKey) mods += 'Ctrl+';"));
      expect(spaceBridge, contains("if (e.shiftKey) mods += 'Shift+';"));
      expect(spaceBridge, contains("if (e.altKey) mods += 'Alt+';"));
      expect(spaceBridge, contains("if (e.metaKey) mods += 'Meta+';"));
      expect(spaceBridge, isNot(contains('e.ctrlKey || e.shiftKey')),
          reason: '旧的「有修饰键就整体放行」分支必须消失，否则组合键绑定仍然死');
    });

    test('放行 IME 组字（否则破坏日文输入）', () {
      expect(spaceBridge, contains('e.isComposing'));
    });

    test('放行输入框 / contenteditable（否则打不出空格）', () {
      expect(spaceBridge, contains("tag === 'INPUT'"));
      expect(spaceBridge, contains("tag === 'TEXTAREA'"));
      expect(spaceBridge, contains('t.isContentEditable'));
    });

    test('只拦声明的键（token 表按 handler 挂在 window 上，可热更新）', () {
      expect(spaceBridge,
          contains("window['__hoshiKeyBridgeKeys_onSpaceKey'] = [' ']"));
      expect(spaceBridge,
          contains("window['__hoshiKeyBridgeKeys_onSpaceKey'] || []"));
    });

    test('e.key 与 e.code 双通道（注册表 token 用 DOM code 命名）', () {
      // InputBinding 的键名（'Space' / 'KeyD' / 'Escape'）逐字就是 DOM code，
      // 而老宿主传的是 e.key（' '）。两个候选都要试，否则二选一必有一边失效。
      expect(spaceBridge, contains('out.push(mods + e.key)'));
      expect(spaceBridge, contains('out.push(mods + e.code)'));
    });

    test('多键宿主生成完整键表', () {
      final String multi = webViewKeyBridgeScript(
        handlerName: 'onMangaKey',
        keys: const <String>['ArrowLeft', 'ArrowRight', ' '],
      );
      expect(
          multi,
          contains(
              "window['__hoshiKeyBridgeKeys_onMangaKey'] = ['ArrowLeft', 'ArrowRight', ' ']"));
      expect(multi, contains("callHandler('onMangaKey', _hit)"));
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
      expect(weird,
          contains(r"window['__hoshiKeyBridgeKeys_onWeird'] = ['\'', '\\']"));
    });

    test('键表槽按 handlerName 派生，装在 window 上（可热更新且互不覆盖）', () {
      // 契约变更（非回归）：键表从 IIFE 闭包里的 `var` 挪到按 handlerName 派生的
      // window 槽。闭包版的键表在首次注入时**冻结**——查词弹窗这类热槽 WebView 跨
      // 查词长期存活，用户改键后宿主重新注入也换不掉旧表，弹窗持焦时仍按老键位
      // 响应（BUG-1071 复诉的一半）。挂 window 槽后每次注入覆盖表、listener 仍只装
      // 一次；槽名带 handlerName，所以两份桥依旧互不覆盖。
      expect(
        spaceBridge.trimLeft(),
        startsWith(';(function () {'),
        reason: '前导 `;` 保拼接安全：前一条语句缺分号时裸 `(function` 会被当成调用',
      );
      expect(spaceBridge.trimRight(), endsWith('})();'));
      final int open = spaceBridge.indexOf('(function () {');
      final int decl =
          spaceBridge.indexOf("window['__hoshiKeyBridgeKeys_onSpaceKey'] =");
      final int install =
          spaceBridge.indexOf("window['__hoshiKeyBridgeInstalled_onSpaceKey']");
      final int close = spaceBridge.lastIndexOf('})();');
      expect(decl, greaterThan(open));
      expect(decl, lessThan(close), reason: '键表赋值必须落在 IIFE 体内');
      expect(decl, lessThan(install),
          reason: '键表必须在幂等 return 之前赋值，否则第二次注入换不掉表');
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
      expect(
          both, contains("window['__hoshiKeyBridgeKeys_onSpaceKey'] = [' ']"));
      expect(
          both,
          contains(
              "window['__hoshiKeyBridgeKeys_onMangaKey'] = ['ArrowLeft', 'ArrowRight']"));
      expect('(function () {'.allMatches(both).length, 2,
          reason: '每份桥各自一个 IIFE');
      expect('})();'.allMatches(both).length, 2);
    });

    test('鼠标监听按 installMouseListeners 生成（默认宿主零变化）', () {
      // 弹窗必须恒装鼠标 listener：用户「现在没绑鼠标键、之后才绑上」时，表会从空
      // 变非空，listener 却只装一次——所以开关不能挂在 mouseButtons 是否为空上。
      expect(spaceBridge, isNot(contains("addEventListener('mousedown'")),
          reason: '只用键盘的老宿主不得平白多出鼠标监听');

      final String withMouse = webViewKeyBridgeScript(
        handlerName: 'hostInputToken',
        keys: const <String>['Escape'],
        installMouseListeners: true,
      );
      expect(withMouse, contains("addEventListener('mousedown'"));
      expect(withMouse,
          contains("callHandler('hostInputToken', 'Mouse' + e.button)"));
      expect(withMouse, contains('e.button === 0'), reason: '左键是选词/查词，绝不能被桥抢走');
      expect(withMouse, contains("addEventListener('auxclick'"),
          reason: '侧键要压掉浏览器历史导航默认行为');
      expect(withMouse, contains("addEventListener('contextmenu'"),
          reason: '绑到右键时要压掉原生菜单');
      expect(withMouse,
          contains("window['__hoshiKeyBridgeButtons_hostInputToken'] = []"),
          reason: '未声明按钮时仍要下发空表，用于清掉热槽上残留的旧表');
    });
  });
}
