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

  // TODO-1085 / BUG-513 症状①：VN 模式常驻遮罩。Dart 侧 loading 遮罩
  // (reader_hibiki_page.dart `if (!_readerContentReady) Positioned.fill(ColoredBox)`)
  // 只由 JS 的 notifyRestoreComplete -> callHandler('onRestoreComplete') 清除。
  // notifyRestoreComplete 是 initialize() readyPromise 链的最后一步，且所有 restore
  // 方法都 await 这同一个 readyPromise —— 链上任何一步 reject 都会静默吞掉 notify，
  // 遮罩只能等 8s 兜底才消。根因修复：readyPromise 补 .catch 兜底仍 fire notify。
  test(
      'BUG-513①: VN initialize readyPromise has a .catch that still fires '
      'notifyRestoreComplete (fail-open, never a permanent mask)', () {
    final String shell = ReaderVisualNovelScripts.vnShellScript();
    // The happy-path notify exists.
    expect(
      shell.contains("callHandler('onRestoreComplete')"),
      isTrue,
      reason: 'notifyRestoreComplete must forward to onRestoreComplete',
    );
    // A .catch handler must exist on the initialize promise chain.
    expect(
      shell.contains('.catch((error) => {'),
      isTrue,
      reason: 'initialize readyPromise must catch failures',
    );
    // Inside the catch, notifyRestoreComplete must still be called so the Dart
    // loading mask is released even when a build step throws.
    final int catchIdx = shell.indexOf('.catch((error) => {');
    expect(catchIdx, greaterThanOrEqualTo(0));
    final int chainEnd = shell.indexOf('return this.readyPromise;', catchIdx);
    expect(chainEnd, greaterThan(catchIdx),
        reason:
            'catch must sit inside initialize before returning readyPromise');
    final String catchBody = shell.substring(catchIdx, chainEnd);
    expect(
      catchBody.contains('this.notifyRestoreComplete();'),
      isTrue,
      reason: 'catch branch must still fire notifyRestoreComplete (fail-open)',
    );
  });

  // TODO-1085 / BUG-513 症状②：VN 模式图片极小。共享 reader 图片 CSS
  // (reader_content_styles.dart) 用 --hoshi-image-max-width/height 给 .block-img 一个
  // 页面尺寸的居中盒；分页 shell 在 initialize/updatePageSize 设这些变量并把大图
  // 提升为 .block-img，VN shell 原来两件都没做 —— 变量落回 CSS 回退、img 又没
  // .block-img，只能命中 img:not(.block-img){max-width:100%}，100% 对着 shrink-to-fit
  // 的 .hoshi-vn-content flex item 解析 -> 坍成几像素。根因修复：VN initialize 里
  // applyImageMaxVars 设变量 + setupReaderImages 把大图提升为 .block-img。
  test(
      'BUG-513②: VN shell sets --hoshi-image-max vars and promotes large '
      'images to .block-img so they are not tiny', () {
    final String shell = ReaderVisualNovelScripts.vnShellScript();
    // The image viewport vars are set (single source of truth ratio 0.95).
    expect(
      shell.contains("setProperty('--hoshi-image-max-width'"),
      isTrue,
      reason: 'VN must set --hoshi-image-max-width so images size to viewport',
    );
    expect(
      shell.contains("setProperty('--hoshi-image-max-height'"),
      isTrue,
      reason: 'VN must set --hoshi-image-max-height so images size to viewport',
    );
    expect(
      shell.contains('var ratio = 0.95;'),
      isTrue,
      reason:
          'image width ratio must match paginated (imageWidthViewportRatio)',
    );
    // applyImageMaxVars is invoked from initialize.
    expect(
      shell.contains('this.applyImageMaxVars();'),
      isTrue,
      reason: 'initialize must call applyImageMaxVars',
    );
    // Large standalone images/svgs are promoted to .block-img + wrapper, so the
    // shared CSS gives them a page-sized centred box (not the collapsed
    // max-width:100% fallback).
    expect(
      shell.contains("classList.add('block-img')"),
      isTrue,
      reason: 'VN must promote large images to .block-img',
    );
    expect(
      shell.contains('this.promoteBlockImages('),
      isTrue,
      reason: 'setupReaderImages must promote block images before rendering',
    );
    expect(
      shell.contains("wrapper.className = 'block-img-wrapper'"),
      isTrue,
      reason: 'promoted images must be centred via .block-img-wrapper',
    );
    // Gaiji glyph images must stay inline (never promoted / never blown up).
    expect(
      shell.contains("img.classList.contains('gaiji')"),
      isTrue,
      reason: 'gaiji glyph images must be excluded from block promotion',
    );
  });

  // Never-break：非 VN 模式（分页/连续）不应被 VN 的图片 var/提升逻辑影响 ——
  // 那些逻辑只存在于 VN shell，分页 shell 的图片处理仍走自己的 _sharedInitImages。
  test('BUG-513: paginated shell is unchanged (VN-only promoteBlockImages)',
      () {
    final String paginated = ReaderPaginationScripts.shellScript();
    expect(
      paginated.contains('this.promoteBlockImages('),
      isFalse,
      reason: 'promoteBlockImages is VN-only; paginated must not gain it',
    );
    expect(
      paginated.contains('this.applyImageMaxVars();'),
      isFalse,
      reason: 'applyImageMaxVars is VN-only; paginated uses its own image vars',
    );
  });

  // BUG-718：VN 模式按字符偏移恢复（restoreToCharOffset）时整页空白。根因——
  // restoreToCharOffset 只由 boot 块之后的 host-compat shim IIFE 挂上，而 boot 的
  // `if (document.readyState==='complete')` 分支在 setup 脚本注入时同步调用
  // `window.hoshiReader.restoreToCharOffset(<offset>)`。shim 尚未定义 → TypeError →
  // 中断整个外层 setup IIFE → 尾部的 `#hoshi-cloak` 移除永不执行 → body 保持
  // visibility:hidden → 空白。根因修复：boot 块必须排在 shim IIFE 之后（restore*
  // 方法先定义再被调用），且 boot restore 套 try/catch，任何 restore 错误都不再
  // 连累 cloak 移除。headless WebView 跑不到真实 cloak 时序，这里钉死源码顺序契约。
  test('BUG-718: charOffset-restore shim is defined BEFORE the boot calls it',
      () {
    const int offset = 22059;
    final String shell =
        ReaderVisualNovelScripts.vnShellScript(initialCharOffset: offset);
    // boot must restore by charOffset for a saved position.
    final int bootCall =
        shell.indexOf('window.hoshiReader.restoreToCharOffset($offset)');
    expect(bootCall, greaterThanOrEqualTo(0),
        reason: 'charOffset restore must call restoreToCharOffset($offset)');
    // the host-compat shim that defines restoreToCharOffset must appear earlier
    // in the script than the boot call site (so it is not undefined when called).
    final int shimDef = shell.indexOf('vn.restoreToCharOffset = ');
    expect(shimDef, greaterThanOrEqualTo(0),
        reason: 'restoreToCharOffset shim must exist');
    expect(shimDef, lessThan(bootCall),
        reason:
            'restoreToCharOffset shim must be defined BEFORE the boot block '
            'calls it — otherwise a synchronous TypeError aborts the setup IIFE '
            'and #hoshi-cloak is never removed (BUG-718 blank screen)');
    // boot restore must be wrapped so a future restore error cannot strand the
    // cloak / caret / gesture setup that follows it in the outer IIFE.
    final int loadListener =
        shell.indexOf("window.addEventListener('load', function() {");
    expect(loadListener, greaterThan(shimDef),
        reason: 'boot (load listener) must come after the shim IIFE');
    expect(shell.substring(loadListener).contains('try {'), isTrue,
        reason: 'boot restore must be wrapped in try/catch');
    // dispatch via shellScript(vnMode:true, initialCharOffset:) keeps the order.
    final String viaShell = ReaderPaginationScripts.shellScript(
      vnMode: true,
      initialCharOffset: offset,
    );
    expect(
      viaShell.indexOf('vn.restoreToCharOffset = ') <
          viaShell.indexOf('window.hoshiReader.restoreToCharOffset($offset)'),
      isTrue,
      reason: 'dispatched VN shell must keep shim-before-boot ordering',
    );
  });
}
