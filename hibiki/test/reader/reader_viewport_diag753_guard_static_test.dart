import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-753 源码守卫：竖排+横屏「正文整体上偏 / 顶端被切 / 越翻越偏」是真机专属，
/// headless 测不出（注入的 viewportHeight 与 WebView 真实 innerHeight/clientHeight
/// 在 headless 下天然一致），必须靠真机取证。`window.hoshiReader._diag753(phase)`
/// 一次性把两套高度量 + chrome inset + getScrollContext().pageSize 打成一行
/// `[753-DIAG]`，经 onConsoleMessage → debugPrint → DebugLogService 环形缓冲，用户
/// 在「设置 → 诊断 → 调试日志」开开关后即可见 + 用「复制全部」复制。
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

  test('诊断只在竖排 + 横屏取证（真凶场景），其余形态早返回', () {
    expect(helper.contains('this.isVertical()'), isTrue, reason: '须按竖排判据门控');
    expect(helper.contains('window.innerWidth > window.innerHeight'), isTrue,
        reason: '须按横屏判据门控（innerW>innerH）');
    expect(helper.contains('if (!vertical || !landscape) return;'), isTrue,
        reason: '非竖排或非横屏一律早返回不打，避免无关刷屏');
  });

  test('同 phase 只打一行（去重，避免 updatePageSize 刷屏）', () {
    expect(helper.contains('this._diag753Seen'), isTrue,
        reason: '须有 per-phase 去重标记');
    expect(helper.contains('if (this._diag753Seen[phase]) return;'), isTrue,
        reason: '同 phase 第二次起早返回');
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
    expect(helper.contains("+ ' pageStep=' + ctx.pageSize"), isTrue);
    expect(helper.contains("+ ' scrollHeight=' + document.body.scrollHeight"),
        isTrue);
    expect(
        helper.contains(
            "+ ' writingMode=' + getComputedStyle(document.body).writingMode"),
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
}
