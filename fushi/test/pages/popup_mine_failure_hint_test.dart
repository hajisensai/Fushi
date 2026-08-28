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
}
