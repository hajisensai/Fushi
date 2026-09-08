import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_desktop_chrome.dart';

/// BUG-2260 守卫：阅读设置 / 导航抽屉开着时，点正文必须把抽屉关掉。
///
/// 根因是 BUG-1692 那套 macOS 平台视图命中模型的**另一面**：engine 只把「平台视图
/// 之后**画了东西**的 Flutter 图层」的 `paint_region` 写进
/// `FlutterMutatorView._hitTestIgnoreRegion`，落在忽略区里的鼠标事件才会被 Flutter
/// 截住。而 [showReaderSideSheet] 用的是 `barrierColor: Colors.transparent`
/// （ッツ 形态不给正文压暗），透明遮罩一个像素都不画 ⇒ 在 macOS 上等于不存在 ⇒
/// 点正文的鼠标事件直穿到 WKWebView，`barrierDismissible: true` 永远等不到那次
/// 点击，抽屉关不掉。
///
/// 修法不是给遮罩硬塞一层几乎不可见的颜色（那是拿观感换命中，还得赌 engine 的
/// cull rect 细节），而是接住 WebView **已经收到**的那次点击：正文 tap 桥在
/// 「抽屉正压着正文」时先关抽屉并吞掉该次点击。其它平台遮罩照常吃点击、JS 侧根本
/// 不会上报 tap，判据恒假、行为零变化。
void main() {
  group('BUG-2260 readerWebViewPointerClosesSideSheet 判据', () {
    test('抽屉开着且阅读器不是顶层路由 → 这次点击用来关抽屉', () {
      expect(
        readerWebViewPointerClosesSideSheet(
          sideSheetOpen: true,
          readerRouteIsCurrent: false,
        ),
        isTrue,
      );
    });

    test('没开抽屉 → 正常正文点击（翻页 / 查词 / 收放控制栏）', () {
      expect(
        readerWebViewPointerClosesSideSheet(
          sideSheetOpen: false,
          readerRouteIsCurrent: false,
        ),
        isFalse,
        reason: '压在正文上的是别的路由（图片查看器 / 制卡对话框…）时不得借道关它——'
            '那些遮罩有实色，macOS 上照常吃点击，根本不会走到这里',
      );
    });

    test('抽屉标志还没复位但阅读器已回到顶层 → 不吞点击', () {
      expect(
        readerWebViewPointerClosesSideSheet(
          sideSheetOpen: true,
          readerRouteIsCurrent: true,
        ),
        isFalse,
        reason: '关闭动画尾巴上误吞一次正文点击 = 用户「关掉面板后第一下点击没反应」',
      );
    });
  });

  group('BUG-2260 源码守卫：正文 tap 桥接入点', () {
    test('_sideSheetOpen 只在 showReaderSideSheet 两侧翻，且 finally 复位', () {
      final File f = File(
        'lib/src/pages/implementations/reader_fushi/chrome.part.dart',
      );
      expect(f.existsSync(), isTrue, reason: 'chrome part 被移动了，守卫需同步更新');
      final String src = f.readAsStringSync();

      final int at = src.indexOf('await showReaderSideSheet<void>(');
      expect(at, greaterThan(-1), reason: '抽屉呈现调用改名了，守卫需同步更新');

      final String before = src.substring((at - 400).clamp(0, at), at);
      expect(
        before.contains('_sideSheetOpen = true'),
        isTrue,
        reason: '旗没在抽屉打开前置位 ⇒ macOS 上点正文仍然关不掉抽屉（BUG-2260 回归）',
      );
      final String after = src.substring(at, at + 600);
      expect(
        after.contains('} finally {') &&
            after.contains('_sideSheetOpen = false'),
        isTrue,
        reason: '复位不在 finally 里 ⇒ 抽屉内抛异常后旗永久顶着 ⇒ 此后每一次正文点击都被'
            '当成「关遮罩」吞掉，正文彻底点不动',
      );
    });

    test('七条正文 tap 桥都必须先过 _closeSideSheetForWebViewPointer', () {
      final String src = File(
        'lib/src/pages/implementations/reader_fushi/webview.part.dart',
      ).readAsStringSync();

      // 桥名 → 该 handler 体内必须出现的门控调用。逐个定位 handlerName，再在其后
      // 一小段窗口里找门控——窗口取到下一个 handler 注册之前即可。
      const List<String> bridges = <String>[
        'onTap', // 正文点击（命中文字 / 唤出控制栏）
        'onTapEmpty', // 正文空白
        'onVnBlankTap', // VN 模式空白
        'onLyricsTapEmpty', // 歌词页空白
        'onSpreadTapEmpty', // 双页 spread 空白
        'onImageTap', // 插图（spread / 图片章几乎整屏都是它）
        'onCueTap', // 有声书逐句跳播
      ];
      for (final String bridge in bridges) {
        final int at = src.indexOf("handlerName: '$bridge',");
        expect(at, greaterThan(-1), reason: '$bridge 桥改名了，守卫需同步更新');
        final int next = src.indexOf('addJavaScriptHandler(', at);
        final String body = src.substring(
          at,
          next > at ? next : (at + 1200).clamp(0, src.length),
        );
        expect(
          body.contains('_closeSideSheetForWebViewPointer()'),
          isTrue,
          reason: '$bridge 少了门控 ⇒ macOS 上抽屉开着时点正文会照常翻页 / 查词 / 跳播，'
              '抽屉却纹丝不动（BUG-2260）',
        );
      }
    });

    test('门控用 maybePop —— 不得绕过阅读器 PopScope 直接 pop', () {
      final String src = File(
        'lib/src/pages/implementations/reader_fushi/chrome.part.dart',
      ).readAsStringSync();
      final int at = src.indexOf('bool _closeSideSheetForWebViewPointer() {');
      expect(at, greaterThan(-1), reason: '门控方法改名了，守卫需同步更新');
      final String body = src.substring(at, at + 700);
      expect(
        body.contains('maybePop()'),
        isTrue,
        reason: '直接 Navigator.pop() 会绕过 PopScope 回调链（BUG-782 同族）',
      );
    });
  });
}
