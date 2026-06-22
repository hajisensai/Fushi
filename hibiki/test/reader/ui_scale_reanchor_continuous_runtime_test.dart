import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/reader_hibiki_page.dart'
    show runUiScaleReanchorOrchestration;

/// TODO-697 item①：693 修复（连续模式改 appUiScale 重锚）此前只有 7 个纯函数真值表 +
/// 7 个源码字符串扫描守卫，**没有运行时执行** begin→（intResult 解析）→ postFrame →
/// commit 这条 Dart 编排序列。源码扫描对「调用仍在、顺序仍对」假绿——若未来有人把
/// `await evalBegin` 改成不 await、把 `charOffset < 0` 早返回删掉、或在门控抑制下仍求值，
/// 字符串扫描照样能命中关键字而通过。
///
/// 本文件直接对编排核心 [runUiScaleReanchorOrchestration]（从 `_reanchorContinuousForUiScale`
/// 抽出的 top-level 函数，回调注入 WebView 求值 / postFrame 调度 / 存活复检 / 错误上报）
/// 做**运行时执行**断言：用 recording fake 记录每次求值的 invocation 与时序，锁住
/// 「begin 在 commit 之前、begin<0 不 commit、门控抑制不求值、求值异常吞掉不外抛」的
/// 真实运行时语义。
///
/// 这是 headless 下能落地的**最窄真行为层**：完整 mount `ReaderHibikiPage` 不可行——
/// 测试用的 fake InAppWebView 平台（见 `test/helpers/fake_inappwebview_platform.dart`）
/// 是惰性的，其 `_controller` 永不就绪（恒 null），门控 `controllerAvailable:false` 直接
/// 早返回，根本到不了 begin/commit。故退到注入式编排核心，仍是运行时执行而非源码扫描。
void main() {
  /// 记录一次求值调用的阶段标签（begin / commit），用来断言**发生与顺序**。
  late List<String> evals;

  /// 待手动触发的 postFrame 回调（模拟 addPostFrameCallback 的延迟语义：
  /// 不立即跑，等测试显式 pump 一帧再跑），用来断言 commit 确实被调度到 begin 之后的帧。
  late List<void Function()> pendingPostFrame;

  setUp(() {
    evals = <String>[];
    pendingPostFrame = <void Function()>[];
  });

  /// 跑完所有挂起的 postFrame 回调（模拟一帧 settle）。回调内是异步求值，
  /// 跑完后等微任务队列排空，确保 evalCommit 的 await 已落地。
  Future<void> pumpOnePostFrame() async {
    final List<void Function()> due =
        List<void Function()>.from(pendingPostFrame);
    pendingPostFrame.clear();
    for (final void Function() cb in due) {
      cb();
    }
    // 让 schedulePostFrame 回调里的 async evalCommit 把微任务跑完。
    await Future<void>.delayed(Duration.zero);
  }

  /// 构造一次编排调用：门控可调，begin 返回值可调，commit 是否抛异常可调。
  /// 返回 future（编排主体）；postFrame 由 [pendingPostFrame] 收集，需测试手动 pump。
  Future<void> runOrchestration({
    bool controllerAvailable = true,
    bool readerContentReady = true,
    bool lyricsMode = false,
    bool restoreInFlight = false,
    bool continuousMode = true,
    Object? beginResult = 1234,
    bool throwOnBegin = false,
    bool throwOnCommit = false,
    bool stillAlive = true,
    List<Object>? beginErrors,
    List<Object>? commitErrors,
  }) {
    return runUiScaleReanchorOrchestration(
      controllerAvailable: controllerAvailable,
      readerContentReady: readerContentReady,
      lyricsMode: lyricsMode,
      restoreInFlight: restoreInFlight,
      continuousMode: continuousMode,
      evalBegin: () async {
        evals.add('begin');
        if (throwOnBegin) throw StateError('begin boom');
        return beginResult;
      },
      evalCommit: () async {
        evals.add('commit');
        if (throwOnCommit) throw StateError('commit boom');
      },
      schedulePostFrame: (void Function() commit) =>
          pendingPostFrame.add(commit),
      stillAlive: () => stillAlive,
      onBeginError: (Object e, StackTrace _) => beginErrors?.add(e),
      onCommitError: (Object e, StackTrace _) => commitErrors?.add(e),
    );
  }

  group('runUiScaleReanchorOrchestration 运行时序列（TODO-697 item①）', () {
    test('连续模式 + 就绪：begin 同步求值 → pump 一帧 → commit 求值，begin 在 commit 之前',
        () async {
      // 阶段1（begin）应在编排 await 完成时已发生；commit 此时尚未发生（在 postFrame）。
      await runOrchestration();
      expect(evals, <String>['begin'],
          reason: '阶段1 begin 必须在编排主体返回前发生（同步采锚+置旗）；'
              'commit 必须延迟到 postFrame，不能在同一帧立即求值');
      expect(pendingPostFrame, hasLength(1),
          reason: 'begin 成功（>=0）后必须调度一个 postFrame 提交 commit');

      // 阶段2（commit）只在 pump 过渡帧 settle 后才发生。
      await pumpOnePostFrame();
      expect(evals, <String>['begin', 'commit'],
          reason: 'commit 必须在 postFrame settle 后求值，且严格发生在 begin 之后');
      final int idxBegin = evals.indexOf('begin');
      final int idxCommit = evals.indexOf('commit');
      expect(idxBegin, lessThan(idxCommit),
          reason: 'begin 必须严格在 commit 之前（先采锚置旗，settle 后才滚回清旗）');
    });

    test('begin 返回 -1（无锚/已有重锚在飞）：不调度 postFrame，永不 commit', () async {
      await runOrchestration(beginResult: -1);
      expect(evals, <String>['begin'],
          reason: 'begin 仍求值（要拿返回值判定），但 -1 时必须就此打住');
      expect(pendingPostFrame, isEmpty,
          reason: 'begin 返回 -1 必须不调度 postFrame（不提交、不误清别处重锚旗）');

      // 即便强行 pump 一帧也不该冒出 commit（根本没调度）。
      await pumpOnePostFrame();
      expect(evals, <String>['begin'], reason: 'begin<0 后无论是否过帧，commit 都不得发生');
    });

    test('begin 返回字符串 "-1"（JS 字符串结果经 intResult 解析）同样抑制 commit', () async {
      // 运行时真走 ReaderPaginationScripts.intResult：字符串 "-1" → -1 → 抑制。
      await runOrchestration(beginResult: '-1');
      expect(pendingPostFrame, isEmpty,
          reason: '字符串 "-1" 经 intResult 解析为 -1，必须与 int -1 同样抑制 commit');
      await pumpOnePostFrame();
      expect(evals, <String>['begin']);
    });

    test('begin 返回字符串数字 "0"（章首有效锚）：仍提交 commit', () async {
      // intResult("0") == 0，>=0 视为有效锚 → 必须提交。
      await runOrchestration(beginResult: '0');
      expect(pendingPostFrame, hasLength(1),
          reason: 'charOffset==0 是有效锚（章首），必须调度 commit');
      await pumpOnePostFrame();
      expect(evals, <String>['begin', 'commit']);
    });
  });

  group('门控抑制：任一守卫不满足时不求值 begin/commit', () {
    test('分页模式（continuousMode==false）抑制——分页有 snap/lock 保护', () async {
      await runOrchestration(continuousMode: false);
      await pumpOnePostFrame();
      expect(evals, isEmpty, reason: '分页模式门控抑制：begin/commit 都不得求值');
      expect(pendingPostFrame, isEmpty);
    });

    test('歌词模式（lyricsMode）抑制', () async {
      await runOrchestration(lyricsMode: true);
      await pumpOnePostFrame();
      expect(evals, isEmpty, reason: '歌词模式门控抑制：不得求值');
    });

    test('恢复期（restoreInFlight）抑制——程序化恢复滚动期不重锚', () async {
      await runOrchestration(restoreInFlight: true);
      await pumpOnePostFrame();
      expect(evals, isEmpty, reason: '恢复期门控抑制：不得求值');
    });

    test('内容未就绪（!readerContentReady）抑制——锚还算不出', () async {
      await runOrchestration(readerContentReady: false);
      await pumpOnePostFrame();
      expect(evals, isEmpty, reason: '内容未就绪门控抑制：不得求值');
    });

    test('控制器已释放（!controllerAvailable）抑制——dispose 竞态', () async {
      await runOrchestration(controllerAvailable: false);
      await pumpOnePostFrame();
      expect(evals, isEmpty, reason: '控制器释放门控抑制：不得求值');
    });
  });

  group('存活复检与异常吞咽（运行时）', () {
    test('begin 后已不存活（dispose 竞态）：不调度 postFrame，不 commit', () async {
      await runOrchestration(stillAlive: false);
      expect(evals, <String>['begin'],
          reason: 'begin 已发起；但 begin 返回后 stillAlive==false 必须中止，不调度提交');
      expect(pendingPostFrame, isEmpty, reason: 'begin 后不存活：不得调度 postFrame');
      await pumpOnePostFrame();
      expect(evals, <String>['begin']);
    });

    test('begin 求值抛异常：上报 onBeginError 并整体中止（不外抛、不 commit）', () async {
      final List<Object> beginErrors = <Object>[];
      await runOrchestration(throwOnBegin: true, beginErrors: beginErrors);
      expect(beginErrors, hasLength(1),
          reason: 'begin 异常必须经 onBeginError 上报（吞掉不外抛，否则 setState/build 路径炸）');
      expect(pendingPostFrame, isEmpty, reason: 'begin 抛异常后必须中止，不调度 commit');
      await pumpOnePostFrame();
      expect(evals, <String>['begin'], reason: 'begin 异常路径下 commit 不得发生');
    });

    test('commit 求值抛异常：上报 onCommitError 并吞掉（不外抛，旗在生产侧 finally 清）', () async {
      final List<Object> commitErrors = <Object>[];
      await runOrchestration(throwOnCommit: true, commitErrors: commitErrors);
      expect(pendingPostFrame, hasLength(1));
      // pump 一帧触发 commit；commit 抛异常应被 onCommitError 吞掉，不冒泡出 pumpOnePostFrame。
      await pumpOnePostFrame();
      expect(commitErrors, hasLength(1),
          reason: 'commit 异常必须经 onCommitError 上报且不外抛（postFrame 回调里抛会被引擎吞或崩）');
      expect(evals, <String>['begin', 'commit']);
    });
  });
}
