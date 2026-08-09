import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-1360：「已制卡的词旁『在 Anki 中打开卡片』按钮」可达性链路的源码守卫。锁住
/// openInAnki 从 popup.js（仅已制卡显示 + 点击调宿主）→ webview handler → layer 透传
/// → 两条宿主车道（mixin / base_source_page）→ 编排（openMinedCardInAnki）全程接线，
/// 避免任一层漏接导致按钮点了没反应或永不出现。
void main() {
  String read(String relativePath) {
    final file = File(relativePath);
    expect(file.existsSync(), isTrue, reason: 'missing $relativePath');
    return file.readAsStringSync();
  }

  test('popup.js: open-in-anki button only shows when mined and calls the host',
      () {
    final src = read('assets/popup/popup.js');
    // 图标与按钮存在。
    expect(src.contains('openInAnki:'), isTrue,
        reason: 'openInAnki icon path must exist in ICON_PATHS');
    expect(src.contains("className: 'inline-action-button open-anki-button"),
        isTrue);
    // 点击调宿主 openInAnki 处理器（带 expression/reading）。
    expect(src.contains("'openInAnki', { expression, reading }"), isTrue,
        reason: 'the button click must call the openInAnki host handler');
    // 可见性跟随真实制卡态：setMineState 据 isMined 切换隐藏类（不装饰）。
    expect(
        src.contains(
            "openAnkiButton.classList.toggle('open-anki-hidden', !isMined)"),
        isTrue,
        reason: 'button visibility must be driven by the real mined state');
  });

  test('popup.css: open-anki-button has a hidden state and shared base look',
      () {
    final css = read('assets/popup/popup.css');
    expect(css.contains('.open-anki-button.open-anki-hidden'), isTrue);
    expect(css.contains('.open-anki-button,'), isTrue,
        reason: 'must share the audio/favorite/mine base button styling');
  });

  test('extension vendor mirrors carry the new button (byte-parity elsewhere)',
      () {
    for (final root in const <String>[
      'assets/browser_extension/vendor',
      '../tools/browser-extension/vendor',
    ]) {
      expect(read('$root/popup.js').contains('open-anki-button'), isTrue,
          reason: '$root/popup.js missing the open-in-anki button');
      expect(read('$root/content.css').contains('.open-anki-button'), isTrue,
          reason: '$root/content.css missing the scoped open-anki-button rule');
    }
  });

  test('dictionary_popup_webview.dart registers the openInAnki JS handler', () {
    final src =
        read('lib/src/pages/implementations/dictionary_popup_webview.dart');
    expect(src.contains("handlerName: 'openInAnki'"), isTrue);
    expect(src.contains('widget.onOpenInAnki!'), isTrue);
    expect(
        src.contains(
            'Future<void> Function(String expression, String reading)? onOpenInAnki'),
        isTrue,
        reason: 'onOpenInAnki field must be declared on the webview');
  });

  test('dictionary_popup_layer.dart threads onOpenInAnki to the webview', () {
    final src =
        read('lib/src/pages/implementations/dictionary_popup_layer.dart');
    expect(src.contains('this.onOpenInAnki'), isTrue);
    expect(src.contains('onOpenInAnki: onOpenInAnki'), isTrue);
  });

  test('both host lanes provide onOpenInAnki and wire it into the layer', () {
    final mixin =
        read('lib/src/pages/implementations/dictionary_page_mixin.dart');
    expect(
        mixin.contains(
            'Future<void> onOpenInAnki(String expression, String reading)'),
        isTrue);
    expect(mixin.contains('onOpenInAnki: onOpenInAnki'), isTrue);
    expect(mixin.contains('openMinedCardInAnki('), isTrue);

    final base = read('lib/src/pages/base_source_page.dart');
    expect(
        base.contains(
            'Future<void> onOpenInAnkiFromPopup(String expression, String reading)'),
        isTrue);
    expect(base.contains('onOpenInAnki: onOpenInAnkiFromPopup'), isTrue);
    expect(base.contains('openMinedCardInAnki('), isTrue);
  });

  test('orchestrator: single opens directly, empty toasts, many pick', () {
    final src = read('lib/src/anki/anki_mined_card_action_sheet.dart');
    expect(src.contains('Future<void> openMinedCardInAnki('), isTrue);
    // 无命中 → toast，不静默。
    expect(src.contains('if (matches.isEmpty)'), isTrue);
    expect(src.contains('t.anki_open_no_card'), isTrue);
    // 单卡 → 直接 openNoteInAnki。
    expect(src.contains('if (matches.length == 1)'), isTrue);
    expect(src.contains('repo.openNoteInAnki(matches.first.noteId)'), isTrue);
    // 多卡 → 轻量选择。
    expect(src.contains('showAnkiOpenNotePicker('), isTrue);
  });
}
