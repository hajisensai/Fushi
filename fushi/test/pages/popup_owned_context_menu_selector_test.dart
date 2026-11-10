// 反馈 3UHYaFPP8g：Windows 查词弹窗里右键已制卡 ✓，弹出的是宿主的「搜索 / 复制」菜单，
// 而不是 popup.js 的覆写 / 查看选择单。
//
// 根因：`dictionary_popup_webview.dart` 的 Windows 右键路径按下即用 elementFromPoint
// 判断要不要给弹窗让位，但让位清单只写了 `.audio-button, .fushi-audio-menu`，漏了
// PR #2980 新加的已制卡 ✓ 管理手势（popup.js `bindMinedCardManageTriggers`）。
//
// 这里锁住两件事：让位选择器覆盖已制卡 ✓（且按 popup.js 的同一判据收窄，未制卡 + 不让位）；
// 宿主右键路径真的用这条选择器生成命中脚本。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart';

void main() {
  test('让位选择器覆盖 ♪、音频源菜单与已制卡 ✓', () {
    final List<String> parts = kPopupOwnedContextMenuSelector
        .split(',')
        .map((String s) => s.trim())
        .toList();
    expect(parts, contains('.audio-button'));
    expect(parts, contains('.fushi-audio-menu'));
    expect(
      parts,
      contains('.mine-button[data-mined="1"]:not([data-mining="1"])'),
      reason: '已制卡 ✓ 的右键由 popup.js 弹覆写 / 查看选择单，宿主菜单必须让位',
    );
    expect(
      parts.where((String s) => s == '.mine-button'),
      isEmpty,
      reason: '未制卡 + 的右键 popup.js 不拦，宿主搜索 / 复制菜单照常',
    );
  });

  test('选择器的 ✓ 判据与 popup.js bindMinedCardManageTriggers 一致', () {
    final String js = File('assets/popup/popup.js').readAsStringSync();
    final int start = js.indexOf('function bindMinedCardManageTriggers(');
    expect(start, greaterThanOrEqualTo(0));
    final int end = js.indexOf('\nfunction ', start + 1);
    final String body = js.substring(start, end);
    expect(
      body,
      contains("button.dataset.mined === '1' && button.dataset.mining !== '1'"),
      reason: 'popup.js 改了拦截判据时，宿主选择器要一起改',
    );
    expect(body, contains("addEventListener('contextmenu'"));
  });

  test('命中脚本嵌入整条选择器并带坐标', () {
    final String script = popupOwnedContextMenuHitTestJs(12.34, 56.78);
    expect(script, contains('document.elementFromPoint(12.3,56.8)'));
    expect(
      script,
      contains(
        'e.closest("${kPopupOwnedContextMenuSelector.replaceAll('"', r'\"')}")',
      ),
    );
  });

  test('Windows 右键路径先判让位、再弹宿主菜单', () {
    final String src = File(
      'lib/src/pages/implementations/dictionary_popup_webview.dart',
    ).readAsStringSync();
    final int menu = src.indexOf('Future<void> _showWindowsContextMenu(');
    expect(menu, greaterThanOrEqualTo(0));
    final int yieldCheck = src.indexOf(
      'if (await _secondaryClickHitsPopupOwnedMenu(globalPosition)) return;',
      menu,
    );
    final int showMenu = src.indexOf('await showFushiMenu<', menu);
    expect(yieldCheck, greaterThan(menu));
    expect(yieldCheck, lessThan(showMenu));
    expect(
      src,
      contains('source: popupOwnedContextMenuHitTestJs(p.dx, p.dy)'),
      reason: '命中测试必须用共享选择器生成，不许再内联一份清单',
    );
  });
}
