import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

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
    // BUG-1064：宿主自带原生对话框时（app 内）仍然必须把点击交给 minedCardAction。
    // 这一支现在写在三元里（另一支是 app 外的页内面板），所以钉调用本身而不是旧的
    // `const reply = await ...` 行形。
    expect(src.contains('parseMineResult(await minedCardAction('), isTrue,
        reason: 'the dataset.mined branch must still call minedCardAction '
            'when the host has a native dialog');
    expect(src.contains('hasNativeMinedCardAction()'), isTrue,
        reason: 'the two lanes must be selected by the host capability flag');
  });

  /// BUG-1064：app 外表面（Windows 裸 WebView2 剪贴板面板 / 瞬态查词窗、浏览器扩展）
  /// 没有 Flutter 层可以呈现这个对话框，它们的 minedCardAction 只会被立刻解析成 null。
  /// 旧代码把 null 当「宿主已处理」→ 点已制卡的 ✓ 完全没反应。这一组钉死替代车道：
  /// popup.js 自己画页内面板，数据走两根新 deferred 桥，动作复用 updateEntry/mineEntry。
  group('BUG-1064 app 外点 ✓ 走页内面板（不得再静默）', () {
    test('popup.js 有页内面板与它的两根数据桥', () {
      final src = read('assets/popup/popup.js');
      expect(src.contains('function showMinedCardActionPanel('), isTrue);
      expect(src.contains('async function runInPageMinedCardAction('), isTrue);
      expect(src.contains("'findMinedMatches'"), isTrue,
          reason: '命中列表必须来自宿主真值（repo.findMatchingNotes）');
      expect(src.contains("'openMinedNote'"), isTrue);
      // 覆写/新增必须复用既有两根桥，不得新开写路径。
      expect(src.contains("if (choice.action === 'overwrite')"), isTrue);
      expect(src.contains('await updateEntry('), isTrue);
      expect(src.contains("if (choice.action === 'duplicate')"), isTrue);
      expect(src.contains('await mineEntry('), isTrue);
      // 面板里产生原生选区会被 selection.js 当成查词，必须禁选。
      final css = read('assets/popup/popup.css');
      expect(css.contains('.mined-action-panel'), isTrue);
      expect(css.contains('.mined-action-backdrop'), isTrue);
      expect(css.contains('user-select: none'), isTrue);
      expect(css.contains('html.mined-action-open'), isTrue,
          reason: '瞬态窗高度按内容收缩，面板打开期间必须撑最小高度否则被裁');
    });

    test('↗「在 Anki 中打开」同一分流，app 外走页内三分支', () {
      final src = read('assets/popup/popup.js');
      // ↗ 的宿主桥 openInAnki 在 app 外同样只会回 null，所以它必须和 ✓ 用同一个
      // 能力标志分流，不得无条件 callHandler。
      expect(src.contains('async function runInPageOpenInAnki('), isTrue);
      expect(
          src.contains(
              'await runInPageOpenInAnki(openAnkiButton, expression, reading)'),
          isTrue,
          reason: 'app 外的 ↗ 必须走页内车道，否则又是点了没反应');
      // 三分支：无命中提示 / 单卡直开 / 多卡 openOnly 面板。
      expect(src.contains('function showInlineHint('), isTrue,
          reason: 'app 外没有 toast，无命中必须就地提示而不是静默');
      expect(src.contains('{ openOnly: true }'), isTrue,
          reason: '多卡只列卡片+打开，不混入覆写/新增（那是 ✓ 的职责）');
      final css = read('assets/popup/popup.css');
      expect(css.contains('.inline-hint'), isTrue);
    });

    test('C++ 把两根新桥列入 DEFERRED（minedCardAction 仍保持即时 null）', () {
      final cpp = read('windows/runner/global_lookup_window.cpp');
      expect(cpp.contains('body.find("\\"findMinedMatches\\"")'), isTrue);
      expect(cpp.contains('body.find("\\"openMinedNote\\"")'), isTrue);
      expect(cpp.contains('body.find("\\"minedCardAction\\"")'), isFalse,
          reason: 'minedCardAction 是 Flutter 对话框，app 外无法呈现，'
              '仍然不得纳入 deferred——替代方案是 popup.js 的页内面板');
    });

    test('Dart 侧解析两根新桥（复用 repo 的既有查找/打开）', () {
      final src = read('lib/src/lookup/overlay_bridge_handlers.dart');
      expect(src.contains("case 'findMinedMatches':"), isTrue);
      expect(src.contains("case 'openMinedNote':"), isTrue);
      expect(
          src.contains('repo.findMatchingNotes(expression, reading)'), isTrue);
      expect(src.contains('repo.openNoteInAnki(noteId)'), isTrue);
    });

    test('注入把「宿主有没有原生对话框」告诉 popup.js', () {
      final src =
          read('lib/src/pages/implementations/popup_settings_injection.dart');
      expect(
          src.contains(
              'window.__fushiMinedCardActionNative = \${!options.globalLookup};'),
          isTrue,
          reason: 'app 外（globalLookup）恒 false → 页内面板；'
              'app 内恒 true → Flutter 对话框');
    });
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
    final String catchReset = compactCode('setState(() => _busy = false); '
        'FushiToast.show(msg: t.anki_card_action_failed,');
    expect(
      catchReset.allMatches(compactCode(src)).length,
      3,
      reason: '三处 catch 必须复位 _busy 并弹 anki_card_action_failed 反馈',
    );
    // 失败分支早返回，不得继续走成功的 Navigator.pop。
    expect(src.contains('} catch (e) {'), isTrue);
  });
}
