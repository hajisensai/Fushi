// 「制卡目标」切换键（#fiwDIpFep7）只在卡片落在本机时出现：查词结果来自别的设备
// （手机遥控电脑制卡，`popupResourceSource` 非 null）时卡片用那台设备的 Anki 配置，
// 本机切配置 / 牌组对卡片不起作用，键不该出现。两条 PR 各自都对，合在一起才出这个
// 语义冲突（#2083 × #2109），这里把判据钉住。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

void main() {
  String flat(String path) => maskComments(
    File(path).readAsStringSync(),
  ).replaceAll(RegExp(r'\s+'), '');

  test('查词 mixin：结果来自别的设备时不显示制卡目标切换键', () {
    final String mixin = flat(
      'lib/src/pages/implementations/dictionary_page_mixin.dart',
    );
    final int at = mixin.indexOf('showMiningTargetSwitch:');
    expect(at, isNot(-1));
    final int end = mixin.indexOf(',onDuplicateCheck:', at);
    expect(end, greaterThan(at));
    expect(
      mixin.substring(at, end),
      contains('popupResourceSource==null'),
      reason: '远端结果（popupResourceSource 非 null）上的切换对卡片不起作用',
    );
  });

  test('手机遥控页确实把结果标成来自别的设备（判据有真宿主）', () {
    final String remote = flat(
      'lib/src/pages/implementations/video_remote_page.dart',
    );
    expect(
      remote,
      contains('DictionaryPopupResourceSource?getpopupResourceSource=>'),
    );
    expect(remote, isNot(contains('getpopupResourceSource=>null')));
  });
}
