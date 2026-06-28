import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-931 source guard: HomeDictionaryPage（首页查词）必须像 reader（base_source_page）/
/// video 一样 seed 一个**常驻隐藏热槽**并按词复用，而不是每次查词都 replaceStack 销毁+冷建
/// 弹窗 WebView。后者在 Windows inappwebview fork 下连点会让某次 WebView 析构撞上上一个
/// WebView 仍在途的 WebResourceRequested 拦截 deferral，触发 use-after-free 崩溃
/// （根因另在 in_app_webview.cpp 加了 alive_ 存活守卫 + dtor remove handler 根治）。
///
/// 本页 lookup 走 media_kit/原生 WebView，无法在 headless 下行为测试，故用源码守卫钉住接线。
void main() {
  String readSource() {
    return File(
      'lib/src/pages/implementations/home_dictionary_page.dart',
    ).readAsStringSync().replaceAll('\r\n', '\n');
  }

  test('home dictionary seeds and reuses a persistent warm popup slot', () {
    final String src = readSource();

    // 开页 seed 一个常驻隐藏热槽（低内存在 controller 内早退）。
    expect(src, contains('void _seedWarmPopup()'));
    expect(src, contains('_popup.seedWarmSlot()'),
        reason: 'seeding must delegate to the shared controller');
    expect(src, contains('appModel.lowMemoryMode'),
        reason: 'low-memory budget threaded into the controller');
    expect(src, contains('_seedWarmPopup();'),
        reason: 'initState 的成功路径必须 seed 热槽');

    // 顶层查词复用热槽，而不是 replaceStack 冷建新 WebView。
    expect(src, contains('reuseWarmSlot: true'),
        reason: 'top-level lookups must reuse the warm slot, not replaceStack');
    expect(src, isNot(contains('replaceStack: true')),
        reason:
            '连点 replaceStack 反复 create/destroy WebView 正是 UAF 崩溃源，必须改为复用热槽');
  });

  test(
      'home dictionary keys visibility off hasVisiblePopup, keeps warm slot on clear',
      () {
    final String src = readSource();

    // 常驻热槽使 entries 永不空：返回 / barrier / pull 判据必须用 hasVisiblePopup（隐藏热槽不算）。
    expect(
        src, contains('bool get _hasVisiblePopup => _popup.hasVisiblePopup;'));
    expect(src, contains('canPop: !_hasActiveQuery && !_popup.hasVisiblePopup'),
        reason: 'back/exit must ignore the hidden warm slot');
    expect(src, contains('if (_popup.hasVisiblePopup) {'),
        reason: 'pop handling must key off visible popups, not raw stack size');

    // 清空 / 新查词必须保留热槽（pruneToWarmSlot），不能 clear 掉热 WebView。
    expect(src, contains('_popup.pruneToWarmSlot()'),
        reason: 'clear/new-search must keep the warm slot alive');
    expect(src, isNot(contains('_popup.clear();')),
        reason:
            'clearing the stack would dispose the warm WebView mid-session');
  });
}
