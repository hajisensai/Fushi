import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/reader_hibiki_page.dart'
    show runUiScaleReanchorOrchestration;

/// TODO-933：连续/滚动模式下开书或退出再进，顶部阅读进度条初次不显示，要滑动一下才出来。
///
/// 根因竞态：`_onRestoreComplete` 调 `_reanchorContinuousAfterRestore()`（不 await）→ 编排
/// `evalBegin` 在 JS 侧同步置 `window.hoshiReader._reanchorPending = true`（清旗推迟到 postFrame
/// 的 `evalCommit`）；紧接着 `_onRestoreComplete` 里的首发 `_refreshProgress()` 执行，但
/// `stableProgressInvocation` = `!_reanchorPending ? hoshiProgressDetails() : null` → 旗为 true
/// 返 null → `_refreshProgress` 早退，`_progressCurrentChars` 保持 null → 进度条隐藏。用户滑动
/// 时旗已 commit 清掉 → 刷新成功 → 条出现。
///
/// 修复：给编排核心 [runUiScaleReanchorOrchestration] 加可选 `onAfterCommit`——commit 成功
/// **清旗之后**确定性回调一次；恢复路径把它接到 `_refreshProgress()`，旗已清不再撞 null gate，
/// 首屏进度条得以 seed。本文件对编排核心做运行时断言锁住该确定性时序（headless 下完整 mount
/// 不可行，沿用 ui_scale_reanchor_continuous_runtime_test.dart 的注入式 fake）。
void main() {
  late List<String> evals;
  late List<void Function()> pendingPostFrame;

  setUp(() {
    evals = <String>[];
    pendingPostFrame = <void Function()>[];
  });

  Future<void> pumpOnePostFrame() async {
    final List<void Function()> due =
        List<void Function()>.from(pendingPostFrame);
    pendingPostFrame.clear();
    for (final void Function() cb in due) {
      cb();
    }
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> runOrchestration({
    bool gateAllowed = true,
    Object? beginResult = 1234,
    bool throwOnCommit = false,
    bool stillAlive = true,
    List<Object>? commitErrors,
    Future<void> Function()? onAfterCommit,
  }) {
    return runUiScaleReanchorOrchestration(
      gateAllowed: gateAllowed,
      evalBegin: () async {
        evals.add('begin');
        return beginResult;
      },
      evalCommit: () async {
        evals.add('commit');
        if (throwOnCommit) throw StateError('commit boom');
      },
      schedulePostFrame: (void Function() commit) =>
          pendingPostFrame.add(commit),
      stillAlive: () => stillAlive,
      onBeginError: (Object e, StackTrace _) {},
      onCommitError: (Object e, StackTrace _) => commitErrors?.add(e),
      onAfterCommit: onAfterCommit,
    );
  }

  group('onAfterCommit 进度 seed 时序（TODO-933）', () {
    test('commit 成功后确定性回调 onAfterCommit，且严格发生在 commit（清旗）之后', () async {
      await runOrchestration(onAfterCommit: () async {
        evals.add('afterCommit');
      });
      // begin 已发生；commit / afterCommit 都在 postFrame，尚未发生。
      expect(evals, <String>['begin'],
          reason: 'commit 与补刷都必须延迟到 postFrame settle，不在 begin 同帧发生');

      await pumpOnePostFrame();
      expect(evals, <String>['begin', 'commit', 'afterCommit'],
          reason: 'commit 成功清旗后，onAfterCommit 必须确定性补跑且严格在 commit 之后');
      expect(evals.indexOf('commit'), lessThan(evals.indexOf('afterCommit')),
          reason: '补刷必须在清旗（commit）之后，旗已清才不会被 stableProgress 的 null gate 挡掉');
    });

    test('撤掉补刷（onAfterCommit 不传，旧行为）：commit 后不再有补刷——red→green 锚点', () async {
      // 不传 onAfterCommit 模拟修复前/缩放·样式重锚路径：commit 后没有 afterCommit。
      await runOrchestration();
      await pumpOnePostFrame();
      expect(evals, <String>['begin', 'commit'],
          reason: '不传 onAfterCommit 时编排只 begin→commit，不得凭空补刷（缩放/样式路径行为不变）');
      expect(evals, isNot(contains('afterCommit')));
    });

    test('commit 抛异常：onAfterCommit 不得被调用（旗未确定性清，补刷无意义）', () async {
      final List<Object> commitErrors = <Object>[];
      bool afterCommitCalled = false;
      await runOrchestration(
        throwOnCommit: true,
        commitErrors: commitErrors,
        onAfterCommit: () async {
          afterCommitCalled = true;
        },
      );
      await pumpOnePostFrame();
      expect(commitErrors, hasLength(1),
          reason: 'commit 异常仍经 onCommitError 上报');
      expect(afterCommitCalled, isFalse,
          reason: 'commit 失败旗未确定性清，补刷仍会被 null gate 挡，必须跳过');
      expect(evals, <String>['begin', 'commit']);
    });

    test('begin 返回 -1（无锚）：不调度 postFrame，onAfterCommit 永不调用', () async {
      bool afterCommitCalled = false;
      await runOrchestration(
        beginResult: -1,
        onAfterCommit: () async {
          afterCommitCalled = true;
        },
      );
      await pumpOnePostFrame();
      expect(pendingPostFrame, isEmpty);
      expect(afterCommitCalled, isFalse, reason: 'begin<0 不提交，自然也不补刷');
      expect(evals, <String>['begin']);
    });

    test('门控抑制（gateAllowed==false）：begin/commit/补刷都不发生', () async {
      bool afterCommitCalled = false;
      await runOrchestration(
        gateAllowed: false,
        onAfterCommit: () async {
          afterCommitCalled = true;
        },
      );
      await pumpOnePostFrame();
      expect(evals, isEmpty);
      expect(afterCommitCalled, isFalse);
    });

    test('补刷自身抛异常：经 onCommitError 上报后吞掉，不外抛出 postFrame 回调', () async {
      final List<Object> commitErrors = <Object>[];
      await runOrchestration(
        commitErrors: commitErrors,
        onAfterCommit: () async {
          throw StateError('refresh boom');
        },
      );
      // 不应抛出 pumpOnePostFrame。
      await pumpOnePostFrame();
      expect(commitErrors, hasLength(1),
          reason: '补刷异常必须经 onCommitError 上报且不外抛（postFrame 回调里抛会被引擎吞或崩）');
      expect(evals, <String>['begin', 'commit']);
    });
  });
}
