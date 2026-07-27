import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-712 ①（查词时延·触发段 3 跳并 1 跳）源码扫描守卫。
///
/// 阅读器点词此前要 3 次跨语言桥往返（JS onTap→Dart → Dart eval selectText→JS →
/// JS onTextSelected→Dart，Windows WebView2 单跳 5-15ms）才发起词典搜索。修复把
/// 点词门控（chrome 可见性 / highlightOnTap）做成 Dart 单写、JS 只读的镜像
/// `window.__hoshiTapGate`：门控通过时 tap 在 JS 侧直接跑同一个 selectText
/// （命中→onTextSelected、空白→onTapEmpty、链接/同字 toggle→静默，四分支与旧链
/// 逐一相同），3 跳并 1 跳；门控不过或镜像缺失回落旧 onTap 链，行为不变。
///
/// 该管线跨 Dart 字符串模板生成的 JS 与三个 part 文件，widget 测试驱动不到真实
/// WebView 手势，这里钉死结构性接线，防重构静默拆掉镜像或漏掉同步点：
///  1. setup 脚本注入镜像初始值（带当前 `$_showChrome` 真值）；
///  2. tap 分支存在 JS 直选 + 旧链回落两条路径；
///  3. Dart 侧 `_syncTapGateJs` 存在，且 chrome 翻转点（_toggleChrome）
///     与设置热更新（onSettingsChangedLive）都调用它。
void main() {
  final String webviewPart = File(
    'lib/src/pages/implementations/reader_hibiki/webview.part.dart',
  ).readAsStringSync();
  final String lookupPart = File(
    'lib/src/pages/implementations/reader_hibiki/lookup.part.dart',
  ).readAsStringSync();
  final String chromePart = File(
    'lib/src/pages/implementations/reader_hibiki/chrome.part.dart',
  ).readAsStringSync();
  final String mainShell = File(
    'lib/src/pages/implementations/reader_hibiki_page.dart',
  ).readAsStringSync();

  test('setup script seeds the tap gate mirror with live Dart truth', () {
    expect(
      webviewPart,
      contains('window.__hoshiTapGate = { chrome: C.showChrome, '
          'lookup: C.highlightOnTap, maxLen: 400 };'),
      reason: 'BUG-1140 第二阶段①后镜像初值随每章 config 下发（不再插进脚本源码），'
          '但仍必须是当前门控真值',
    );
  });

  test('tap branch does the JS-side direct select with an onTap fallback', () {
    final int gateCheck = webviewPart.indexOf(
      'shiftTap || (tapGate.chrome && tapGate.lookup)',
    );
    final int directSelect = webviewPart.indexOf(
      'window.hoshiSelection.selectText(x, y, tapGate.maxLen || 400, false);',
    );
    final int fallback = webviewPart.indexOf(
      "window.flutter_inappwebview.callHandler('onTap', x, y, shiftTap);",
    );
    expect(gateCheck, greaterThan(-1), reason: '门控判定必须存在');
    expect(directSelect, greaterThan(gateCheck),
        reason: '门控通过时 JS 直接 selectText（与旧链同一函数，3 跳并 1 跳）');
    expect(fallback, greaterThan(directSelect),
        reason: '门控不过/镜像缺失必须回落旧 onTap 链（行为安全网）');
  });

  test('_syncTapGateJs exists and every gate flip site calls it', () {
    expect(lookupPart, contains('void _syncTapGateJs()'),
        reason: 'Dart 单写镜像的同步助手必须存在');
    expect(lookupPart, contains("'window.__hoshiTapGate = '"),
        reason: '同步助手必须写同一个 JS 全局');

    // chrome 可见性的翻转点要同步镜像。
    final RegExp toggleBody =
        RegExp(r'void _toggleChrome\(\) \{[\s\S]*?\n  \}');
    expect(toggleBody.firstMatch(chromePart)?.group(0),
        contains('_syncTapGateJs();'),
        reason: '_toggleChrome 翻转 chrome 后必须同步 JS 门控镜像');

    // BUG-969：highlightOnTap 镜像同步随实时预览合并进 _liveSettingsRunner 动作体；
    // onSettingsChangedLive 只负责 trigger 该 runner（拖 slider 风暴收敛为背靠背串行趟）。
    // runner 定义在 hook 之前，故同步点必须落在 runner 动作内、且 hook 经 trigger 触发。
    final int runnerDef = mainShell.indexOf('CoalescedAsyncRunner(() async {');
    final int syncCall = mainShell.indexOf('_syncTapGateJs();', runnerDef);
    expect(runnerDef, greaterThan(-1),
        reason: '实时设置合并执行器 _liveSettingsRunner 必须存在');
    expect(syncCall, greaterThan(runnerDef),
        reason: 'highlightOnTap 镜像同步必须在合并执行器动作内（BUG-969）');
    final int liveHook = mainShell.indexOf('onSettingsChangedLive = ()');
    expect(liveHook, greaterThan(-1));
    expect(mainShell.indexOf('_liveSettingsRunner.trigger()', liveHook),
        greaterThan(liveHook),
        reason:
            'onSettingsChangedLive 必须经 _liveSettingsRunner.trigger() 触发（合并后同步镜像）');
  });
}
