import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-578 / TODO-1268 — 桌面悬浮字幕点词的程序化入口 [GlobalLookupController.lookupText]
/// 必须在进入 `_lookupExternal` 之前 **await 一次 `hide(notify:false)` 前置复位**，与全局
/// 热键 `_onHotKey` 的 TODO-1079(D) 前导复位对齐。
///
/// 真机根因：热键路径靠异步选区抓取的长让路让覆盖窗 hide→show 过渡与 host content-ready
/// 门在渲染前沉降；悬浮字幕点词零让路 + 快速连点，踩踏共享 reveal 状态，`overlaySize` 从不
/// 发出、覆盖窗只走 READY-SAFETY 空白兜底（点词“没有出现查词窗口”）。补上 await 前置 hide
/// 后，两条触发前导一致。覆盖窗真弹出依赖 native WebView2，headless 测不了，故本卷用源码
/// 扫描钉住这条时序契约防回归。
void main() {
  String read(String p) => File(p).readAsStringSync().replaceAll('\r\n', '\n');

  late String controller;
  setUpAll(
      () => controller = read('lib/src/lookup/global_lookup_controller.dart'));

  /// 抽出 `lookupText` 的**完整**函数体（签名到函数收尾的 `\n  }`）。
  ///
  /// BUG-1099 起 lookupText 开头多了一条被动流早退（命中「用户卡还在屏上」判据时
  /// 直接 `return true;`），旧写法「截到第一个 return true」会把前置 hide 整段切掉
  /// 而误报。改成取整个函数体：前置 hide 必须在 _lookupExternal 之前这条契约不变。
  String lookupTextBody(String src) {
    // lookupText 现在只是路由包装（把整次查词钉进一条 GlobalLookupRoute），真正的
    // 实现搬进了 _lookupTextRouted。前置 hide 的契约落在实现体上。
    const String sig = 'Future<bool> _lookupTextRouted(';
    final int at = src.indexOf(sig);
    expect(at, greaterThanOrEqualTo(0),
        reason: 'lookupText 程序化入口的实现必须存在（TODO-872）');
    // 包装层必须真的把实现钉进路由里，否则游戏内查词会打到桌面浮窗上。
    expect(src.contains('GlobalLookupChannel.runWithRoute('), isTrue,
        reason: 'lookupText 必须在一条确定的路由上下文里跑实现');
    // 收尾是独占一行的 `  }`；不能只找 `\\n  }`，那会先命中多行签名的
    // `  }) async {`。
    final int end = src.indexOf('\n  }\n', at);
    expect(end, greaterThan(at));
    return src.substring(at, end);
  }

  test('lookupText 在 _lookupExternal 前 await 一次 hide(notify:false) 复位', () {
    final String body = lookupTextBody(controller);
    final int hideAt =
        body.indexOf('await GlobalLookupChannel.hide(notify: false)');
    final int externalAt = body.indexOf('_lookupExternal(');
    expect(hideAt, greaterThanOrEqualTo(0),
        reason: 'BUG-578：程序化路径必须 await 前置 hide(notify:false) 复位覆盖窗，'
            '否则悬浮字幕连点会让 host 门被踩踏、覆盖窗空白');
    expect(externalAt, greaterThan(hideAt),
        reason: '前置 hide 复位必须在 _lookupExternal 之前');
  });

  test('前置复位用 notify:false（不被当成用户关窗 TODO-1233）', () {
    final String body = lookupTextBody(controller);
    // lookupText 体内对 hide 的调用一律 notify:false（between-lookups 复位，非用户关窗）。
    final RegExp anyHide = RegExp(r'GlobalLookupChannel\.hide\(');
    for (final Match m in anyHide.allMatches(body)) {
      final String tail = body.substring(m.start, m.start + 40);
      expect(tail.contains('notify: false'), isTrue,
          reason: 'lookupText 内的 hide 复位必须 notify:false');
    }
  });
}
