import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码守卫：阅读器/有声书（base_source_page）弹窗层与加载占位层必须带稳定 key。
///
/// 与 mixin 侧 BUG-941 同根因：dismiss barrier（`hasVisiblePopup || searching` 时
/// 插到 Stack children[0]）与搜索占位层出现/消失时，弹窗层在 children 中前/后移一
/// 位。若顶层 [Positioned] 无 key，Flutter 按位置把相邻层的元素错配更新、再拆掉旧
/// 位置的平台 WebView——常驻热槽被冷重载（popup.html + 209KB popup.js 整包重来，
/// 「第一次查词慢」的直接元凶），Windows 上甚至只剩空白弹窗外壳。
///
/// 行为级驱动需要真实 InAppWebView 平台视图（headless 不可得），故钉调用点不变量
/// （与 dictionary_popup_eager_mount_guard_test / parked_popup_layer_dedup_test
/// 同款守卫层）。
void main() {
  final String base =
      File('lib/src/pages/base_source_page.dart').readAsStringSync();
  final String mixin = File(
    'lib/src/pages/implementations/dictionary_page_mixin.dart',
  ).readAsStringSync();

  test('base _buildPopupLayer 的 parkedPopupLayer 以 entry 身份钉 key', () {
    final int start = base.indexOf('Widget _buildPopupLayer(');
    expect(start, greaterThanOrEqualTo(0));
    final String body = base.substring(start);
    expect(body.contains('key: ObjectKey(item)'), isTrue,
        reason: 'barrier/占位层插拔时弹窗层必须按身份搬位，而不是被按位置错配拆建'
            '原生 WebView（热槽冷重载）');
  });

  test('base 加载占位层 Positioned 带稳定 key', () {
    final int start = base.indexOf('Widget _buildLoadingPlaceholder(');
    expect(start, greaterThanOrEqualTo(0));
    final int end = base.indexOf('Widget _buildPopupLayer(');
    expect(end, greaterThan(start), reason: '占位方法应在弹窗层方法之前');
    final String body = base.substring(start, end);
    expect(
        body.contains(
            "key: const ValueKey<String>('base-source-popup-loading-placeholder')"),
        isTrue,
        reason: '占位层无 key 时，其插拔同样会让后续 keyed/非 keyed 子项错配');
  });

  test('mixin 侧 BUG-941 key 仍在（同族两处一起守）', () {
    expect(mixin.contains('key: ObjectKey(entry)'), isTrue,
        reason: 'mixin buildNestedPopupLayer 的 entry 身份 key 不得回归');
  });

  test('Android 独立查词窗（popup_dictionary_page）弹窗层同样以 entry 钉 key', () {
    final String popupPage = File(
      'lib/src/pages/implementations/popup_dictionary_page.dart',
    ).readAsStringSync();
    final int call = popupPage.indexOf('return parkedPopupLayer(');
    expect(call, greaterThanOrEqualTo(0));
    final String body = popupPage.substring(call, call + 400);
    expect(body.contains('key: ObjectKey(entry)'), isTrue,
        reason: '独立查词窗与三个 in-app 宿主同机制（隐藏热槽/占位层插拔），'
            '无 key 同样会拆建原生 WebView 冷重载热槽');
  });
}
