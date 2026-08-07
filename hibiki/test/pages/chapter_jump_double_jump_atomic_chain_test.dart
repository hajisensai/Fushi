import 'package:flutter_test/flutter_test.dart';

import 'reader_hibiki_page_source_corpus.dart';

/// BUG-615 / TODO-1309 ② 源码守卫：跨章「精确跳转」双跳（首跳只到章节）。
///
/// 旧两段式（先 `_navigateToChapterAndWait` 落章首 → 调用方在 restore 完成微任务里抢发
/// `scrollToSearchMatch` / `restoreProgress`）会被随后的 settle-reflow / 连续重锚采样冲回
/// 章首——只有目标章已是当前章（第二次点，章节已 settle）才生效。根因修：收敛为一次原子
/// 恢复链——书签/收藏/字符跳转把分数**烘进导航**（progress），搜索跳转排进 `_pendingPreciseLocate`
/// 由 `_onRestoreComplete` 在 settle **之后**应用。跳转走 WebView 几何 + 恢复代际状态机，
/// widget 层难真触发，按项目范式（`chapter_jump_pagination_in_flight_guard_test.dart` /
/// `favorite_jump_char_anchor_guard_test.dart`）锁契约分流点不回归。
///
/// 谁把跨章跳转退回两段式（滞后抢发 / `!ok` 早退 / 不烘 progress / 不在 settle 后应用），红。
void main() {
  late String source;

  setUpAll(() {
    source = readReaderPageSource();
  });

  String slice(String from, String to) {
    final int a = source.indexOf(from);
    expect(a, isNonNegative, reason: '找不到锚点：$from');
    final int b = source.indexOf(to, a + from.length);
    expect(b, greaterThan(a), reason: '找不到结束锚点：$to（起点 $from）');
    return source.substring(a, b);
  }

  test('_navigateToChapterAndWait 收 progress + preciseLocateJs 并全部转发', () {
    final String body = slice(
      'Future<bool> _navigateToChapterAndWait(',
      'return success && _currentChapter == resolvedChapter;',
    );
    expect(body, contains('double progress = 0.0,'),
        reason: '必须能把目标章内分数烘进导航（书签/收藏/字符跳转）');
    expect(body, contains('String? preciseLocateJs,'),
        reason: '必须能排入章内文本定位（搜索跳转，分数无法表达文本命中）');
    // progress + charOffset 必须透传给 _navigateToChapter（否则烘进导航失效、退回章首）。
    // TODO-1308 问题②：转发调用升级为多参（progress/charOffset/charOffsetEnd），
    // 收藏跳转靠 charOffset 走精确字符锚，书签/字符跳转仍可走 progress。
    expect(body, contains('_navigateToChapter(index,'),
        reason:
            'progress/charOffset 必须转发给 _navigateToChapter → _beginNavigation');
    expect(body, contains('charOffset: charOffset,'),
        reason: 'charOffset 必须转发（收藏绝对字符锚运输通道）');
    expect(body, contains('progress: progress,'),
        reason: 'progress 仍必须转发（书签/字符跳转分数路径）');
    expect(body, contains('preciseLocateJs: preciseLocateJs'),
        reason: '搜索定位意图必须转发到 _navigateToChapter，不能留在 loadUrl await 之后');
  });

  test('_beginNavigation 在 loadUrl 前清旧 pending 并绑定本次代际', () {
    final String body = slice(
      'void _beginNavigation({',
      '_startContentReadyTimeout();',
    );
    expect(body, contains('_preciseLocateQueue.clear();'),
        reason: '新一次导航必须作废上一次排队但未消费的章内定位');
    expect(body, contains('String? preciseLocateJs,'),
        reason: '定位意图必须进入导航初始化原子步骤');
    expect(body, contains('_preciseLocateQueue.replace('),
        reason: '本次定位必须在 loadUrl 前进入 last-write-wins 队列');
    expect(body, contains('generation: _navigateGeneration,'),
        reason: '本次 pending 必须绑定已经递增的 _navigateGeneration');

    final String navigate = slice(
      'Future<void> _navigateToChapter(',
      'Future<bool> _navigateToChapterAndWait(',
    );
    final int beginIdx = navigate.indexOf('_beginNavigation(');
    final int loadIdx = navigate.indexOf('await _loadChapterDirectly(index);');
    expect(beginIdx, isNonNegative);
    expect(loadIdx, greaterThan(beginIdx),
        reason: '必须先绑定定位意图再 loadUrl；反过来会让 onRestoreComplete 消费空 pending');
    expect(navigate, contains('preciseLocateJs: preciseLocateJs,'),
        reason: '_navigateToChapter 必须把定位意图交给 _beginNavigation');
  });

  test('_applyPendingPreciseLocate 有代际守卫且消费一次', () {
    final String body = slice(
      'Future<void> _applyPendingPreciseLocate() async {',
      'debugPrint(\'[ReaderFushi] _applyPendingPreciseLocate failed',
    );
    expect(body, contains('_preciseLocateQueue.consume('),
        reason: '消费必须经过 last-write-wins 队列的一次性代际守卫');
    expect(body, contains('generation: _navigateGeneration,'),
        reason: '只消费当前导航代际');
    expect(body, contains('canApply: mounted && _controller != null,'),
        reason: 'dispose/控制器释放后必须丢弃 pending，不执行旧 DOM 脚本');
  });

  test('dispose 立即中止导航等待并清除 pending', () {
    final String body = slice(
      'void dispose() {',
      'super.dispose();',
    );
    expect(body, contains('_failNavigation();'),
        reason: 'dispose 必须立即 complete(false) 并清 pending，不能让搜索回调挂到超时');
  });

  test('_onRestoreComplete 在 settle 之后应用 pending（分派互斥：非连续直接 / 连续走 reanchor）',
      () {
    // 非连续（分页/VN）：章节 restore 完成即已分页 snap，直接应用。
    final String restore = slice(
      'void _onRestoreComplete() {',
      '_startProgressPoll();',
    );
    final int reanchorIdx =
        restore.indexOf('_reanchorContinuousAfterRestore();');
    final int nonContIdx =
        restore.indexOf('if (_settings?.isContinuousMode != true) {');
    expect(reanchorIdx, isNonNegative);
    expect(nonContIdx, greaterThan(reanchorIdx),
        reason: '非连续直接应用必须在 reanchor 之后（连续由 reanchor onAfterCommit 应用）');
    final String nonCont = restore.substring(nonContIdx);
    expect(nonCont, contains('unawaited(_applyPendingPreciseLocate());'),
        reason: '非连续模式直接应用 pending');

    // 连续：reanchor commit 清旗 + 打 B-3 settle 窗之后才应用（onAfterCommit），先应用再补刷。
    final String onAfter = slice(
      'onAfterCommit: () async {',
      'await _refreshProgress();',
    );
    expect(onAfter, contains('await _applyPendingPreciseLocate();'),
        reason: '连续模式在 reanchor commit（settle）之后应用 pending');
  });

  test('onSearchJump 按 logical chapter + DOM ready 分流，跨章排队且同章在飞最后写胜出', () {
    final String body = slice(
      'onSearchJump: (BookSearchResult result, String query) async {',
      'favoriteSentences: favorites,',
    );
    // 跨章必须把定位排进导航链（preciseLocateJs），而不是导航后抢发。
    expect(body, contains('preciseLocateJs:'), reason: '跨章搜索定位必须排进导航的原子恢复链');
    expect(body, contains('scrollToSearchMatchInvocation'),
        reason: '搜索定位仍用 scrollToSearchMatch（文本命中）');
    expect(body, contains('decideReaderSearchJump('),
        reason: '不得只比较 sectionIndex/currentChapter；必须同时判断 DOM ready');
    expect(
        body,
        contains(
            'if (!mounted || _book == null || _controller == null) return;'),
        reason: '搜索弹层回调晚到 dispose 后不得继续排队或求值旧 WebView');
    expect(body, contains('ReaderSearchJumpAction.replacePending'),
        reason: '同一逻辑目标章仍在 restore 时，新选择必须替换本代 pending');
    expect(body, contains('_preciseLocateQueue.replace('),
        reason: '最后一次同章选择必须成为 settle 后唯一执行的定位');
    // 旧的首跳 !ok 早退（停在章首、要点两次）必须已删除。
    expect(body.contains('if (!ok'), isFalse,
        reason: '删掉 !ok 早退——定位随恢复落定 settle 之后确定性应用，不再靠第二次点');
  });

  test('收藏/字符跨章跳转把分数烘进 _navigateToChapterAndWait(progress:)', () {
    // TODO-1308 问题②（BUG-696）：收藏跳转从「烘分数」升级为「烘绝对字符锚」——
    // fav.normCharOffset 是 getNormalizedOffset 的章内绝对可匹配字符索引（不是
    // 0-10000 分数），跨章烘进 _navigateToChapterAndWait(charOffset:)、同章直接
    // restoreToCharOffset。原子链（单次恢复、跨章分支不滞后抢发）语义不变，只是
    // 恢复目标由分数换成精确字符锚。闭包已抽成 _jumpToFavoriteSentence 方法。
    final String fav = slice(
        'Future<void> _jumpToFavoriteSentence(FavoriteSentence fav) async {',
        'class _ReaderGalleryPage extends StatefulWidget {');
    expect(fav, contains('_navigateToChapterAndWait('),
        reason: '收藏跨章走 navigate-with-baked-charOffset（原子恢复链）');
    expect(fav, contains('charOffset: useOffset ? normCharOffset :'),
        reason: '收藏把目标绝对字符锚烘进导航（不再 /10000 当分数落章首）；'
            'BUG-876 起 charOffset 条件化(useOffset ? … : null)，收藏缺 offset 回退文本搜索');
    expect(fav.contains('progress:'), isFalse,
        reason: '收藏跳转不得再把绝对字符索引当分数烘进 progress');
    expect('fushiReader.restoreProgress('.allMatches(fav).length, 0,
        reason: '收藏同章分支改用 restoreToCharOffset 精确锚，不再 restoreProgress');
    expect('restoreToCharOffset('.allMatches(fav).length, 1,
        reason: '收藏同章分支保留一条 restoreToCharOffset 直接锚');

    final String charJump = slice(
      'Future<void> _jumpToGlobalCharOffset(int globalOffset) async {',
      'Future<void> _flushReadingStats()',
    );
    expect(charJump, contains('_navigateToChapterAndWait('),
        reason: '字符跳转跨章统一走原子链（await 到恢复落定），不再裸 fire-and-forget');
    expect(charJump, contains('progress: target.progress,'),
        reason: '字符跳转把章内分数烘进导航');
  });
}
