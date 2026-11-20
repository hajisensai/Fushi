import 'dart:io';

import 'package:test/test.dart';

import '../helpers/source_guard.dart';

/// BUG-1140 源码守卫：跨章提速的三个确定性结构不许被悄悄退回去。
///
/// 背景：这次提速删掉的是**空等**——两处 `_settleAndNotify` 里回调体为空、只为再拖
/// 16ms 才通知 Dart 的第二层 `setTimeout`；同时把「新章可见之后的收尾」挪出遮罩那一帧。
/// 唯一端到端验证是 `integration_test/reader_cross_chapter_perf_itest.dart`，它是
/// Windows 离屏 / 真机 itest，**不进 CI 单测门**。也就是说日后有人为了修某个闪烁，把
/// 空等原样加回来，或者把收尾又搬回同步路径，没有任何东西会红。这里补上那个「会红」。
///
/// 钉三条：
/// 1. 两处 `_settleAndNotify` 各只剩**一层** `setTimeout`（第二层空等不许回来）。
/// 2. 分页 shell 的那一层里，落点是**同步写死**再通知的：`reapplyImageLateAnchor`
///    （按已登记的语义锚重设落点，BUG-4808）→ `registerSnapScroll` →
///    `notifyRestoreComplete` 顺序在位。这是「Dart 收到通知时落点已定」的 program-order
///    保证，不是时间赌——顺序一乱就退化成赌。回调**不得**写回延后之前捕获的像素位置
///    （迟到图片重锚 / 用户翻页会被盖掉）；行为由
///    `test/reader/paged_settle_semantic_anchor_behavior_test.dart` 用 Node 真跑钉住。
/// 3. 延后一帧的收尾块带 `_navigateGeneration` 代际守卫（只有 `mounted` 不够：跨章
///    快速连点时旧收尾会把旧章位置写进新导航）。
void main() {
  String read(String rel) {
    final File f = File(rel);
    expect(f.existsSync(), isTrue, reason: '文件不存在：$rel');
    return f.readAsStringSync().replaceAll('\r\n', '\n');
  }

  /// 取 `_settleAndNotify: function(` 起到下一个同层属性 `restoreProgress:` 为止的体，
  /// 断言只落在该函数上。
  List<String> settleBodies(String src) {
    final List<String> bodies = <String>[];
    int from = 0;
    while (true) {
      final int start = src.indexOf('_settleAndNotify: function(', from);
      if (start < 0) break;
      final int end = src.indexOf('restoreProgress:', start);
      expect(
        end,
        greaterThan(start),
        reason: '_settleAndNotify 之后应紧跟 restoreProgress（用于界定函数体范围）',
      );
      bodies.add(src.substring(start, end));
      from = end;
    }
    return bodies;
  }

  test('两处 _settleAndNotify 都只剩一层 setTimeout（空等不许加回来）', () {
    final String src = read('lib/src/reader/reader_pagination_scripts.dart');
    final List<String> bodies = settleBodies(src);
    expect(bodies.length, 2, reason: '分页 / 连续两个 shell 各有一处 _settleAndNotify');
    for (final String body in bodies) {
      expect(
        'setTimeout('.allMatches(body).length,
        1,
        reason:
            '_settleAndNotify 里出现了不止一层 setTimeout —— 第二层历史上是**空等**，'
            '删它正是 BUG-1140 的提速主体。要加回来必须先在 BUG 文档里说明它等的是什么。',
      );
    }
  });

  test('分页 shell 的 settle 是「同步写落点再通知」的顺序（program-order 保证）', () {
    final String src = read('lib/src/reader/reader_pagination_scripts.dart');
    final String body = maskJsComments(settleBodies(src).first);
    final int setPos = body.indexOf('self.reapplyImageLateAnchor(');
    final int snap = body.indexOf('registerSnapScroll(');
    final int notify = body.indexOf('notifyRestoreComplete(');
    expect(
      setPos,
      greaterThan(-1),
      reason: 'settle 必须同步重设落点（按已登记的语义锚重算，BUG-4808）',
    );
    expect(snap, greaterThan(setPos), reason: 'snap 基线须在落点写入之后注册');
    expect(
      body.contains('_settleAndNotify: function()'),
      isTrue,
      reason:
          'BUG-4808：settle 不再接收延后之前捕获的 (context, pos)——'
          '带着像素位置进来，回调就会把它写回去、盖掉这 16ms 内的迟到图片重锚',
    );
    expect(
      body.contains('setPagePosition('),
      isFalse,
      reason:
          'BUG-4808：settle 回调不得直接写像素位置；重设落点只走 '
          'reapplyImageLateAnchor（锚已清 = 位置已归别人所有，不写）',
    );
    expect(
      body.contains(
        'if (self.getPagePosition(self.getScrollContext()) !== landed) {',
      ),
      isTrue,
      reason:
          '语义锚重算只在位置被动过时做：位置原封未动时再从章首走到锚字，是把一次与入口'
          '落点同量级的全章走查白白排在通知 Dart 之前（跨章耗时回退）。landed 只用于比较',
    );
    expect(
      body.contains(
        'registerSnapScroll(self.getPagePosition(self.getScrollContext()))',
      ),
      isTrue,
      reason: 'snap 基线取回调执行时的真实位置，不取延后之前读到的值',
    );
    expect(
      notify,
      greaterThan(snap),
      reason:
          '通知 Dart 必须排在落点写入与 snap 注册之后 —— 顺序一乱，'
          '「Dart 收到就绪时落点已定」就从 program-order 保证退化成时间赌',
    );
  });

  test('延后一帧的跨章收尾必须带 _navigateGeneration 代际守卫', () {
    final String src = read(
      'lib/src/pages/implementations/reader_fushi/navigation.part.dart',
    );
    final int start = src.indexOf('void _onRestoreComplete() {');
    expect(start, greaterThan(-1), reason: '找不到 _onRestoreComplete');
    // 以收尾内容定位块（_onRestoreComplete 里不只一个 postFrame 回调），
    // 再向前找包着它的 addPostFrameCallback。
    final int highlight = src.indexOf('_applyChapterHighlights();', start);
    expect(highlight, greaterThan(start), reason: '收尾块里应重新应用收藏高亮');
    final int postFrame = src.lastIndexOf(
      'WidgetsBinding.instance.addPostFrameCallback',
      highlight,
    );
    expect(
      postFrame,
      greaterThan(start),
      reason: '跨章收尾应在 _onRestoreComplete 里延后一帧执行',
    );
    final int end = src.indexOf('\n    });', postFrame);
    expect(end, greaterThan(postFrame));
    final String block = src.substring(postFrame, end);

    // 收尾内容仍在（挪帧不等于删功能）。
    for (final String call in <String>[
      '_applyChapterHighlights()',
      'resetImagePauseAnchor(',
      '_refreshProgress()',
      '_startProgressPoll()',
    ]) {
      expect(
        block.contains(call),
        isTrue,
        reason: '延后一帧的收尾块里少了 $call —— 挪帧不该丢功能',
      );
    }

    // 代际守卫：mounted 之外还要比对 _navigateGeneration 快照。
    expect(block.contains('mounted'), isTrue);
    expect(
      block.contains('_navigateGeneration'),
      isTrue,
      reason:
          '收尾晚一帧执行时可能已经起了新导航；只有 mounted 守卫会把旧章位置'
          '写进新导航（_refreshProgress 落库）。必须比对入口快照的代际。',
    );
    final int snapshot = src.lastIndexOf('= _navigateGeneration;', postFrame);
    expect(
      snapshot,
      greaterThan(start),
      reason: '代际快照必须在 addPostFrameCallback 之前取（回调里再读就恒相等）',
    );
  });
}
