import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// 取 [anchor] 起、到**同层分号**为止的那条声明/语句原文。
///
/// 为什么不用 [methodBody]：被守的 `nativeSelectionTextInvocation` 是**箭头**成员
/// （`... () => '…';`），没有花括号方法体；methodBody 会一路找到下一个带 `{` 的成员
/// 上去，窗口指向错误对象。这里的右界是「括号深度归零处的 `;`」——一条语句的天然
/// 结尾，与它写几行、串里有多少括号无关（配对跑在掩码串上，串/注释里的括号与分号
/// 不参与）。
String statementAt(String src, String anchor) {
  final int start = maskComments(src).indexOf(anchor);
  expect(start, greaterThanOrEqualTo(0), reason: '源码中找不到锚点：$anchor');
  final String structural = maskCommentsAndStrings(src);
  int depth = 0;
  for (int i = start; i < structural.length; i++) {
    final String c = structural[i];
    if (c == '(' || c == '[' || c == '{') depth++;
    if (c == ')' || c == ']' || c == '}') depth--;
    if (c == ';' && depth == 0) return src.substring(start, i + 1);
  }
  fail('锚点 $anchor 之后找不到同层分号（语句未收口？）');
}

/// BUG-402 / BUG-4165 源码守卫：阅读器桌面复制兼容层（Windows Ctrl+C、macOS ⌘C）
/// 接线不得回退。
///
/// 复制链路涉 WebView2 键盘转发 / macOS first responder（BUG-2948），widget 测试照
/// 不到真实复制，故这里用源码扫描钉死三件事：① 键事件处理调用纯谓词
/// desktopShouldHandleCopyGesture，且把 Windows 与 macOS 两个平台事实都传进去
/// （BUG-4165：旧版只传 isWindows，macOS 的 ⌘C 永远到不了 WKWebView）；② 取的是浏览器原生 getSelection（window.getSelection），
/// **不是** fushiSelection 查词选区；③ 命中后写系统剪贴板 Clipboard.setData。
void main() {
  final File caret = File(
    'lib/src/pages/implementations/reader_fushi/caret.part.dart',
  );
  final File scripts = File('lib/src/reader/reader_selection_scripts.dart');

  test('caret.part.dart：复制键 → 谓词门控 Windows/macOS + 取原生选区 + 写剪贴板', () {
    expect(caret.existsSync(), isTrue, reason: 'caret.part.dart 不存在，路径变了须更新守卫');
    final String src = caret.readAsStringSync();

    // ① 走纯谓词，且 Windows / macOS 两个平台事实都传进去。
    final String call = statementAt(src, 'if (desktopShouldHandleCopyGesture(');
    expect(
      call,
      contains('isWindows: isWindowsPlatform'),
      reason: 'Windows 的 Ctrl+C 到不了 WebView2（BUG-402），谓词必须拿到 isWindowsPlatform',
    );
    expect(
      call,
      contains('isMacOS: isMacOSPlatform'),
      reason:
          'macOS 点正文后 first responder 通常仍是 FlutterView，⌘C 的 copy: 到不了 WKWebView'
          '（BUG-4165 / BUG-2948），谓词必须拿到 isMacOSPlatform',
    );

    // ② + ③ 经 helper 取原生选区写剪贴板。
    expect(
      src,
      contains('_copyNativeSelectionToClipboard'),
      reason: '命中复制手势必须调 _copyNativeSelectionToClipboard',
    );
    expect(
      src,
      contains('Clipboard.setData'),
      reason: '复制必须写系统剪贴板 Clipboard.setData',
    );
    expect(
      src,
      contains('nativeSelectionTextInvocation'),
      reason: '必须取浏览器原生选区，不碰 fushiSelection 查词选区',
    );
  });

  test('caret.part.dart：复制按可见层叠顺序分派（弹窗各层 → 歌词 / 正文），BUG-4165', () {
    // macOS 上 Flutter 焦点从不跟随点击进入平台视图（AppKitView 只在引擎 onFocus 时
    // requestFocus，macOS 引擎不发；BUG-3131），弹窗 / 歌词里拖选后的 ⌘C 也落在阅读器
    // 的 _focusNode 上。复制若只读正文 _controller，弹窗 / 歌词里的选区永远复制不到，
    // 正文残留旧选区时还会复制出错误文字。
    final String src = caret.readAsStringSync();
    final String body = methodBody(
      src,
      'Future<void> _copyNativeSelectionToClipboard(',
    );
    expect(
      body,
      contains('copyFromTopmostSurfaceWithSelection('),
      reason: '取选区必须走自顶向下的层叠分派，不能只认一个 controller',
    );
    final int popups = body.indexOf('_caretVisiblePopupStatesTopDown');
    final int forHost = body.indexOf('copyNativeSelectionForHost');
    expect(popups, greaterThanOrEqualTo(0), reason: '可见弹窗各层必须进候选');
    expect(forHost, greaterThan(popups), reason: '弹窗层经弹窗自己的复制入口取选区');
    expect(
      body,
      contains('_lyricsOverlayShown'),
      reason: '歌词覆盖层显示时阅读面是歌词 WebView（正文被盖住）',
    );
    expect(
      statementAt(body, 'final InAppWebViewController? readingSurface'),
      allOf(contains('_lyricsController'), contains('_controller')),
    );
    expect(
      body.lastIndexOf('readingSurface'),
      greaterThan(forHost),
      reason: '阅读面排在所有弹窗层之后（弹窗盖在阅读面之上）',
    );
  });

  test(
    'reader_selection_scripts.dart：取 window.getSelection 而非 fushiSelection',
    () {
      final String src = scripts.readAsStringSync();
      final int start = src.indexOf('nativeSelectionTextInvocation');
      expect(
        start,
        greaterThanOrEqualTo(0),
        reason: '缺 nativeSelectionTextInvocation',
      );
      // invocation 方法体里必须是浏览器原生 getSelection。
      final String body = src.substring(start, start + 200);
      expect(body, contains('window.getSelection'), reason: '复制取的是浏览器原生选区');
      expect(
        body.contains('fushiSelection'),
        isFalse,
        reason: '不得用 fushiSelection 查词选区（BUG-368 注释，是另一套）',
      );
    },
  );
}
