import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

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
  final File mixin = File(
    'lib/src/pages/implementations/dictionary_page_mixin.dart',
  );
  final File base = File('lib/src/pages/base_source_page.dart');
  final File controller = File('lib/src/lookup/global_lookup_controller.dart');
  final File render = File('lib/src/lookup/global_lookup_render.dart');

  group('TODO-1190 查词高亮补缺失面守卫', () {
    test('mixin 车道 onTextSelected + onLinkClick 都高亮父卡片', () {
      final String src = mixin.readAsStringSync();
      // 两处（选文/点链）都必须 await onPush 拿匹配长度并 highlightSelection。
      final int occurrences = 'highlightSelection(count)'
          .allMatches(src)
          .length;
      expect(
        occurrences,
        greaterThanOrEqualTo(2),
        reason:
            'mixin onTextSelected/onLinkClick 未各自 highlightSelection(count)',
      );
      expect(
        src.contains('final int count = await onPush('),
        isTrue,
        reason: 'mixin 未 await onPush 取匹配字数用于高亮',
      );
      // onPush 必须返回匹配字数（Future<int>），否则拿不到 count。
      expect(
        src.contains(
          'required Future<int> Function(String text, Rect selectionRect) onPush',
        ),
        isTrue,
        reason: 'onPush 签名未返回 Future<int> 匹配字数',
      );
      expect(
        src.contains('Future<int> pushNestedPopup('),
        isTrue,
        reason: 'pushNestedPopup 未返回匹配字数',
      );
      expect(
        src.contains('lookupHighlightCharCount('),
        isTrue,
        reason: 'pushNestedPopup 未用 lookupHighlightCharCount 复用共享匹配长度逻辑',
      );
    });

    test('阅读器车道 onLinkClick 与 onTextSelected 对称高亮', () {
      final String src = base.readAsStringSync();
      final int idx = src.indexOf('onLinkClick: (query, localRect) async {');
      expect(
        idx,
        greaterThanOrEqualTo(0),
        reason: 'base_source_page 缺 onLinkClick',
      );
      // onLinkClick 之后必须有 highlightSelection（与 onTextSelected 对称）。
      //
      // 定界用**下一个回调的起点**，不用固定字符数：BUG-2054 往这个回调里加了两道
      // 身份门后，原来的 1000 字符窗口就把 highlightSelection 挤了出去（判据的语义
      // 没变，只是被推远）。把数字调大是削弱——真正的边界是「还在 onLinkClick 这一
      // 段里」，语义定界既不会随段落长度漂移，也不会漏进隔壁回调。
      final int nextCallback = src.indexOf('onScrolledToBottom', idx);
      final String after = src.substring(
        idx,
        nextCallback > idx ? nextCallback : src.length,
      );
      expect(
        after.contains('item.webViewKey.currentState?.highlightSelection('),
        isTrue,
        reason: 'reader onLinkClick 未对称高亮点中的词头/链接',
      );
    });

    test('app 外全局查词嵌套高亮父 iframe', () {
      final String src = controller.readAsStringSync();
      expect(
        src.contains('buildHighlightFrameScript('),
        isTrue,
        reason: 'global_lookup_controller 嵌套查词未高亮父卡片',
      );
      // BUG-1834：父层必须来自 host stamp 的 __frameId，不能默认当前 top；用来源层
      // index + 匹配字数驱动，且只在有词条时高亮。
      expect(
        src.contains("message['__frameId'] as String?"),
        isTrue,
        reason: '未读取 nested 消息的来源 frame id',
      );
      expect(
        src.contains('resolveNestedLookupParent('),
        isTrue,
        reason: '未按来源 frame 截断旧后代并解析父层 index',
      );
      expect(
        src.contains('parentIndex = _stack.length - 1'),
        isFalse,
        reason: '不得把当前最深层硬编码成 nested 来源父层',
      );
      expect(
        src.contains('buildHighlightFrameScript(sourceIndex,'),
        isTrue,
        reason: '未高亮真正触发查词的来源 iframe',
      );
      expect(
        src.contains('getFinalHighlightLength('),
        isTrue,
        reason: '未按匹配字数决定高亮长度',
      );

      // render 侧提供 host highlightFrame 通道脚本构建器。
      final String rsrc = render.readAsStringSync();
      expect(
        rsrc.contains('window.__globalLookupHost.highlightFrame('),
        isTrue,
        reason: 'buildHighlightFrameScript 未调用 host.highlightFrame 通道',
      );
    });

    // BUG-2054：同一次高亮回报的**整词 bbox** 必须回来重锚子卡。子卡打开时的锚点
    // 是 selection.js getSelectionRect() 给的「点击首字符」矩形（textSelected 早于
    // 词典查询，那时匹配长度还未知），跨行选区时它只覆盖点击那一行，子卡就贴在第一
    // 行下方、盖住选区第二行。host 侧回报本身由 global_lookup_host_test.mjs 真跑
    // 验证（§33b）；controller 不能 headless 实例化，故此处守它的接线。
    test('app 外嵌套子卡在第一次渲染前就拿到整词 bbox', () {
      final String src = maskComments(controller.readAsStringSync());
      expect(
        containsCodeLine(src, "handler != 'nestedWordAnchor'"),
        isTrue,
        reason: 'controller 未接收 host 回报的整词 bbox',
      );

      // 关键顺序：bbox 的往返必须发生在 push/render **之前**。app 外子卡不像
      // app 内那样有 markPendingReveal 挡着——_renderStack() 一走就交给 host 的
      // reveal 门，事后重锚会移动已可见的卡片，还会把整个覆盖窗的几何（union
      // bbox → overlaySize → 原生挪窗）在**每次**嵌套查词时重跑一遍（单行选区的
      // 整词 bbox 同样不等于首字符矩形）。
      final String body = methodBody(
        src,
        'Future<void> _lookupNested(',
      );
      final int awaitAnchor = body.indexOf('_highlightAndAwaitWordAnchor(');
      final int push = body.indexOf('_pushChildFrame(');
      expect(awaitAnchor, greaterThanOrEqualTo(0),
          reason: '_lookupNested 未等待整词 bbox');
      expect(push, greaterThanOrEqualTo(0), reason: '_lookupNested 未推子卡');
      expect(awaitAnchor, lessThan(push),
          reason: 'bbox 往返落在 push 之后 ⇒ 卡片弹出后跳位 + 覆盖窗二次挪动');
      expect(
        containsCodeLine(body, 'effectiveAnchor'),
        isTrue,
        reason: '拿到的整词 bbox 没被用作子卡锚点',
      );

      // 迟到 / 跨路由的回报按 token 认领，不按栈位置（否则会覆盖无关卡片的锚点）。
      final String handler = methodBody(
        src,
        'bool _maybeHandleNestedWordAnchor(',
      );
      expect(
        containsCodeLine(handler, '_pendingWordAnchors.remove(token)'),
        isTrue,
        reason: '整词 bbox 回报未按 token 路由 ⇒ 迟到回报会认领错卡片',
      );

      final File host = File('assets/popup/global_lookup_host.js');
      final String hsrc = maskJsComments(host.readAsStringSync());
      expect(
        hsrc.contains("postToHost('nestedWordAnchor'"),
        isTrue,
        reason: 'host.highlightFrame 又把 highlightSelection 的 bbox 丢了',
      );
      expect(
        hsrc.contains('anchorRectToScreen(target, bounds)'),
        isTrue,
        reason: '整词 bbox 必须走与原锚点同一条 iframe-local -> window-local 转换',
      );
      // highlightFrame 的契约是「绝不抛」：Dart 在等它的回报，一次抛出既毁掉
      // 已完成的查词，也让那个等待白白吃满超时。
      final String highlightBody = methodBody(
        hsrc,
        'function highlightFrame(frameIndex, count, token) {',
        lexicon: SourceLexicon.js,
      );
      // 用**最后一个** try/catch 定界：函数开头还有一个 `try { win = ... }`，拿
      // 第一个 try 当下界会让断言恒真（把这两行挪出 try 也照样绿）。
      final int tryAt = highlightBody.lastIndexOf('try {');
      final int catchAt = highlightBody.lastIndexOf('} catch');
      final int anchorAt = highlightBody.indexOf('anchorRectToScreen(');
      final int postAt = highlightBody.indexOf("postToHost('nestedWordAnchor'");
      expect(tryAt, greaterThanOrEqualTo(0));
      expect(catchAt, greaterThan(tryAt));
      for (final MapEntry<String, int> e in <String, int>{
        'anchorRectToScreen': anchorAt,
        'postToHost': postAt,
      }.entries) {
        expect(e.value, greaterThan(tryAt),
            reason: '${e.key} 落在 try 之外（highlightFrame 的契约是绝不抛）');
        expect(e.value, lessThan(catchAt),
            reason: '${e.key} 落在 catch 之后（highlightFrame 的契约是绝不抛）');
      }
    });
  });
}
