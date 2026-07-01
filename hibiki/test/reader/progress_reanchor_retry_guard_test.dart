import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-493 (TODO-1053 Bug B) 源码守卫：重锚时序竞态致进度概率不显示。
///
/// 恢复完成后 _reanchorContinuousAfterRestore 的 begin 同步置 JS 侧 _reanchorPending=true，
/// 紧跟的首发 _refreshProgress() 撞上 → stableProgressInvocation 返 null → 早退 → 顶部进度条
/// 隐藏，只剩 10s 轮询（要滑一下/查词滚 DOM 才补触发到 100%）。TODO-933 的 onAfterCommit 只
/// 覆盖「重锚 commit 成功」一条；gate 不放行 / begin 采不到锚 / 已有别处重锚在飞等逃逸路径下
/// commit 与 onAfterCommit 都不跑 → 进度仍锁死。
///
/// 根因修复：_refreshProgress 读到「真实文本章却返 null」（重锚在飞瞬态）时武装一次有界短延迟
/// 重试，重锚一清旗即补到真值，覆盖所有逃逸路径；拿到真实快照即撤销并复位。本守卫盯死重试
/// 接线点存在、只对文本章武装、拿快照即撤销、dispose 清理。
void main() {
  String read(String path) => File(path).readAsStringSync();

  test('_refreshProgress null 分支武装重锚重试（不再无条件早退丢进度）', () {
    final String nav = read(
        'lib/src/pages/implementations/reader_hibiki/navigation.part.dart');
    // null 结果不再一律 return，而是先武装重试。
    expect(nav, contains('if (result == null) {'),
        reason: 'null 结果单独分支处理，供武装重试');
    expect(nav, contains('_maybeArmProgressReanchorRetry();'),
        reason: 'null（重锚在飞瞬态）时武装一次重试');
    // 拿到真实快照即撤销待重试并复位计数。
    expect(nav, contains('_cancelProgressReanchorRetry();'),
        reason: '真实快照落地即撤销待重试');
  });

  test('重试只对真实文本章武装、有界、coalesce（图片章 null 是稳态不重试）', () {
    final String nav = read(
        'lib/src/pages/implementations/reader_hibiki/navigation.part.dart');
    // 图片/封面章的 null 是稳态 → 跳过，避免空转。
    expect(
        nav, contains('if (book.isImageOnlyChapter(_currentChapter)) return;'),
        reason: '纯图片章 null 是稳态，不武装重试');
    // 有界：达到上限不再排队。
    expect(
        nav,
        contains(
            'if (_progressReanchorRetryCount >= _kProgressRetryMax) return;'),
        reason: '有界重试，超界回落 10s 轮询');
    // coalesce：已武装不重复排队。
    expect(nav, contains('if (_progressReanchorRetryTimer != null) return;'),
        reason: '已武装不重复排队（coalesce）');
  });

  test('重试字段声明 + dispose 清理定时器', () {
    final String page =
        read('lib/src/pages/implementations/reader_hibiki_page.dart');
    expect(page, contains('Timer? _progressReanchorRetryTimer;'),
        reason: '重试定时器字段必须存在');
    expect(page, contains('static const int _kProgressRetryMax'),
        reason: '重试上限常量必须存在（有界）');
    expect(page, contains('_progressReanchorRetryTimer?.cancel();'),
        reason: 'dispose 必须清理重试定时器（防泄漏）');
  });

  test('onAfterCommit 补刷仍在（重锚 commit 成功路径不回归）', () {
    final String chrome =
        read('lib/src/pages/implementations/reader_hibiki/chrome.part.dart');
    expect(chrome, contains('onAfterCommit: () => _refreshProgress(),'),
        reason: 'TODO-933 的 commit 成功补刷路径保留，与新重试互补');
  });
}
