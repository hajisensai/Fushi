import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-1007/1008：「点 ✓ 弹操作选择（覆写/新增重复卡/查看·在 Anki 中打开）」可达性
/// 链路的源码守卫。锁住 minedCardAction 在 popup.js → webview → layer → 两条宿主车道
/// （mixin / base_source_page）全程接线，避免任一层漏接导致点 ✓ 又回到「静默无反应」。
void main() {
  String read(String relativePath) {
    final file = File(relativePath);
    expect(file.existsSync(), isTrue, reason: 'missing $relativePath');
    return file.readAsStringSync();
  }

  test('popup.js: clicking a mined ✓ invokes the host minedCardAction handler',
      () {
    final src = read('assets/popup/popup.js');
    // The ✓ click (mined, not latest) must hand off to the host, not silently
    // return.
    expect(src.contains('async function minedCardAction('), isTrue);
    expect(src.contains("callHandler('minedCardAction', fields)"), isTrue);
    expect(src.contains('const reply = await minedCardAction('), isTrue,
        reason: 'the dataset.mined branch must call minedCardAction');
  });

  test('dictionary_popup_webview.dart registers the minedCardAction JS handler',
      () {
    final src =
        read('lib/src/pages/implementations/dictionary_popup_webview.dart');
    expect(src.contains("handlerName: 'minedCardAction'"), isTrue);
    expect(src.contains('widget.onMinedCardAction!'), isTrue);
    expect(
        src.contains(
            'Future<MinePopupResult> Function(Map<String, String> fields)?\n      onMinedCardAction'),
        isTrue,
        reason: 'onMinedCardAction field must be declared on the webview');
  });

  test('dictionary_popup_layer.dart threads onMinedCardAction to the webview',
      () {
    final src =
        read('lib/src/pages/implementations/dictionary_popup_layer.dart');
    expect(src.contains('this.onMinedCardAction'), isTrue);
    expect(src.contains('onMinedCardAction: onMinedCardAction'), isTrue);
  });

  test('both host lanes provide onMinedCardAction and wire it into the layer',
      () {
    final mixin =
        read('lib/src/pages/implementations/dictionary_page_mixin.dart');
    expect(
        mixin.contains(
            'Future<MinePopupResult> onMinedCardAction(Map<String, String> fields)'),
        isTrue);
    expect(mixin.contains('onMinedCardAction: onMinedCardAction'), isTrue);
    expect(mixin.contains('runAnkiMinedCardAction('), isTrue);

    final base = read('lib/src/pages/base_source_page.dart');
    expect(base.contains('Future<MinePopupResult> onMinedCardActionFromPopup('),
        isTrue);
    expect(
        base.contains('onMinedCardAction: onMinedCardActionFromPopup'), isTrue);
    expect(base.contains('runAnkiMinedCardAction('), isTrue);
  });

  test('action sheet orchestrator falls back to mineNew when nothing matches',
      () {
    final src = read('lib/src/anki/anki_mined_card_action_sheet.dart');
    expect(
        src.contains('Future<AnkiCardMutationResult> runAnkiMinedCardAction('),
        isTrue);
    // No matches (card deleted since detection) -> mine fresh, never silent.
    expect(src.contains('if (matches.isEmpty)'), isTrue);
    expect(src.contains('return mineNew();'), isTrue);
    // The viewer offers overwrite + open-in-Anki.
    expect(src.contains('showAnkiNoteViewer'), isTrue);
    expect(src.contains('openNoteInAnki'), isTrue);
  });

  // TODO-1007 健壮性守卫：三处 await 宿主回调必须被 try/catch 包裹，catch 内复位
  // _busy 并给用户反馈，否则宿主网络/平台通道抛错时 action sheet 卡在进度条无反应。
  test('mineNew/overwrite await 三处都被 try/catch 包裹且 catch 内复位 _busy + 反馈', () {
    final src = read('lib/src/anki/anki_mined_card_action_sheet.dart');
    // 三处 await：_runMineNew / _runOverwrite / _AnkiNoteViewerDialogState._overwrite。
    expect(
      'try {'.allMatches(src).length,
      greaterThanOrEqualTo(3),
      reason: '三处宿主回调 await 必须各有 try',
    );
    // catch 块固定形态：复位 _busy（避免卡死）+ 弹失败反馈。三处都必须出现这条收口。
    const String catchReset =
        'setState(() => _busy = false);\n      HibikiToast.show(msg: t.anki_card_action_failed);';
    expect(
      catchReset.allMatches(src).length,
      3,
      reason: '三处 catch 必须复位 _busy 并弹 anki_card_action_failed 反馈',
    );
    // 失败分支早返回，不得继续走成功的 Navigator.pop。
    expect(src.contains('} catch (e) {'), isTrue);
  });
}
