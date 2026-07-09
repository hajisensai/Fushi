import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-1190 守卫：查词弹窗「高亮被查词」补齐所有缺失面（源码扫描，不依赖真机）。
///
/// 在词头/链接/纯文本被点开子查词后，父卡片必须像 base_source_page 阅读器车道一样
/// 用 `highlightSelection` 标出被查的源词（CSS Custom Highlights）。此前三处缺口：
///   1. mixin 车道（video / 首页 / texthooker）的 onTextSelected/onLinkClick 只
///      truncate + onPush，未高亮父卡片；
///   2. base_source_page 阅读器车道的 onLinkClick 只 push、未与 onTextSelected 对称
///      高亮；
///   3. app 外全局查词嵌套（global_lookup_controller._lookupNested）无任何高亮。
/// 守住这三处不被回退（app 外根查词源词在别的窗口/悬浮字幕、非可控 webview，
/// 无法高亮，属已知边界，不在守卫范围）。
void main() {
  // flutter test 的 cwd 是 hibiki 包根。
  final File mixin =
      File('lib/src/pages/implementations/dictionary_page_mixin.dart');
  final File base = File('lib/src/pages/base_source_page.dart');
  final File controller = File('lib/src/lookup/global_lookup_controller.dart');
  final File render = File('lib/src/lookup/global_lookup_render.dart');

  group('TODO-1190 查词高亮补缺失面守卫', () {
    test('mixin 车道 onTextSelected + onLinkClick 都高亮父卡片', () {
      final String src = mixin.readAsStringSync();
      // 两处（选文/点链）都必须 await onPush 拿匹配长度并 highlightSelection。
      final int occurrences =
          'highlightSelection(count)'.allMatches(src).length;
      expect(occurrences, greaterThanOrEqualTo(2),
          reason:
              'mixin onTextSelected/onLinkClick 未各自 highlightSelection(count)');
      expect(src.contains('final int count = await onPush('), isTrue,
          reason: 'mixin 未 await onPush 取匹配字数用于高亮');
      // onPush 必须返回匹配字数（Future<int>），否则拿不到 count。
      expect(
          src.contains(
              'required Future<int> Function(String text, Rect selectionRect) onPush'),
          isTrue,
          reason: 'onPush 签名未返回 Future<int> 匹配字数');
      expect(src.contains('Future<int> pushNestedPopup('), isTrue,
          reason: 'pushNestedPopup 未返回匹配字数');
      expect(src.contains('lookupHighlightCharCount('), isTrue,
          reason: 'pushNestedPopup 未用 lookupHighlightCharCount 复用共享匹配长度逻辑');
    });

    test('阅读器车道 onLinkClick 与 onTextSelected 对称高亮', () {
      final String src = base.readAsStringSync();
      final int idx = src.indexOf('onLinkClick: (query, localRect) async {');
      expect(idx, greaterThanOrEqualTo(0),
          reason: 'base_source_page 缺 onLinkClick');
      // onLinkClick 之后必须有 highlightSelection（与 onTextSelected 对称）。
      final String after =
          src.substring(idx, (idx + 1000).clamp(0, src.length));
      expect(
          after.contains('item.webViewKey.currentState?.highlightSelection('),
          isTrue,
          reason: 'reader onLinkClick 未对称高亮点中的词头/链接');
    });

    test('app 外全局查词嵌套高亮父 iframe', () {
      final String src = controller.readAsStringSync();
      expect(src.contains('buildHighlightFrameScript('), isTrue,
          reason: 'global_lookup_controller 嵌套查词未高亮父卡片');
      // 用父层插入序 index + 匹配字数驱动，且只在有词条时高亮。
      expect(src.contains('final int parentIndex = _stack.length - 1;'), isTrue,
          reason: '未在推子层前捕获父层 index');
      expect(src.contains('getFinalHighlightLength('), isTrue,
          reason: '未按匹配字数决定高亮长度');

      // render 侧提供 host highlightFrame 通道脚本构建器。
      final String rsrc = render.readAsStringSync();
      expect(rsrc.contains('window.__globalLookupHost.highlightFrame('), isTrue,
          reason: 'buildHighlightFrameScript 未调用 host.highlightFrame 通道');
    });
  });
}
