import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/reader/reader_visual_novel_scripts.dart';
import 'package:hibiki/src/reader/reader_pagination_scripts.dart';

void main() {
  test('VN shell builds and contains the object + restore + deps', () {
    final String shell = ReaderVisualNovelScripts.vnShellScript(
      initialCharOffset: 1234,
      revealSpeed: 45,
      screenMode: 'block',
    );
    expect(shell.contains('<script>'), isTrue);
    expect(shell.contains('window.hoshiReader = {'), isTrue);
    expect(shell.contains('global.hoshiReaderTextSemantics'), isTrue);
    expect(shell.contains('global.hoshiReaderVnContentStream'), isTrue);
    expect(shell.contains('global.hoshiReaderVnRangeMap'), isTrue);
    expect(shell.contains('global.hoshiReaderMediaSemantics'), isTrue);
    expect(shell.contains('restoreToCharOffset(1234)'), isTrue);
    expect(shell.contains('revealSpeed: 45'), isTrue);
    expect(shell.contains("screenMode: 'block'"), isTrue);
    expect(shell.contains("callHandler('onRestoreComplete')"), isTrue);
    // dispatch via shellScript(vnMode:true) reaches the VN shell.
    final String viaShell = ReaderPaginationScripts.shellScript(
      vnMode: true,
      initialCharOffset: 7,
      vnRevealSpeed: 45,
    );
    expect(viaShell.contains('window.hoshiReader = {'), isTrue);
    expect(viaShell.contains('restoreToCharOffset(7)'), isTrue);
  });

  // TODO-909 M0 reveal contract. reveal（打字渐显）是 M1 功能；M0 在 webview 的
  // wire 点（vnRevealSpeedM0ForceZero）强制 revealSpeed=0，让每屏 renderScreen 即
  // revealComplete=true、paginate 只返 "scrolled"/"limit"，与 Dart _didScroll 只认
  // "scrolled" 的语义对齐，避免 forward 翻屏命中 "revealed" 分支被误判为章节边界
  // 而跨章。本测试钉死「revealSpeed=0 时 shell 走 revealComplete=true 路径、且
  // forward paginate 不返 revealed」这一可落地契约（headless WebView 在 CI 跑不到，
  // 真机行为留真机 Gate）。
  test(
      'M0 reveal speed 0 makes every screen complete on render (no '
      '"revealed" paginate path)', () {
    final String shell0 = ReaderPaginationScripts.shellScript(
      vnMode: true,
      // M0 wire point forces this to 0 (see webview.part.dart
      // vnRevealSpeedM0ForceZero); assert the shell carries it through.
      vnRevealSpeed: 0,
    );
    expect(
      shell0.contains('revealSpeed: 0'),
      isTrue,
      reason: 'M0 shell must carry revealSpeed: 0',
    );
    expect(
      shell0.contains('revealSpeed: 45'),
      isFalse,
      reason: 'M0 shell must not carry the M1 default reveal speed',
    );
    // The paginate forward path that returns "revealed" is guarded by
    // `if (!this.revealComplete)`. With revealSpeed <= 0, renderScreen sets
    // revealComplete = true (this.revealSpeed <= 0 short-circuit), so forward
    // paginate never takes the "revealed" branch — it returns "scrolled" or
    // "limit", which Dart _didScroll understands.
    expect(
      shell0.contains('this.revealComplete = true;'),
      isTrue,
      reason: 'reveal-complete short-circuit must exist in the VN shell',
    );
    expect(
      shell0.contains('this.revealSpeed <= 0'),
      isTrue,
      reason: 'revealSpeed <= 0 must force revealComplete=true on render',
    );
    expect(
      shell0.contains('return "scrolled";'),
      isTrue,
      reason: 'paginate must return "scrolled" on a real screen advance',
    );
  });

  // Pin the Dart-side contract that _didScroll only treats "scrolled" as a real
  // turn: "revealed" is NOT a scroll, which is exactly why M0 must avoid the
  // reveal path (otherwise forward paginate -> "revealed" -> _didScroll false ->
  // _handlePageTurnLimit cross-chapter misjump).
  test(
      'chrome _didScroll treats only "scrolled" as a real turn (not '
      '"revealed")', () {
    final String chrome = File(
      'lib/src/pages/implementations/reader_hibiki/chrome.part.dart',
    ).readAsStringSync();
    expect(
      chrome.contains("== 'scrolled'"),
      isTrue,
      reason: '_didScroll must compare against "scrolled"',
    );
    expect(
      chrome.contains("== 'revealed'"),
      isFalse,
      reason: '_didScroll must not accept "revealed" as a turn',
    );
  });
}
