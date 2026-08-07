// 覆盖边界（勿误读）：本文件只验 reader 侧 JS 载荷的**语义**——生成函数返回的那个字符串
// 里有什么、行为契约对不对。它证明不了这个载荷真的被拼进最终注入 WebView 的 setup 脚本。
// 「装配完整性」（每个子载荷都被拼进去、压缩后还在）由
// test/reader/reader_script_compactor_test.dart 的「setup 装配完整性」一组集中守——
// 那里删掉模板中的 $caretJs / $selectionJs / $longPressDragJs 会立刻转红，本文件不会。
// 改这里前先分清你要锁的是语义还是注入，别在本文件里重造装配断言。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_caret_scripts.dart';
import 'package:fushi/src/reader/reader_pagination_scripts.dart';

/// TODO-1289 守卫：图片防剧透遮罩「点击揭开后又恢复」。
///
/// 根因——揭开只删 WebView 内 DOM 的 `blurred` class，章节 (重)载 / 布局设置切换会
/// 重跑 initialize→_sharedInitImages 无条件重加 `blurred`，把揭开状态冲掉。修复把
/// 「本次会话已揭开」的稳定 key 注入分页脚本，`_fushiBlurImage` 命中即跳过重新遮罩；
/// 揭开状态由 Dart 会话集经 `onImageRevealed` 回传持久。这些守卫锁住三条不变量：
///   1. 分页/连续脚本在 C.blurImages 为真时消费 C.revealedKeys 并跳过已揭开图片；
///   2. 揭开 key 计算器 `window.__fushiImageRevealKey` 暴露给点击/焦点两条揭开路径；
///   3. 点击（webview.part.dart）与键盘/手柄（caret）揭开都回传 onImageRevealed。
String _read(String relPath) => File(relPath).readAsStringSync();

void main() {
  group('TODO-1289 分页脚本消费已揭开集（不再无条件重新遮罩）', () {
    test('blurImages=true 时嵌入 revealedKeys 并让 _fushiBlurImage 跳过命中项', () {
      final String js = ReaderPaginationScripts.paginatedShellSource();
      // 已揭开集被嵌入并建成查找表。
      expect(js, contains('var _fushiRevealedKeys = Object.create(null);'));
      // BUG-1140 第二阶段①：已揭开集不再插进源码，改由运行时 C.revealedKeys 读。
      expect(js, contains('var __fushiKeys = C.revealedKeys;'));
      // 遮罩前先看 key 是否已揭开——命中直接 return，不再重加 blurred。
      expect(js, contains('if (key && _fushiRevealedKeys[key]) return;'));
      // 揭开 key 计算器暴露给点击/焦点揭开路径复用。
      expect(
          js, contains('window.__fushiImageRevealKey = _fushiImageRevealKey;'));
    });

    test('连续模式同样透传 revealedKeys（重排/重载不复原遮罩）', () {
      final String js = ReaderPaginationScripts.continuousShellSource();
      expect(js, contains('var _fushiRevealedKeys = Object.create(null);'));
      expect(js, contains('var __fushiKeys = C.revealedKeys;'));
      expect(js, contains('if (key && _fushiRevealedKeys[key]) return;'));
    });

    test('blurImages=false 时不装遮罩/揭开副作用（边界，零行为变化）', () {
      // 改动前是「blurImages 为假整段不注入」；引擎静态化后函数照常定义，
      // **副作用**（重新遮罩、两个 window 全局的暴露）仍受同一个开关门控。
      final String js = ReaderPaginationScripts.paginatedShellSource();
      expect(js, contains('if (C.blurImages) _fushiBlurImage(svg);'));
      expect(js, contains('if (C.blurImages) _fushiBlurImage(img);'));
      expect(
        js,
        contains('window.__fushiImageRevealKey = _fushiImageRevealKey;'),
        reason: '揭开 key 计算器仍要暴露给点击/焦点揭开路径复用',
      );
      // 两个 window 全局只在开了防剧透遮罩时才挂上（caret / 有声书桥接都靠这个
      // 全局在不在来探测），否则行为与改动前不一致。
      final int gate = js.indexOf('if (C.blurImages) {');
      final int export =
          js.indexOf('window.__fushiImageRevealKey = _fushiImageRevealKey;');
      expect(gate, isNonNegative);
      expect(export, greaterThan(gate),
          reason: '揭开 key 计算器的 window 暴露必须落在 C.blurImages 门控之内');
      final int markExport =
          js.indexOf('window.__fushiMarkImageRevealed = function(key)');
      expect(markExport, greaterThan(gate), reason: '会话内揭开登记同样受同一个开关门控');
    });
  });

  group('TODO-1289 两条揭开路径都回传 onImageRevealed 做持久化', () {
    test('焦点/手柄揭开（caret 脚本）回传稳定 key', () {
      final String js = ReaderCaretScripts.source();
      expect(js, contains("this.el.classList.remove('blurred');"));
      expect(js, contains('window.__fushiImageRevealKey(this.el)'));
      expect(js, contains("callHandler('onImageRevealed', revealKey)"));
    });

    test('点击揭开（webview.part.dart）回传 key + 分页脚本嵌入会话集', () {
      final String src = _read(
        'lib/src/pages/implementations/reader_fushi/webview.part.dart',
      );
      // 点击揭开回传。
      expect(src, contains("callHandler('onImageRevealed', key)"));
      // 注册处理器把 key 收进会话内存集。
      expect(src, contains("handlerName: 'onImageRevealed'"));
      expect(src, contains('_revealedImageKeys.add(key)'));
      // BUG-1140 第二阶段①：会话集不再嵌进脚本源码，改随每章 config 下发。
      expect(
        src,
        contains('revealedKeys: _revealedImageKeys.toList(),'),
      );
    });

    test('会话集字段声明在阅读器 State（随本书阅读会话存活）', () {
      final String page =
          _read('lib/src/pages/implementations/reader_fushi_page.dart');
      expect(
          page, contains('final Set<String> _revealedImageKeys = <String>{};'));
    });
  });
}
