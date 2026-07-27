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

    test('键名里的引号 / 反斜杠被转义（不产生语法坏掉的 JS）', () {
      final String weird = webViewKeyBridgeScript(
        handlerName: 'onWeird',
        keys: const <String>["'", r'\'],
      );
      expect(weird, contains(r"_hoshiBridgeKeys = ['\'', '\\']"));
    });
  });
}
