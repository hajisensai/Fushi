import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-1360 / BUG-2051：「已制卡的词旁 ↗『在 Anki 中打开卡片』按钮」可达性链路的
/// 源码守卫。锁住 openInAnki 从 popup.js（仅已制卡显示 + 点击调宿主）→ webview handler
/// → layer 透传 → 两条宿主车道（mixin / base_source_page）→ 仓库
/// （[BaseAnkiRepository.openWordInAnki]）全程接线，避免任一层漏接导致按钮点了没反应。
///
/// BUG-2051 之后这条链路只剩**一条判据**：宿主把 Anki 浏览器过滤到「Anki 认为这个词
/// 已有的卡」（第一字段 checksum，与画 ✓ 的查重同源），不再先按第一字段**名**反查
/// note id——那条反查看不见笔记类型不同的重复卡，于是 ✓ 说已制卡、↗ 说没有卡。
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
            'Future<AnkiOpenWordOutcome> Function(String expression, String reading)?'),
        isTrue,
        reason: 'onOpenInAnki field must be declared on the webview');
    expect(src.contains('return outcome.name;'), isTrue,
        reason: '三态结局必须回传，popup.js 靠它区分「没有卡」与「打不开」');
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
    expect(mixin.contains('Future<AnkiOpenWordOutcome> onOpenInAnki('), isTrue);
    expect(mixin.contains('onOpenInAnki: onOpenInAnki'), isTrue);
    expect(mixin.contains('repo.openWordInAnki(expression, reading)'), isTrue);

    final base = read('lib/src/pages/base_source_page.dart');
    expect(base.contains('Future<AnkiOpenWordOutcome> onOpenInAnkiFromPopup('),
        isTrue);
    expect(base.contains('onOpenInAnki: onOpenInAnkiFromPopup'), isTrue);
    expect(base.contains('repo.openWordInAnki(expression, reading)'), isTrue);
  });

  test('BUG-2051 仓库层：↗ 与查重同源，且没有第二条反查', () {
    final repo = read(
        '../packages/fushi_anki/lib/src/ankiconnect/ankiconnect_repository.dart');
    // 查询串来自与查重共用的构造器，直接喂给 guiBrowse——不再先 findNotes 拿 id。
    expect(repo.contains('ankiDuplicateSearchQuery('), isTrue);
    expect(repo.contains('service.guiBrowseQuery(query)'), isTrue);
    final int openWordAt =
        repo.indexOf('Future<AnkiOpenWordOutcome> openWordInAnki(');
    expect(openWordAt, greaterThan(-1));
    // 方法体 = 到下一个 @override 为止（不用固定窗口：那会随代码长短漂移，
    // 要么切掉半个方法、要么把邻居的实现算进来，两头都让断言失去判别力）。
    final int nextOverride = repo.indexOf('\n  @override', openWordAt);
    expect(nextOverride, greaterThan(openWordAt));
    final String body = repo.substring(openWordAt, nextOverride);
    expect(body.contains('findNotesByField('), isFalse,
        reason: '按第一字段名查是被删掉的那条判据，不得在 ↗ 路径上复活');
    expect(body.contains('ankiDuplicateSearchQuery('), isTrue);

    // 没有原生「按词打开」能力的后端走基类默认（按 note id，两者本就同源）。
    final base =
        read('../packages/fushi_anki/lib/src/base_anki_repository.dart');
    expect(
        base.contains('Future<AnkiOpenWordOutcome> openWordInAnki('), isTrue);
    expect(base.contains('AnkiOpenWordOutcome.noMatch'), isTrue,
        reason: '「Anki 可达但这个词没有卡」必须是独立的第三态');
  });

  test('BUG-2051 popup.js 只有一条车道（页内反查已删）', () {
    final src = read('assets/popup/popup.js');
    expect(src.contains('async function openWordInAnki('), isTrue);
    expect(src.contains('runInPageOpenInAnki'), isFalse);
    expect(src.contains('openOnly'), isFalse);
  });
}
