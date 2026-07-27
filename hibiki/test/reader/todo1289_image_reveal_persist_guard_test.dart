// 覆盖边界（勿误读）：本文件只验 reader 侧 JS 载荷的**语义**——生成函数返回的那个字符串
// 里有什么、行为契约对不对。它证明不了这个载荷真的被拼进最终注入 WebView 的 setup 脚本。
// 「装配完整性」（每个子载荷都被拼进去、压缩后还在）由
// test/reader/reader_script_compactor_test.dart 的「setup 装配完整性」一组集中守——
// 那里删掉模板中的 $caretJs / $selectionJs / $longPressDragJs 会立刻转红，本文件不会。
// 改这里前先分清你要锁的是语义还是注入，别在本文件里重造装配断言。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/reader/reader_caret_scripts.dart';
import 'package:hibiki/src/reader/reader_pagination_scripts.dart';

/// TODO-1289 守卫：图片防剧透遮罩「点击揭开后又恢复」。
///
/// 根因——揭开只删 WebView 内 DOM 的 `blurred` class，章节 (重)载 / 布局设置切换会
/// 重跑 initialize→_sharedInitImages 无条件重加 `blurred`，把揭开状态冲掉。修复把
/// 「本次会话已揭开」的稳定 key 注入分页脚本，`_hoshiBlurImage` 命中即跳过重新遮罩；
/// 揭开状态由 Dart 会话集经 `onImageRevealed` 回传持久。这些守卫锁住三条不变量：
///   1. 分页/连续脚本在 blurImages=true 时消费 revealedKeysJson 并跳过已揭开图片；
///   2. 揭开 key 计算器 `window.__hoshiImageRevealKey` 暴露给点击/焦点两条揭开路径；
///   3. 点击（webview.part.dart）与键盘/手柄（caret）揭开都回传 onImageRevealed。
String _read(String relPath) => File(relPath).readAsStringSync();

void main() {
  group('TODO-1289 分页脚本消费已揭开集（不再无条件重新遮罩）', () {
    test('blurImages=true 时嵌入 revealedKeys 并让 _hoshiBlurImage 跳过命中项', () {
      final String js = ReaderPaginationScripts.shellScript(
        blurImages: true,
        revealedKeysJson: '["hoshi.local/cover.jpg"]',
      );
      // 已揭开集被嵌入并建成查找表。
      expect(js, contains('var _hoshiRevealedKeys = Object.create(null);'));
      expect(js, contains('["hoshi.local/cover.jpg"]'));
      // 遮罩前先看 key 是否已揭开——命中直接 return，不再重加 blurred。
      expect(js, contains('if (key && _hoshiRevealedKeys[key]) return;'));
      // 揭开 key 计算器暴露给点击/焦点揭开路径复用。
      expect(
          js, contains('window.__hoshiImageRevealKey = _hoshiImageRevealKey;'));
    });

    test('连续模式同样透传 revealedKeys（重排/重载不复原遮罩）', () {
      final String js = ReaderPaginationScripts.shellScript(
        continuousMode: true,
        blurImages: true,
        revealedKeysJson: '["hoshi.local/pic.png"]',
      );
      expect(js, contains('var _hoshiRevealedKeys = Object.create(null);'));
      expect(js, contains('["hoshi.local/pic.png"]'));
      expect(js, contains('if (key && _hoshiRevealedKeys[key]) return;'));
    });

    test('blurImages=false 时不注入遮罩/揭开逻辑（边界，零行为变化）', () {
      final String js = ReaderPaginationScripts.shellScript(blurImages: false);
      expect(js, isNot(contains('_hoshiBlurImage')));
      expect(js, isNot(contains('_hoshiRevealedKeys')));
    });

    test('默认 revealedKeysJson 为空数组（首开无已揭开项）', () {
      final String js = ReaderPaginationScripts.shellScript(blurImages: true);
      expect(js, contains('var keys = [];'));
    });
  });

  group('TODO-1289 两条揭开路径都回传 onImageRevealed 做持久化', () {
    test('焦点/手柄揭开（caret 脚本）回传稳定 key', () {
      final String js = ReaderCaretScripts.source();
      expect(js, contains("this.el.classList.remove('blurred');"));
      expect(js, contains('window.__hoshiImageRevealKey(this.el)'));
      expect(js, contains("callHandler('onImageRevealed', revealKey)"));
    });

    test('点击揭开（webview.part.dart）回传 key + 分页脚本嵌入会话集', () {
      final String src = _read(
        'lib/src/pages/implementations/reader_hibiki/webview.part.dart',
      );
      // 点击揭开回传。
      expect(src, contains("callHandler('onImageRevealed', key)"));
      // 注册处理器把 key 收进会话内存集。
      expect(src, contains("handlerName: 'onImageRevealed'"));
      expect(src, contains('_revealedImageKeys.add(key)'));
      // 构建章节 HTML 时把会话集嵌回分页脚本。
      expect(
        src,
        contains('revealedKeysJson: jsonEncode(_revealedImageKeys.toList())'),
      );
    });

    test('会话集字段声明在阅读器 State（随本书阅读会话存活）', () {
      final String page =
          _read('lib/src/pages/implementations/reader_hibiki_page.dart');
      expect(
          page, contains('final Set<String> _revealedImageKeys = <String>{};'));
    });
  });
}
