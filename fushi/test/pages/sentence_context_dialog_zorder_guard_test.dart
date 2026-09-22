import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-797 / BUG-1040 守卫：任何盖在查词弹窗之上的 Flutter 对话框（「制卡·选择句子
/// 上下文」[SentenceContextDialog]、「卡片已在 Anki 中」动作对话框、「打开卡片」多卡
/// 选择框）打开期间，必须把查词弹窗 WebView 停靠屏外，否则**原生平台视图**（桌面
/// WebView2 / Android platform view，靠 airspace 总画在 Flutter overlay 之上）会盖住
/// `showAppDialog` 弹的对话框（用户报「层级不对 / 看不见」）。
///
/// airspace 无头测试照不到，故用源码扫描钉死两车道接线：
///   ① 有嵌套安全的计数 `_popupHidingDialogDepth`（BUG-1040 从 bool 改计数：动作对话框
///      里还能叠一层 note viewer，bool 会被内层 finally 提前复位）；
///   ② 有统一入口 `runWithLookupPopupHidden`，且增减都经 setState（触发重建让弹窗真移动）；
///   ③ `parkedPopupLayer` 的 `visible` 与「计数为 0」相与（对话框期间强制停靠屏外）；
///   ④ 每一个会弹 Flutter 对话框的调用点（句子上下文对话框 / runAnkiMinedCardAction）
///      都接上了该入口。
///
/// BUG-2051：↗「在 Anki 中打开」不再弹任何 Flutter 对话框（它把 Anki 浏览器过滤到
/// 这个词的卡，多张由 Anki 自己列），`openMinedCardInAnki` 与多卡选择框已删除。判据
/// 因此从「数出 ≥2 处 runHidden」改成**逐个调用点检查**——数个数会随功能增减漂移，
/// 而「漏接一处停靠」的改动恰好也会把数字改小，那种守卫抓不住它。
void main() {
  String read(String rel) {
    final File f = File(rel);
    expect(f.existsSync(), isTrue, reason: 'missing $rel');
    return f.readAsStringSync();
  }

  void assertZOrderWiring(String src, String visibleExpr, String label) {
    expect(src.contains('int _popupHidingDialogDepth = 0'), isTrue,
        reason: '$label 缺「盖住弹窗的对话框」嵌套计数');
    expect(
        RegExp(r'Future<(\w+)> runWithLookupPopupHidden<\1>\(Future<\1> Function\(\) body\)')
            .hasMatch(src),
        isTrue,
        reason: '$label 缺统一停靠入口 runWithLookupPopupHidden');
    // 增减都必须经 setState，否则弹窗不会真的移动。
    expect(src.contains('setState(() => _popupHidingDialogDepth++)'), isTrue,
        reason: '$label 计数自增须走 setState');
    expect(src.contains('setState(() => _popupHidingDialogDepth ='), isTrue,
        reason: '$label 计数复位须走 setState');
    // parkedPopupLayer 的 visible 与「无对话框」相与 → 对话框期间弹窗停靠屏外。
    expect(src.contains(visibleExpr), isTrue,
        reason:
            '$label 的 parkedPopupLayer visible 必须与 _popupHidingDialogDepth == 0 相与');
    // 每个会弹 Flutter 对话框的调用点都接上统一入口。
    expect(src.contains('runWithLookupPopupHidden<void>('), isTrue,
        reason: '$label 的句子上下文对话框必须走统一停靠入口');
    final Iterable<Match> minedCalls =
        RegExp(r'runAnkiMinedCardAction\(').allMatches(src);
    expect(minedCalls, isNotEmpty,
        reason: '$label 必须仍有 runAnkiMinedCardAction 调用点，'
            '否则下面的逐点检查是空转');
    for (final Match m in minedCalls) {
      final int end = m.start + 800 > src.length ? src.length : m.start + 800;
      expect(
          src
              .substring(m.start, end)
              .contains('runHidden: runWithLookupPopupHidden'),
          isTrue,
          reason: '$label 的 runAnkiMinedCardAction 调用点必须传 runHidden');
    }
    // ↗ 不得再拉起 Flutter 对话框（BUG-2051 后它只让 Anki 浏览器过滤到这个词）。
    expect(src.contains('openMinedCardInAnki'), isFalse,
        reason: '$label 的 ↗ 不得再弹 Flutter 对话框');
  }

  test('reader 车道 (base_source_page) 对话框期间停靠弹窗', () {
    final String src = read('lib/src/pages/base_source_page.dart');
    assertZOrderWiring(
      src,
      'visible: item.visible && _popupHidingDialogDepth == 0',
      'base_source_page',
    );
  });

  test('video/首页车道 (dictionary_page_mixin) 对话框期间停靠弹窗', () {
    final String src =
        read('lib/src/pages/implementations/dictionary_page_mixin.dart');
    assertZOrderWiring(
      src,
      'visible: entry.visible && _popupHidingDialogDepth == 0',
      'dictionary_page_mixin',
    );
  });

  // BUG-2627：对话框期间浮层被**停靠屏外却仍然挂载**——这是有意的（webview 活着，
  // 确认制卡才回点得到它）。代价是它的 DOM 还可能拿着系统键盘焦点，而
  // `onHostInputToken` 落地的是 `_dismissTopVisiblePopup` / `clearDictionaryResult`
  // 这类**关栈**动作：不挡这条，用户在对话框里敲一个被绑的键，对话框**背后**的整条
  // 浮层栈就没了（连带清空制卡草稿），而屏幕上什么都看不出来——随后「确认制卡」
  // 回点必然扑空，长成「点了没反应」。这条通道必须与 barrier
  // （[shouldShowLookupDismissBarrier]）和浮层 `visible:` 共用同一道门。
  void assertInputTokenGated(String src, String gate, String label) {
    final int at = src.indexOf('onHostInputToken:');
    expect(at, greaterThan(0), reason: '$label 必须接 onHostInputToken');
    // 取接线点之后的一小段：门必须就写在这条接线里，而不是散落在别处。
    final String wiring = src.substring(at, at + 420);
    expect(wiring.contains(gate), isTrue,
        reason: '$label 的 onHostInputToken 必须在对话框期间短路（门：$gate）');
  }

  test('BUG-2627 reader 车道：对话框期间弹窗输入 token 不得关栈', () {
    assertInputTokenGated(
      read('lib/src/pages/base_source_page.dart'),
      '_popupHidingDialogDepth != 0',
      'base_source_page',
    );
  });

  test('BUG-2627 video/首页车道：对话框期间弹窗输入 token 不得关栈', () {
    assertInputTokenGated(
      read('lib/src/pages/implementations/dictionary_page_mixin.dart'),
      'lookupPopupHiddenByDialog',
      'dictionary_page_mixin',
    );
  });

  // BUG-2627：「确认制卡」是一次跨 WebView 的往返，两条车道都必须把「有没有真的点到
  // 那颗按钮」原样回传给对话框——吞掉返回值，任何关栈竞态都退化成同一个无声症状。
  test('BUG-2627 两条车道的 onConfirm 都回传回点结果', () {
    for (final (String path, String label) in <(String, String)>[
      ('lib/src/pages/base_source_page.dart', 'base_source_page'),
      (
        'lib/src/pages/implementations/dictionary_page_mixin.dart',
        'dictionary_page_mixin',
      ),
    ]) {
      final String src = read(path);
      // 按语义匹配而不是钉死一行字面量：BUG-2634 第二轮给它加了必填的
      // releaseWhenPayloadConsumed，调用点换行了。要的仍是「await + 原样回传」。
      final RegExp call = RegExp(
        r'await\s+webViewKey\.currentState\?\.mineEntryByIndex\(\s*'
        r'entryIndex,[\s\S]{0,900}?\)\s*\?\?',
      );
      expect(call.hasMatch(src), isTrue,
          reason: '$label 的 onConfirm 必须 await 并回传 mineEntryByIndex 的结果');
      // BUG-2634 第二轮：能不能提前关窗是**宿主的担保**，每条车道必须显式表态
      // （参数是 required，漏了编译就过不去；这里再钉一道，防止有人图省事全填 true）。
      expect(call.stringMatch(src), contains('releaseWhenPayloadConsumed:'),
          reason: '$label 必须显式声明宿主是否在首个 await 之前读走草稿');
    }
    expect(
        read('lib/src/pages/implementations/sentence_context_dialog.dart')
            .contains('final Future<bool> Function() onConfirm;'),
        isTrue,
        reason: 'onConfirm 的契约必须是「回传有没有点到」，不是 VoidCallback');
  });

  // BUG-1040：对话框本体必须是**居中对话框**而非底部 sheet——这是「必须当场决定」的模态
  // 选择，贴屏幕下沿在视频页会被播放器控件/窗口边缘裁掉半截（用户附图里进度条已被切）。
  test('已制卡动作走居中对话框，不再是 bottom sheet', () {
    final String src = read('lib/src/anki/anki_mined_card_action_sheet.dart');
    expect(src.contains('showModalBottomSheet'), isFalse,
        reason: '同族模态选择不得再用 bottom sheet（BUG-1040）');
    // BUG-2051 后本文件只剩「点 ✓ 的动作选择」一个顶层入口（↗ 的多卡选择框已删），
    // 所以钉的是**那个入口本身**用 showAppDialog，而不是数出几个 showAppDialog——
    // 后者在入口增减时会自己变绿/变红，与「入口是否居中弹出」无关。
    final int entry = src.indexOf('Future<AnkiMinedCardActionResult> '
        'showAnkiMinedCardActionSheet(');
    expect(entry, greaterThan(-1), reason: '动作对话框入口不存在，守卫会空转');
    final int end = entry + 600 > src.length ? src.length : entry + 600;
    final String body = src.substring(entry, end);
    expect(body.contains('showAppDialog<AnkiMinedCardActionResult>'), isTrue,
        reason: '动作对话框须走 showAppDialog');
    // 制卡/覆写有副作用，误触 barrier 不该丢掉整次操作。
    expect(body.contains('barrierDismissible: false'), isTrue,
        reason: '动作对话框须禁用 barrier 关闭');
  });
}
