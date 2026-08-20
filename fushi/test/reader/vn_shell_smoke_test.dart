// 覆盖边界（勿误读）：本文件只验 reader 侧 JS 载荷的**语义**——生成函数返回的那个字符串
// 里有什么、行为契约对不对。它证明不了这个载荷真的被拼进最终注入 WebView 的 setup 脚本。
// 「装配完整性」（每个子载荷都被拼进去、压缩后还在）由
// test/reader/reader_script_compactor_test.dart 的「setup 装配完整性」一组集中守——
// 那里删掉模板中的 $caretJs / $selectionJs / $longPressDragJs 会立刻转红，本文件不会。
// 改这里前先分清你要锁的是语义还是注入，别在本文件里重造装配断言。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_visual_novel_scripts.dart';
import 'package:fushi/src/reader/reader_pagination_scripts.dart';

void main() {
  test('VN shell builds and contains the object + restore + deps', () {
    final String shell = ReaderVisualNovelScripts.vnShellScript();
    expect(shell.contains('<script>'), isTrue);
    expect(shell.contains('window.fushiReader = {'), isTrue);
    expect(shell.contains('global.fushiReaderTextSemantics'), isTrue);
    expect(shell.contains('global.fushiReaderVnContentStream'), isTrue);
    expect(shell.contains('global.fushiReaderVnRangeMap'), isTrue);
    expect(shell.contains('global.fushiReaderMediaSemantics'), isTrue);
    // BUG-1140 第二阶段①：恢复锚 / reveal 参数不再插进源码，改由运行时读 C。
    expect(shell.contains('restoreToCharOffset(C.initialCharOffset)'), isTrue);
    expect(shell.contains('revealSpeed: C.vnRevealSpeed,'), isTrue);
    expect(shell.contains('screenMode: C.vnScreenMode,'), isTrue);
    expect(
      _hasGenerationAwareRestoreCall(
        _extractBraceBlock(shell, 'notifyRestoreComplete: function()'),
      ),
      isTrue,
      reason: 'VN restore notification must send handler + perf placeholder + '
          'the immutable document generation',
    );
    // 整份 shell 被包成运行时可复用的安装函数（引擎静态化的前提）。
    expect(shell.contains('window.__fushiShells.vn = function(C) {'), isTrue);
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
    final String shell0 = ReaderVisualNovelScripts.vnShellScript();
    // M0 的 revealSpeed=0 强制点搬到 Dart 侧 config 组装处（webview.part.dart 的
    // vnRevealSpeedM0ForceZero，由 vn_view_mode_three_state_guard 钉住）；shell 这边
    // 只需保证它读的是运行时值、没有把任何 M1 默认值写死进源码。
    expect(
      shell0.contains('revealSpeed: C.vnRevealSpeed,'),
      isTrue,
      reason: 'VN shell must read the reveal speed from the runtime config',
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
      'lib/src/pages/implementations/reader_fushi/chrome.part.dart',
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
  // (reader_fushi_page.dart `if (!_readerContentReady) Positioned.fill(ColoredBox)`)
  // 只由 JS 的 notifyRestoreComplete -> callHandler('onRestoreComplete') 清除。
  // notifyRestoreComplete 是 initialize() readyPromise 链的最后一步，且所有 restore
  // 方法都 await 这同一个 readyPromise —— 链上任何一步 reject 都会静默吞掉 notify，
  // 遮罩只能等 8s 兜底才消。根因修复：readyPromise 补 .catch 兜底仍 fire notify。
  test(
      'BUG-513①: VN initialize readyPromise has a .catch that still fires '
      'notifyRestoreComplete (fail-open, never a permanent mask)', () {
    final String shell = ReaderVisualNovelScripts.vnShellScript();
    final String notifyBody =
        _extractBraceBlock(shell, 'notifyRestoreComplete: function()');
    expect(
      _hasGenerationAwareRestoreCall(notifyBody),
      isTrue,
      reason: 'notifyRestoreComplete must forward the document generation',
    );
    final String initializeBody =
        _extractBraceBlock(shell, 'initialize: function()');
    // A .catch handler must exist on the initialize promise chain.
    const String catchMarker = '.catch((error) => {';
    final int catchIdx = initializeBody.indexOf(catchMarker);
    expect(
      catchIdx,
      greaterThanOrEqualTo(0),
      reason: 'initialize readyPromise must catch failures',
    );
    final String happyBody = initializeBody.substring(0, catchIdx);
    expect(
      happyBody.contains('this.notifyRestoreComplete();'),
      isTrue,
      reason: 'initialize happy path must fire notifyRestoreComplete',
    );
    // Inside the catch, notifyRestoreComplete must still be called so the Dart
    // loading mask is released even when a build step throws.
    final String catchBody = _extractBraceBlock(
      initializeBody,
      catchMarker,
    );
    expect(
      catchBody.contains('this.notifyRestoreComplete();'),
      isTrue,
      reason: 'catch branch must still fire notifyRestoreComplete (fail-open)',
    );
  });

  test(
      'restore handler validates and gates the reported document generation '
      'before settling Dart state', () {
    final String webview = File(
      'lib/src/pages/implementations/reader_fushi/webview.part.dart',
    ).readAsStringSync();
    final String callback = _extractRestoreHandlerCallback(webview);

    expect(
      RegExp(
        r'args\.length\s*<\s*2\s*\|\|\s*args\[1\]\s+is!\s+num',
      ).hasMatch(callback),
      isTrue,
      reason: 'Dart handler must reject a missing/non-numeric generation',
    );
    expect(
      callback.contains('rawGeneration.isFinite') &&
          callback.contains('rawGeneration != rawGeneration.toInt()'),
      isTrue,
      reason: 'Dart handler must reject non-finite/fractional generations',
    );
    expect(
      RegExp(
        r'_acceptRestoreComplete\(\s*'
        r'reportedGeneration:\s*rawGeneration\.toInt\(\),\s*'
        r'perfSnapshot:\s*args\.first,\s*\)',
      ).hasMatch(callback),
      isTrue,
      reason: 'only the validated generation may enter the restore gate',
    );

    final String navigation = File(
      'lib/src/pages/implementations/reader_fushi/navigation.part.dart',
    ).readAsStringSync();
    final int gateStart = navigation.indexOf('void _acceptRestoreComplete({');
    final int settleStart =
        navigation.indexOf('void _onRestoreComplete()', gateStart);
    expect(gateStart, greaterThanOrEqualTo(0));
    expect(settleStart, greaterThan(gateStart));
    final String gate = navigation.substring(gateStart, settleStart);
    expect(
      RegExp(
        r'isCurrentReaderRestoreCompletion\(\s*'
        r'reportedGeneration:\s*reportedGeneration,\s*'
        r'currentGeneration:\s*_navigateGeneration,\s*'
        r'expectedGeneration:\s*_restoreExpectedGeneration,\s*\)',
      ).hasMatch(gate),
      isTrue,
      reason: 'Dart must compare reported, current, and expected generations',
    );
    expect(
      gate.indexOf('isCurrentReaderRestoreCompletion('),
      lessThan(gate.indexOf('_onRestoreComplete();')),
      reason: 'generation gate must run before restore side effects settle',
    );
  });

  // TODO-1085 / BUG-513 症状②：VN 模式图片极小。共享 reader 图片 CSS
  // (reader_content_styles.dart) 用 --fushi-image-max-width/height 给 .block-img 一个
  // 页面尺寸的居中盒；分页 shell 在 initialize/updatePageSize 设这些变量并把大图
  // 提升为 .block-img，VN shell 原来两件都没做 —— 变量落回 CSS 回退、img 又没
  // .block-img，只能命中 img:not(.block-img){max-width:100%}，100% 对着 shrink-to-fit
  // 的 .fushi-vn-content flex item 解析 -> 坍成几像素。根因修复：VN initialize 里
  // applyImageMaxVars 设变量 + setupReaderImages 把大图提升为 .block-img。
  test(
      'BUG-513②: VN shell sets --fushi-image-max vars and promotes large '
      'images to .block-img so they are not tiny', () {
    final String shell = ReaderVisualNovelScripts.vnShellScript();
    // The image viewport vars are set (single source of truth ratio 0.95).
    expect(
      shell.contains("setProperty('--fushi-image-max-width'"),
      isTrue,
      reason: 'VN must set --fushi-image-max-width so images size to viewport',
    );
    expect(
      shell.contains("setProperty('--fushi-image-max-height'"),
      isTrue,
      reason: 'VN must set --fushi-image-max-height so images size to viewport',
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
    final String paginated = ReaderPaginationScripts.paginatedShellSource();
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

  test('BUG-1244 zero-width media screens attach to adjacent VN text', () {
    final String shell = ReaderVisualNovelScripts.vnShellScript();
    final int buildAt = shell.indexOf('buildScreens: function()');
    final int attachAt = shell.indexOf(
      'baseScreens = this.attachMediaScreensToAdjacentText(baseScreens);',
      buildAt,
    );
    final int cueMergeAt =
        shell.indexOf('this.mergeSentenceAudioCrossScreenScreens(baseScreens)');
    expect(attachAt, greaterThan(buildAt));
    expect(
      attachAt,
      lessThan(cueMergeAt),
      reason: '图片必须先并入相邻文字屏，再按 cue 合屏；否则逐句跳转仍会略过图片屏',
    );
    expect(
      shell,
      contains(
        'this.screenStartCharCount(screen) === this.screenEndCharCount(screen)',
      ),
      reason: '只有没有字符锚的纯媒体屏需要附加，正常文字/图片混排屏不得被重排',
    );
    expect(shell, contains('pendingMedia.concat([screen])'));
    expect(shell, contains('[previous].concat(pendingMedia)'),
        reason: '章尾无下一句时必须挂到上一屏，仍然不能永久不可见');
  });

  // BUG-718：VN 模式按字符偏移恢复（restoreToCharOffset）时整页空白。根因——
  // restoreToCharOffset 只由 boot 块之后的 host-compat shim IIFE 挂上，而 boot 的
  // `if (document.readyState==='complete')` 分支在 setup 脚本注入时同步调用
  // `window.fushiReader.restoreToCharOffset(<offset>)`。shim 尚未定义 → TypeError →
  // 中断整个外层 setup IIFE → 尾部的 `#fushi-cloak` 移除永不执行 → body 保持
  // visibility:hidden → 空白。根因修复：boot 块必须排在 shim IIFE 之后（restore*
  // 方法先定义再被调用），且 boot restore 套 try/catch，任何 restore 错误都不再
  // 连累 cloak 移除。headless WebView 跑不到真实 cloak 时序，这里钉死源码顺序契约。
  test('BUG-718: charOffset-restore shim is defined BEFORE the boot calls it',
      () {
    final String shell = ReaderVisualNovelScripts.vnShellScript();
    // boot must restore by charOffset for a saved position（现在读运行时 C）。
    final int bootCall = shell
        .indexOf('window.fushiReader.restoreToCharOffset(C.initialCharOffset)');
    expect(bootCall, greaterThanOrEqualTo(0),
        reason:
            'charOffset restore must call restoreToCharOffset(C.initialCharOffset)');
    // the host-compat shim that defines restoreToCharOffset must appear earlier
    // in the script than the boot call site (so it is not undefined when called).
    final int shimDef = shell.indexOf('vn.restoreToCharOffset = ');
    expect(shimDef, greaterThanOrEqualTo(0),
        reason: 'restoreToCharOffset shim must exist');
    expect(shimDef, lessThan(bootCall),
        reason:
            'restoreToCharOffset shim must be defined BEFORE the boot block '
            'calls it — otherwise a synchronous TypeError aborts the setup IIFE '
            'and #fushi-cloak is never removed (BUG-718 blank screen)');
    // boot restore must be wrapped so a future restore error cannot strand the
    // cloak / caret / gesture setup that follows it in the outer IIFE.
    final int loadListener =
        shell.indexOf("window.addEventListener('load', function() {");
    expect(loadListener, greaterThan(shimDef),
        reason: 'boot (load listener) must come after the shim IIFE');
    expect(shell.substring(loadListener).contains('try {'), isTrue,
        reason: 'boot restore must be wrapped in try/catch');
    // 引擎里三种 shell 并存时，VN 那份仍保持 shim-before-boot 顺序。
    final String engine = ReaderPaginationScripts.engineShell(
        vnMode: true, continuousMode: false);
    final int engShim = engine.indexOf('vn.restoreToCharOffset = ');
    final int engBoot = engine.indexOf(
        'window.fushiReader.restoreToCharOffset(C.initialCharOffset)', engShim);
    expect(engShim, greaterThanOrEqualTo(0));
    expect(engBoot, greaterThan(engShim),
        reason:
            'engine-assembled VN shell must keep shim-before-boot ordering');
  });

  // BUG-1742 / BUG-1743：shim 块是「VN 必须实现的宿主接口清单」的唯一真相点。
  // 宿主里有一批共享路径假定 window.fushiReader 上有这些方法，VN 缺哪个就在哪个
  // 功能上静默失效（跟随不翻屏 / 搜索点了没反应），而且 JS 的 TypeError 在
  // evaluateJavascript 通道上抓不到，线上只表现为「没反应」。
  test('BUG-1742/1573: VN 实现全部宿主接口（跟随 + 章内文本定位）', () {
    final String shell = ReaderVisualNovelScripts.vnShellScript();
    for (final String method in <String>[
      'contentRoot',
      'screenIndexForCharOffset',
      'highlightSelectorCue',
      'scrollToSearchMatch',
      'clearSearchHighlight',
    ]) {
      expect(
        shell.contains('vn.$method = '),
        isTrue,
        reason: 'VN 缺宿主接口 $method —— 对应功能会在 VN 模式下静默失效',
      );
    }
    // 引擎三 shell 并存时 VN 那份同样要带齐。
    final String engine = ReaderPaginationScripts.engineShell(
        vnMode: true, continuousMode: false);
    expect(engine.contains('vn.highlightSelectorCue = '), isTrue);
    expect(engine.contains('vn.scrollToSearchMatch = '), isTrue);
  });

  test('BUG-1742: VN 的正文根取 sourceRoot，绝不是 document', () {
    final String shell = ReaderVisualNovelScripts.vnShellScript();
    final int start = shell.indexOf('vn.contentRoot = ');
    expect(start, greaterThanOrEqualTo(0));
    final String body = shell.substring(start, start + 200);
    // detachChapterSource 把整章正文搬进游离的 sourceRoot；从 document 取根
    // 就等于回到 BUG-1742 那条静默落空的老路。
    expect(body.contains('this.sourceRoot'), isTrue,
        reason: 'contentRoot 必须返回 sourceRoot（正文已被搬出 document）');
  });

  test('BUG-1742: 选择器跟随走「字符偏移 → 屏」链路，而不是滚动', () {
    final String shell = ReaderVisualNovelScripts.vnShellScript();
    final int start = shell.indexOf('vn.highlightSelectorCue = ');
    expect(start, greaterThanOrEqualTo(0));
    final int end = shell.indexOf('vn.scrollToSearchMatch = ', start);
    expect(end, greaterThan(start));
    final String body = shell.substring(start, end);
    expect(body.contains('this.contentRoot()'), isTrue,
        reason: '必须在 contentRoot 上找元素，document 里只有当前屏的克隆');
    expect(body.contains('sourcePositionForNode'), isTrue,
        reason: '必须把源节点换算成字符偏移');
    expect(body.contains('this.screenIndexForCharOffset'), isTrue);
    expect(body.contains('this.renderScreen('), isTrue,
        reason: 'VN 的跟随语义是翻屏；scrollIntoView 在定屏 stage 上无效果');
    expect(body.contains('if (!reveal) return null;'), isTrue,
        reason: 'reveal=false 是「别打断当前阅读位置」的显式请求，不许翻屏');
  });

  test('BUG-1743: VN 搜索在整章 contentStream 上匹配并做坐标换算', () {
    final String shell = ReaderVisualNovelScripts.vnShellScript();
    final int start = shell.indexOf('vn.scrollToSearchMatch = ');
    expect(start, greaterThanOrEqualTo(0));
    final int end = shell.indexOf('vn.clearSearchHighlight = ', start);
    expect(end, greaterThan(start));
    final String body = shell.substring(start, end);
    // 分页版用 createWalker()（只走当前屏）+ scrollToRange（VN 无此方法）——
    // 照搬过来在 VN 下只会在当前屏内找，跨屏命中永远找不到。
    expect(body.contains('createWalker('), isFalse,
        reason: 'VN 必须在整章 contentStream 上匹配，不能只走当前屏');
    expect(body.contains('stream.textEntries'), isTrue);
    // 命中下标是拼接后的原始文本坐标，屏索引吃的是可匹配字符坐标。
    expect(body.contains('countChars(prefix)'), isTrue,
        reason: '缺少 raw→matchable 换算会在任何含空白的章节上系统性偏移');
    expect(body.contains('seg.entry.startChar'), isTrue);
    expect(body.contains('this.screenIndexForCharOffset'), isTrue);
    expect(body.contains('return this.calculateProgress();'), isTrue,
        reason: '返回契约与分页版一致（调用方靠它落库）');
  });
}

String _extractRestoreHandlerCallback(String source) {
  const String handlerMarker = "handlerName: 'onRestoreComplete'";
  final int handlerStart = source.indexOf(handlerMarker);
  expect(
    handlerStart,
    greaterThanOrEqualTo(0),
    reason: 'Dart must register the onRestoreComplete handler',
  );
  final int callbackStart = source.indexOf('callback:', handlerStart);
  expect(
    callbackStart,
    greaterThan(handlerStart),
    reason: 'onRestoreComplete must have a callback',
  );
  return _extractBraceBlockAt(source, callbackStart);
}

String _extractBraceBlock(String source, String marker) {
  final int markerStart = source.indexOf(marker);
  expect(
    markerStart,
    greaterThanOrEqualTo(0),
    reason: 'missing source marker: $marker',
  );
  return _extractBraceBlockAt(source, markerStart);
}

String _extractBraceBlockAt(String source, int start) {
  final int bodyStart = source.indexOf('{', start);
  expect(bodyStart, greaterThanOrEqualTo(0), reason: 'missing block body');
  int depth = 0;
  for (int index = bodyStart; index < source.length; index++) {
    final String char = source[index];
    if (char == '{') {
      depth++;
    } else if (char == '}') {
      depth--;
      if (depth == 0) {
        return source.substring(bodyStart, index + 1);
      }
    }
  }
  fail('source block braces are unbalanced');
}

bool _hasGenerationAwareRestoreCall(String source) {
  return RegExp(
    r"callHandler\(\s*'onRestoreComplete'\s*,\s*null\s*,\s*"
    r'C\.navigationGeneration\s*\)',
  ).hasMatch(source);
}
