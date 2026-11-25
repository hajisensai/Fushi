// 反馈 3UHYaFPP8g：查词弹窗里已制卡 ✓ 的管理手势与 ♪ 的选源菜单各抄了一份「长按 / 右键 /
// 菜单键」绑定，长按只认 touch / pen，桌面鼠标按住无效，可提示写的是「右键或长按」。
// 现在两处都委托给 popup.js 的 bindPopupSecondaryActionTriggers（鼠标主键长按也算）。
// 行为断言在 node 真跑 popup.js 的 test/utils/misc/popup_asset_behavior_test.js
// （testMouseLongPress*，经 popup_headword_drag_copy_test.dart 接进 flutter test）；
// 本文件守住结构：不许再长出只认触屏的私有长按计时。
import 'dart:io';

import 'package:test/test.dart';

/// 截取 popup.js 里名为 [name] 的顶层函数体（到下一个顶层 `function` 为止）。
String _functionBody(String js, String name) {
  final int start = js.indexOf('function $name(');
  expect(start, greaterThanOrEqualTo(0), reason: 'popup.js 缺少 $name');
  final int end = js.indexOf('\nfunction ', start + 1);
  return js.substring(start, end < 0 ? js.length : end);
}

void main() {
  final String js = File('assets/popup/popup.js').readAsStringSync();

  test('✓ 与 ♪ 的次级菜单手势都走共享绑定', () {
    for (final String binder in <String>[
      'bindMinedCardManageTriggers',
      'bindAudioSourceMenuTriggers',
    ]) {
      final String body = _functionBody(js, binder);
      expect(
        body,
        contains('bindPopupSecondaryActionTriggers(button'),
        reason: '$binder 必须委托共享绑定',
      );
      expect(
        body,
        isNot(contains("addEventListener('pointerdown'")),
        reason: '$binder 不许再自挂长按计时',
      );
    }
  });

  test('共享绑定的长按认鼠标主键，不只认触屏', () {
    final String predicate = _functionBody(js, 'isPopupLongPressPointer');
    expect(predicate, contains("e.pointerType === 'mouse' && e.button === 0"));
    expect(
      js,
      isNot(contains("e.pointerType !== 'touch' && e.pointerType !== 'pen'")),
      reason: '只认触屏的长按早退会让桌面鼠标长按失效',
    );
  });

  test('三份 popup.js 镜像一致', () {
    for (final String mirror in <String>[
      'assets/browser_extension/vendor/popup.js',
      '../tools/browser-extension/vendor/popup.js',
    ]) {
      expect(File(mirror).readAsStringSync(), js, reason: '$mirror 未同步');
    }
  });
}
