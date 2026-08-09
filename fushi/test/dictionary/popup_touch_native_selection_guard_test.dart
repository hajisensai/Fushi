import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-926 守卫（撤回 BUG-762）：词典弹窗触屏必须保留原生文本选区，否则安卓 ActionMode /
/// iOS 长按 callout 都消费不到选区 → 词典释义**无法复制**（1.2.0 用户报「查词界面文字无法
/// 复制」）。BUG-762 曾用 `_touchNoSelectStyleJs` 注入
/// `@media (pointer: coarse){html,body,body *{user-select:none!important}}` 全量碾平了
/// popup.css 已精细分区的选区设计，本守卫钉死它不得复活。
///
/// BUG-762 担心的「长按释义→系统 ActionMode 接管→弹窗关不掉」由 popup.js 的 document click
/// 处理器化解（有选区先 removeAllRanges 再 return，点一下取消选择、再点才关窗），本守卫一并
/// 钉死该机制存在，防止两头回归。
///
/// flutter test cwd = hibiki 包根。无头测试照不到真实 WebView，用源码扫描钉死接线。
void main() {
  String read(String rel) {
    final File f = File(rel);
    expect(f.existsSync(), isTrue, reason: 'missing $rel');
    return f.readAsStringSync();
  }

  String injectionSrc() =>
      read('lib/src/pages/implementations/popup_settings_injection.dart');

  test('弹窗注入体不得再全量禁掉触屏原生选区（否则释义无法复制）', () {
    final String src = injectionSrc();
    // 旧 BUG-762 的三个碾平特征——任一复活都会再次掐死触屏复制。
    expect(src.contains('fushi-popup-touch-noselect'), isFalse,
        reason: 'BUG-762 的全量触屏禁选 <style> 不得复活（会掐死释义复制，BUG-926）');
    expect(src.contains('body *{'), isFalse,
        reason: '不得对 body * 全量 user-select:none —— 会碾平 popup.css 的正文可选分区');
    expect(src.contains(r'$_touchNoSelectStyleJs'), isFalse,
        reason: 'head 模板不得再拼入触屏禁选注入');
  });

  test('popup.css 正文保持跨平台可选（安卓 ActionMode / iOS callout 复制的前提）', () {
    final String css = read('assets/popup/popup.css');
    expect(css.contains('-webkit-user-select: text'), isTrue,
        reason: '词典正文必须 user-select:text 才能被原生选区选中并复制');
    // 正文的可选性不得被任何触屏门控关掉——popup.css 里就不该出现 coarse 抑制。
    expect(css.contains('pointer: coarse'), isFalse,
        reason: 'popup.css 不得含触屏 user-select 抑制（会再次掐死触屏复制）');
  });

  test('popup.js click 先清原生选区再关窗（BUG-762 卡死的真实化解，非回归）', () {
    final String js = read('assets/popup/popup.js');
    expect(js.contains('removeAllRanges()'), isTrue,
        reason: '点击时须先 removeAllRanges 取消原生选区（有选区先取消、再点才关窗）');
  });
}
