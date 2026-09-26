import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// PR #1669 审查的两处阻断：视频页的「看完再制卡」退出写入与后台制卡落地，都跑在
/// 页面 deactivate / unmount 之后。
///
/// - 退出写入在 `dispose()` 里：此时 element 已经 deactivated，`ref.read` 在 debug 抛
///   「Looking up a deactivated widget's ancestor is unsafe」、release 抛「No
///   ProviderScope found」，被外层 catch 吞掉，一张卡都写不进去（BUG-513 同类）。
///   必须改用在 `didChangeDependencies` 抓住的 ProviderContainer。
/// - 后台落地回调在页面 unmount 之后才跑：`context.mounted` 先取 `context`，而 State
///   unmount 后取 `context` 本身就抛，落地回调（写制卡历史）跟着没了。必须用 State
///   的 `mounted`。
///
/// 这两条都只在「页面关掉之后」触发，widget 测试要搭起整张视频页 + 真 Anki 后端 +
/// 延迟完成的制卡任务才能复现，所以这里钉源码形状。
void main() {
  String read(String relativePath) {
    final File file = File(relativePath);
    expect(file.existsSync(), isTrue, reason: 'missing $relativePath');
    return file.readAsStringSync();
  }

  const String pagePath = 'lib/src/pages/implementations/video_fushi_page.dart';
  const String queuePartPath =
      'lib/src/pages/implementations/video_fushi/mine_queue.part.dart';
  const String miningPartPath =
      'lib/src/pages/implementations/video_fushi/lookup_mining.part.dart';

  test('页面在 didChangeDependencies 抓住 ProviderContainer', () {
    final String body = compactCode(
      methodBody(read(pagePath), 'void didChangeDependencies()'),
    );
    expect(
      body,
      contains(
        '_providerContainer=ProviderScope.containerOf(context,listen:false);',
      ),
    );
  });

  test('dispose 里的退出写入不 ref.read，Anki 后端从缓存的 container 取', () {
    final String src = read(queuePartPath);
    final String flush = compactCode(
      methodBody(src, 'void _flushStagedMinesOnExit()'),
    );
    expect(flush, isNot(contains('ref.read(')));
    expect(flush, contains('_providerContainer.read(ankiRepositoryProvider)'));
    // 失败不能静默吞掉。
    expect(flush, isNot(contains('catch(_)')));
    expect(flush, contains('ErrorLogService.instance.log('));

    // dispose 仍然调它（退出写入这条路本身还在）。页面文件里第一处 `void dispose()`
    // 就是 `_VideoFushiPageState` 的。
    final String dispose = compactCode(
      methodBody(read(pagePath), 'void dispose()'),
    );
    expect(dispose, contains('_flushStagedMinesOnExit();'));
  });

  test('待制卡 part 里没有任何 ref.read（异步链与 dispose 都可能在失活后跑）', () {
    final String src = compactCode(read(queuePartPath));
    expect(src, isNot(contains('ref.read(')));
    final String commit = compactCode(
      methodBody(
          read(queuePartPath),
          'Future<VideoMineCommitSummary> '
          '_commitStagedMines('),
    );
    expect(commit, contains('_providerContainer.read(ankiRepositoryProvider)'));
  });

  test('后台落地用 State 的 mounted；打开列表在 await 前抓住 context', () {
    final String land = compactCode(
      methodBody(read(miningPartPath), 'MinePopupResult _landVideoMine('),
    );
    expect(land, isNot(contains('context.mounted')));
    expect(land, contains('if(!mounted)returnresult;'));

    final String open = compactCode(
      methodBody(read(queuePartPath), 'Future<void> _openVideoMineQueue()'),
    );
    // 打开列表要用 context 弹窗：await 之前先抓住 element，await 之后问它的
    // mounted（不在 await 之后取 `this.context`）。
    expect(open, contains('finalBuildContextcontext=this.context;'));
    expect(
      open.indexOf('finalBuildContextcontext=this.context;'),
      lessThan(open.indexOf('await_videoMineQueue()')),
    );
    expect(open, contains('if(!context.mounted)return;'));
  });

  test('后台落地回调写制卡历史用点击时冻结的库，不经 ref / context', () {
    final String src = read(miningPartPath);
    final int anchor =
        src.indexOf('onBackgroundLanded: (MinePopupResult landed)');
    expect(anchor, greaterThan(0));
    final String callback = compactCode(balancedBlockFrom(src, anchor));
    expect(callback, contains('_recordMinedSentenceForVideo('));
    expect(callback, contains('db:historyDb'));
    expect(callback, isNot(contains('ref.')));
    expect(callback, isNot(contains('context')));
  });
}
