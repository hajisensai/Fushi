import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-792/753 源码守卫：竖排翻页「文字越翻越偏 / 叠加漂移」是真机专属，headless
/// 测不出（注入的 viewportHeight 与 WebView 真实 innerHeight/clientHeight 在 headless
/// 下天然一致；probe 的 column-width 也省了 −cT−cB，δ 天然为 0），必须靠真机取证。
/// `window.hoshiReader._diag753(phase)` 一次性把两套高度量 + chrome inset +
/// getScrollContext().pageSize + **每页 δ（pitchDelta = contentBox − 浏览器解析
/// columnWidth）** 打成一行 `[753-DIAG]`，经 onConsoleMessage → debugPrint →
/// DebugLogService 环形缓冲，用户在「设置 → 诊断 → 调试日志」开开关后可「复制全部」。
///
/// TODO-792：旧版只在竖排+横屏打，漏掉用户竖屏竖排场景；现竖排横/竖屏都打，按
/// phase+朝向去重。关键新字段 pitchDelta 让真机日志一锤定音：>0 坐实竖排该跟横排一样
/// 改读 getComputedStyle.columnWidth 消 δ；≈0 则漂移另有来源（reanchor/inset 遮挡）。
///
/// 这个守卫只锁「诊断接入存在且字段完整、走 console.log 同管道、只在分页 shell」，
/// 撤掉任一点 → 转红。纯取证，不验运行时几何（needsDevice）。
void main() {
  late String source;
  late String helper;

  setUpAll(() {
    source = File(
      'lib/src/reader/reader_pagination_scripts.dart',
    ).readAsStringSync();
    final int start =
        source.indexOf('window.hoshiReader._diag753 = function(phase) {');
    expect(start, greaterThan(0), reason: '_diag753 诊断 helper 必须存在');
    final int end =
        source.indexOf('window.hoshiReader.initialize = function() {', start);
    expect(end, greaterThan(start),
        reason: 'helper 必须定义在 paginated initialize 之前');
    helper = source.substring(start, end);
  });

  test('诊断在竖排（横/竖屏都打），非竖排早返回（TODO-792 放宽）', () {
    expect(helper.contains('this.isVertical()'), isTrue, reason: '须按竖排判据门控');
    expect(helper.contains('if (!vertical) return;'), isTrue,
        reason: '非竖排（横排亚像素 δ 已由 TODO-753 修复）一律早返回不打');
    expect(helper.contains('window.innerWidth > window.innerHeight'), isTrue,
        reason: '仍按横/竖屏算 orient 字段（写进日志），但不再用作门控');
    expect(helper.contains('if (!vertical || !landscape) return;'), isFalse,
        reason: 'TODO-792：旧版「非横屏早返回」门控已移除，竖屏竖排也须取证');
  });

  test('phase+朝向去重（横竖屏各打一次，避免 updatePageSize 刷屏）', () {
    expect(helper.contains('this._diag753Seen'), isTrue, reason: '须有去重标记');
    expect(helper.contains("var key = phase + '_' + orient;"), isTrue,
        reason: 'TODO-792：按 phase+朝向去重（横竖屏切换各打一次仍不刷屏）');
    expect(helper.contains('if (this._diag753Seen[key]) return;'), isTrue,
        reason: '同 phase+朝向第二次起早返回');
  });

  test('诊断走 console.log（经 onConsoleMessage → debugPrint → DebugLog 同管道）', () {
    expect(helper.contains("console.log('[753-DIAG] phase='"), isTrue,
        reason: '诊断行标签必须是 [753-DIAG] 且走 console.log，复用既有 DebugLog 桥');
  });

  test('采集两套高度量：dartH / innerH / bodyClientH / docClientH / 注入 V', () {
    // dartH = Flutter 注入的原始 viewportHeight（MediaQuery.size.height），编译期常量。
    expect(
      helper.contains(
          r"var dartH = ${dartPageHeight != null ? '${dartPageHeight.round()}' : 'null'};"),
      isTrue,
      reason: 'dartH 须是 Dart 端注入的 viewportHeight 原值',
    );
    expect(helper.contains("+ ' dartH=' + dartH"), isTrue);
    expect(helper.contains("+ ' innerH=' + window.innerHeight"), isTrue);
    expect(helper.contains("+ ' bodyClientH=' + document.body.clientHeight"),
        isTrue);
    expect(
        helper.contains(
            "+ ' docClientH=' + document.documentElement.clientHeight"),
        isTrue);
    // injectedV = getScrollContext 实际用的注入视口高（竖排列高几何唯一基准）。
    expect(helper.contains("+ ' injectedV=' + this.viewportHeight"), isTrue);
  });

  test('采集 chrome inset（getComputedStyle 读 px）+ pageStep + scrollHeight + 写向',
      () {
    expect(helper.contains("getPropertyValue('--chrome-top-inset')"), isTrue);
    expect(
        helper.contains("getPropertyValue('--chrome-bottom-inset')"), isTrue);
    expect(helper.contains("+ ' chromeTopInset=' + topInset"), isTrue);
    expect(helper.contains("+ ' chromeBottomInset=' + bottomInset"), isTrue);
    // pageStep 来自 getScrollContext（JS pageStep 实际用的 V），与 CSS 列高 V 对照。
    expect(helper.contains('var ctx = this.getScrollContext();'), isTrue,
        reason: 'pageStep 必须取自 getScrollContext，对照 CSS 列高 V');
    expect(helper.contains("+ ' pageStep=' + ctx.pageSize.toFixed(3)"), isTrue);
    expect(helper.contains("+ ' scrollHeight=' + document.body.scrollHeight"),
        isTrue);
    expect(helper.contains("+ ' writingMode=' + bodyCs.writingMode"), isTrue);
  });

  test('TODO-792：采集每页 δ —— contentBox vs 浏览器解析 columnWidth + pitchDelta', () {
    expect(helper.contains('var bodyCs = getComputedStyle(document.body);'),
        isTrue,
        reason: '复用 body computed style 读 columnWidth/columnGap');
    expect(
        helper.contains('var resolvedColW = parseFloat(bodyCs.columnWidth);'),
        isTrue,
        reason: '须读浏览器对 column-width 单次解析的 used 列高（亚像素）');
    expect(helper.contains('var contentBox = ctx.pageSize - gap;'), isTrue,
        reason: 'contentBox = JS 翻页网格列高（pageStep − gap，双 parseFloat 路径产物）');
    expect(
        helper.contains(
            'var pitchDelta = (resolvedColW > 0) ? (contentBox - resolvedColW) : null;'),
        isTrue,
        reason:
            'pitchDelta = contentBox − resolvedColumnWidth = 每页 δ（坐实/排除竖排亚像素根因的关键字段）');
    expect(helper.contains("+ ' contentBox=' + contentBox.toFixed(3)"), isTrue);
    expect(
        helper.contains(
            "+ ' resolvedColumnWidth=' + (resolvedColW > 0 ? resolvedColW.toFixed(3) : 'NaN')"),
        isTrue);
    expect(
        helper.contains(
            "+ ' pitchDelta=' + (pitchDelta != null ? pitchDelta.toFixed(3) : 'null')"),
        isTrue);
  });

  test('从 paginated initialize（恢复完成后）与 updatePageSize 各调一次', () {
    // initialize 末尾 .then 内、恢复脚本之后调 phase='init'。
    expect(source.contains("window.hoshiReader._diag753('init');"), isTrue,
        reason: '首帧布局/恢复完成后取 init 证据');
    // updatePageSize 内（横竖屏切换 / chrome inset 变化后）调 phase='resize'。
    expect(source.contains("this._diag753('resize');"), isTrue,
        reason: '尺寸变化后取 resize 证据');
  });

  test('诊断不污染 continuous shell（那里无 getScrollContext / viewportHeight 列高）', () {
    // _diag753 只能定义/调用一次（仅 paginated shell）。continuous shell 复用
    // 会因缺 getScrollContext 抛错。
    expect(
      'window.hoshiReader._diag753 = function(phase) {'
          .allMatches(source)
          .length,
      1,
      reason: '_diag753 只能在 paginated shell 定义一次，不得进 continuous shell',
    );
  });

  test('TODO-792：scrollToRange 内有 [792-REVEAL] 逐句 reveal 取证探针（仅竖排，零行为变化）', () {
    final int s = source.indexOf('scrollToRange: function(range) {');
    expect(s, greaterThan(0), reason: 'scrollToRange 必须存在');
    final int e = source.indexOf('contentLastPageScroll:', s);
    expect(e, greaterThan(s),
        reason: 'scrollToRange 之后须有 contentLastPageScroll');
    final String fn = source.substring(s, e);
    // 仅竖排门控：横排亚像素 δ 已由 TODO-753 修复，竖排 pitchDelta=0 另有来源（reveal 累积），
    // 探针只在竖排打，避免横排噪声刷屏。
    expect(fn.contains('if (context.vertical) {'), isTrue, reason: '探针须只在竖排打');
    expect(fn.contains("console.log('[792-REVEAL]'"), isTrue,
        reason: '逐句探针行标签 [792-REVEAL]，走 console.log 与 [753-DIAG] 同管道');
    // 核心判据字段：delta = anchor − targetScroll（有界震荡=floor 不累积；单调增长=坐实累积）。
    expect(
        fn.contains("+ ' delta=' + (anchor - targetScroll).toFixed(3)"), isTrue,
        reason: 'delta 是定性 floor 是否累积的核心字段');
    expect(fn.contains("+ ' anchor=' + anchor.toFixed(2)"), isTrue);
    expect(fn.contains("+ ' targetScroll=' + targetScroll.toFixed(2)"), isTrue);
    // rAF 复读探针：核验 vertical-rl scrollTop 是否亚像素回读漂移。
    expect(fn.contains("console.log('[792-REVEAL-RB]'"), isTrue,
        reason: 'rAF 复读 [792-REVEAL-RB] 核验 scrollTop 回读漂移');
    expect(fn.contains("+ ' rbDelta=' + (readback - targetScroll).toFixed(3)"),
        isTrue);
    // 零行为变化：探针不得改动既有 floor 对齐逻辑（仅取证）。
    expect(fn.contains('var targetScroll = this.alignToPage(context, anchor);'),
        isTrue,
        reason: '探针不改既有 floor 对齐（仅取证，本轮不动行为）');
  });
}
