import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-1908：galgame 浮窗里制卡失败**完全没有提示**（用户 2026-08-28：
/// 「gal制卡报错没有明显提示」）。
///
/// 两层根因：
/// ① **回程通道传不出原因**。`GalHookMiningResult.toPopupReply()` 与
///    `overlay_bridge_handlers` 的两条 reply 都只有 `{ankiConnect, noteId}`，
///    宿主即便算出了「没选卡组 / 字段映射对不上 / 窗口截图失败」也没地方放。
/// ② **浮窗侧整段没有 else**。`ankiConnect:false` 是正常 resolve、不抛，
///    既不进 `catch` 也不进 `if (result.ankiConnect)` —— 零反馈。
///
/// 而 Flutter 那边的 toast 救不了场：galgame 浮窗是独立的 native WebView2 窗口，
/// `FushiToast` 画在**主 app 窗口**的 Overlay 上，游戏全屏时主窗在后台，
/// 那些 toast 一个也看不见（`fushi_toast.dart` 在拿不到 overlay 时更是直接 return）。
/// 浮窗内本来就有为「app 外没有 Flutter toast 可用」而建的页内车道
/// `showInlineHint`（BUG-1064），只是制卡链路从没接上。
///
/// 这里守三件事：JS 侧解析出 message 并在失败时就地提示；Dart 侧三条回程都能带
/// message；三镜像同步。
void main() {
  final String popupJs = File('assets/popup/popup.js').readAsStringSync();

  test('popup.js 解析 reply.message 并在制卡失败时就地提示（BUG-1908）', () {
    expect(popupJs.contains('reply.message'), isTrue,
        reason: 'parseMineResult 必须把失败原因取出来，否则宿主算了也没人看');

    // 失败分支必须真的调 showInlineHint —— 那是 app 外唯一可见的提示通道。
    // 锚点用失败分支自身的注释（`BUG-1908` 在本文件出现多次，第一处是
    // parseMineResult，拿它当锚会量到文件另一头去）。
    final int marker = popupJs.indexOf('制卡失败必须');
    expect(marker, greaterThanOrEqualTo(0), reason: 'popup.js 的制卡失败分支必须存在');
    final int hintCall = popupJs.indexOf('showInlineHint(', marker);
    expect(hintCall, greaterThanOrEqualTo(0),
        reason: '失败分支必须调用 showInlineHint');
    // 就在同一段里（而不是文件别处某个不相干的调用）。
    expect(hintCall - marker, lessThan(1200),
        reason: 'showInlineHint 必须紧跟在失败分支里');

    // 兜底文案由宿主注入（i18n），不硬编码中文/英文进 JS。
    expect(popupJs.contains('window.i18nMineFailed'), isTrue);
    final String injection = File(
      'lib/src/pages/implementations/popup_settings_injection.dart',
    ).readAsStringSync();
    expect(injection.contains('window.i18nMineFailed'), isTrue,
        reason: '兜底文案必须由宿主按 locale 注入');
  });

  test('Dart 三条回程都能带失败原因（BUG-1908）', () {
    final String coordinator = File(
      'lib/src/mining/gal_hook_mining_coordinator.dart',
    ).readAsStringSync();
    expect(coordinator.contains('toPopupReply({String? message})'), isTrue,
        reason: 'gal 制卡回程必须能带 message');

    final String controller = File(
      'lib/src/lookup/gal_hook_text_overlay_controller.dart',
    ).readAsStringSync();
    expect(controller.contains('toPopupReply(message:'), isTrue,
        reason: '浮窗控制器必须把已本地化的失败文案回给浮窗，'
            '而不是只画一个用户看不见的 Flutter toast');

    final String bridge = File(
      'lib/src/lookup/overlay_bridge_handlers.dart',
    ).readAsStringSync();
    expect(bridge.contains("'message': message"), isTrue,
        reason: '裸浮窗（非 gal）的制卡/覆写回程同样要带原因');
    expect(bridge.contains("'message': t.card_export_failed"), isTrue,
        reason: '异常路径此前只写磁盘日志、浮窗零反馈；至少要告诉用户失败了');
  });

  test('popup.js 三镜像同步（BUG-1908 改动不得只落一份）', () {
    final String vendorApp =
        File('assets/browser_extension/vendor/popup.js').readAsStringSync();
    final String vendorRepo =
        File('../tools/browser-extension/vendor/popup.js').readAsStringSync();
    expect(vendorApp, equals(popupJs));
    expect(vendorRepo, equals(popupJs));
  });

  // BUG-1908 第二轮（PR #1032 审查）：前一轮只在**新制卡**那条路上接了提示，另外三条
  // 出口仍然把宿主算好的原因丢掉、或对按钮态硬猜。这里逐条钉死。
  //
  // 行为覆盖在 fushi/test/utils/misc/popup_asset_behavior_test.js（node 真跑 popup.js
  // 的假 DOM harness，四条用例 + 四次变异实测），但那套不进 CI；下面这层源码守卫是
  // CI 里唯一能拦住回归的东西，所以判据取「区间内必须/不得出现某个 token」，并且每个
  // 区间的起止都断言找得到，避免锚点被改名后守卫退化成零断言空转。
  String region(String from, String to) {
    final int start = popupJs.indexOf(from);
    expect(start, greaterThanOrEqualTo(0), reason: '锚点消失：$from');
    final int end = popupJs.indexOf(to, start);
    expect(end, greaterThan(start), reason: '区间结束锚点消失：$to');
    return popupJs.substring(start, end);
  }

  test('覆写（✓⤺）失败必须说出原因，且不把卡说没（BUG-1908）', () {
    // 区间 = 「最新可改」覆写分支，止于紧随其后的「已存在卡」分支。
    final String overwrite = region(
      'TODO-270 D green',
      "if (mineButton.dataset.mined === '1')",
    );
    expect(overwrite.contains('!result.ankiConnect'), isTrue,
        reason: 'ankiConnect 才是覆写的真成败位；无条件画 ✓ 等于把失败画成成功');
    expect(overwrite.contains('showInlineHint('), isTrue,
        reason: '覆写失败必须走页内提示车道——gal 浮窗是独立 native 窗口，'
            '宿主的 Flutter toast 在游戏全屏时用户一个也看不见');
    expect(overwrite.contains('result.message'), isTrue,
        reason: '宿主为覆写失败专门算了本地化文案'
            '（toPopupReply(message: failureMessage)，updateNoteId != null 那条路）；'
            '丢掉它就等于让那段 Dart 变成死代码');
  });

  test('制卡失败的按钮态只能来自宿主的确定答复，不许硬猜也不许回查（BUG-1908/TODO-448）',
      () {
    final String failure = region('制卡失败必须', '} catch (e) {');
    expect(failure.contains('setMineState(result.duplicate === true)'), isTrue,
        reason: '失败态必须照宿主给的 duplicate 位画：'
            'MineResult.duplicate 走的正是 success:false，此时 Anki 里确定有卡，'
            '硬写 setMineState(false) 会画成可制卡 ＋ 并把 ↗ 入口藏起来');
    expect(failure.contains("callHandler('duplicateCheck'"), isFalse,
        reason: 'TODO-448：失败/不确定后绝不回查 Anki 再把按钮翻成 ✓'
            '（addNote 到了 Anki 但响应断了那次，用户先看到失败再看到 ✓）');

    // 反面：宿主没给 duplicate 位时不许翻。parseMineResult 必须真读 reply.duplicate，
    // 否则上面那条断言会被一个恒 false 的常量满足（假绿）。
    expect(popupJs.contains('duplicate: reply.duplicate === true'), isTrue,
        reason: 'duplicate 位必须来自宿主 reply，写死常量等于守卫空转');
  });

  test('桥自身 reject 时不得静默（BUG-1908）', () {
    final String catchBlock = region(
      "console.error('mine button: mineEntry failed'",
      '} finally {',
    );
    expect(catchBlock.contains('showInlineHint('), isTrue,
        reason: '只写 console.error 对用户等于「点了没反应」；'
            'BUG-077 只修了「按钮不卡死」，没修「说出来」');
  });

  test('已存在卡的操作单回程也要带出宿主的原因（BUG-1908）', () {
    final String handled = region(
      "if (action.outcome === 'handled')",
      "outcome === 'fallthrough'",
    );
    expect(handled.contains('action.result.message'), isTrue,
        reason: '覆写/新增重复卡失败时宿主的原因不能在这条路上被丢掉');
    expect(handled.contains('showInlineHint('), isTrue,
        reason: '同上，必须落到页内提示车道');
  });

  test('Dart 侧把「重复」与「真没制成」分开回传（BUG-1908）', () {
    final String coordinator = File(
      'lib/src/mining/gal_hook_mining_coordinator.dart',
    ).readAsStringSync();
    expect(coordinator.contains('bool get duplicate'), isTrue,
        reason: 'gal 回程必须能区分 MineResult.duplicate');
    expect(coordinator.contains("if (duplicate) 'duplicate': true"), isTrue,
        reason: 'duplicate 位必须真的进 reply');

    final String popupResult = File(
      'lib/src/pages/implementations/dictionary_popup_webview.dart',
    ).readAsStringSync();
    expect(popupResult.contains('this.duplicate = false'), isTrue,
        reason: 'MinePopupResult 必须带 duplicate 位');
    expect(popupResult.contains("if (duplicate) 'duplicate': true"), isTrue,
        reason: 'duplicate 位必须序列化给 JS');

    final String bridge = File(
      'lib/src/lookup/overlay_bridge_handlers.dart',
    ).readAsStringSync();
    expect(
        bridge.contains(
            "if (outcome.result == MineResult.duplicate) 'duplicate': true"),
        isTrue,
        reason: 'app 外裸浮窗的制卡回程同样要带 duplicate 位');
  });
}
