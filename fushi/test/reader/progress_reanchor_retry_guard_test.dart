import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-493 (TODO-1053 Bug B) 源码守卫：重锚时序竞态致进度概率不显示——事件驱动版。
///
/// 恢复完成后 _reanchorContinuousAfterRestore 的 begin 同步置 JS 侧 _reanchorPending=true，
/// 紧跟的首发 _refreshProgress() 撞上 → stableProgressInvocation 返 null → 早退 → 顶部进度条
/// 隐藏。旧修复在 Dart 侧武装 120ms×8 有界轮询重试兜「清旗时机不可知」；根因是
/// _reanchorPending 的 true→false 转换发生在 JS 侧却无回调通知 Dart。
///
/// 根因修复（轮询 → 事件）：JS 侧把 _reanchorPending 的写入收敛到单一 setter
/// `_setReanchorPending`（_sharedJs，两 shell 共用），true→false（重锚 settle）那一刻
/// callHandler('onReanchorSettled') 通知 Dart；Dart 侧（webview.part.dart）注册该 handler，
/// 收到即补刷一次进度。任何一处清旗（含 commit 成功之外的逃逸路径）都会通知，轮询重试
/// 机制整体删除。本守卫盯死：清旗单点化（除 setter 外无直接赋值）、settle 通知存在、
/// Dart handler 接线、轮询不复活、onAfterCommit 补刷仍在。
void main() {
  String read(String path) => File(path).readAsStringSync();

  test('JS 侧 _reanchorPending 写入单点化（唯一赋值在 _setReanchorPending 内）', () {
    final String js = read('lib/src/reader/reader_pagination_scripts.dart');
    expect(js, contains('_setReanchorPending: function(value)'),
        reason: '_sharedJs 必须定义清旗单点 setter（两 shell 共用）');
    // 赋值（非 ===/!== 比较）只允许 setter 内那一处：`this._reanchorPending = value === true;`。
    final RegExp assignment = RegExp(r'\._reanchorPending\s*=(?![=])');
    final int assignments = assignment.allMatches(js).length;
    expect(assignments, 1,
        reason: '除 _setReanchorPending 内部外不得有任何 _reanchorPending 直接赋值——'
            '直接赋值会绕过 true→false 的 settle 通知，进度重新锁死等 10s 轮询');
  });

  test('JS 侧 true→false 转换必须 callHandler(onReanchorSettled) 通知 Dart', () {
    final String js = read('lib/src/reader/reader_pagination_scripts.dart');
    final int start = js.indexOf('_setReanchorPending: function(value)');
    expect(start, greaterThan(-1));
    final int end = js.indexOf('\n  },', start);
    expect(end, greaterThan(start));
    final String body = js.substring(start, end);
    expect(body, contains("callHandler('onReanchorSettled')"),
        reason: 'settle（true→false）必须经 bridge 通知 Dart 补刷进度');
    // 只在真的发生 true→false 转换时通知（置 true / false→false 不得刷屏）。
    expect(body, contains('this._reanchorPending === true'),
        reason: '通知必须以「旧值为 true」为前提（true→false 转换判定）');
  });

  test('Dart 侧注册 onReanchorSettled handler 并补刷进度', () {
    final String webview =
        read('lib/src/pages/implementations/reader_fushi/webview.part.dart');
    expect(webview, contains("handlerName: 'onReanchorSettled'"),
        reason: 'webview.part.dart 必须注册 settle 通知 handler');
    final int start = webview.indexOf("handlerName: 'onReanchorSettled'");
    final String body = webview.substring(start, start + 400);
    expect(body, contains('_refreshProgress()'),
        reason: '收到 settle 通知必须补刷一次进度（替代轮询重试的职责）');
  });

  test('旧的轮询重试机制不得复活（120ms×8 兜底已被事件驱动替代）', () {
    final String nav = read(
        'lib/src/pages/implementations/reader_fushi/navigation.part.dart');
    final String page =
        read('lib/src/pages/implementations/reader_fushi_page.dart');
    expect(nav, isNot(contains('_maybeArmProgressReanchorRetry')),
        reason: '轮询重试武装点已删（根因已在 JS 侧事件化）');
    expect(page, isNot(contains('Timer? _progressReanchorRetryTimer')),
        reason: '重试定时器字段已删');
    expect(page, isNot(contains('_kProgressRetryMax')), reason: '重试上限常量已删');
  });

  test('onAfterCommit 补刷仍在（重锚 commit 成功路径不回归）', () {
    final String chrome =
        read('lib/src/pages/implementations/reader_fushi/chrome.part.dart');
    // TODO-1309：连续模式恢复的 onAfterCommit 从单行箭头改为 async 块——commit 清
    // `_reanchorPending` + 打 B-3 settle 窗之后，先应用排队的章内精确定位
    // （_applyPendingPreciseLocate，跨章搜索跳转的 scrollToSearchMatch），再
    // _refreshProgress 补刷。TODO-933 的 commit 成功补刷路径（_refreshProgress）必须
    // 保留（在精确定位之后刷，进度反映 locate 后位置；onReanchorSettled 事件发生在
    // locate 之前，二者互补）；空白归一后比对逻辑内容（dart format 折行）。
    final String chromeFlat = chrome.replaceAll(RegExp(r'\s+'), ' ');
    expect(
        chromeFlat,
        contains('onAfterCommit: () async { '
            'await _applyPendingPreciseLocate(); '
            'await _refreshProgress(); },'),
        reason: 'TODO-933 的 commit 成功补刷路径保留（TODO-1309 后先应用精确定位再补刷）');
  });
}
