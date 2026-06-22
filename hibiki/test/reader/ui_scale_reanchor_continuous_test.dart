import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/reader_hibiki_page.dart'
    show readerUiScaleReanchorAllowed, readerRestoreReanchorAllowed;

import '../pages/reader_hibiki_page_source_corpus.dart';

/// TODO-693：改 appUiScale（整体界面缩放）时，**连续/滚动模式**阅读位置被弹回章节开头。
///
/// 根因：连续模式阅读位置是裸 `window.scrollY`，没有分页模式的
/// `registerSnapScroll`/`lockRootViewport` 保护。HibikiAppUiScale 用新 scale 重建两层
/// FittedBox/SizedBox → reader 子树（含 WebView 平台视图）box.size 过渡帧抖动 → 击穿
/// SetSizeDedup → native put_Bounds → WebView2 reflow 把 document scrollY 瞬时归 0；归零
/// 后连续模式无机制拉回，被章内 scroll 回传通道（onReaderScroll）当作真实滚动落库
/// progress≈0 → 弹回章首。
///
/// 修复（方案 D，镜像 setChromeInsets 的 `_reanchorPending` 串行契约，Dart 两阶段编排）：
/// reader 在 `ref.listen` 监听 `appUiScale` 变化 →（仅连续模式 + 门控通过）阶段 1 同步
/// 采样首个可见字符偏移并置 `_reanchorPending`（挡住 reflow 归零 scroll 污染落库）→
/// postFrame settle 后阶段 2 把锚滚回视口首边并清旗。
///
/// reader_hibiki_page.dart 太重（真 InAppWebView + DB + provider）不便整页 mount，门控逻辑
/// 抽成 [readerUiScaleReanchorAllowed] 纯函数在此锁定真值表；JS 两阶段重锚原语 + Dart
/// 接线由源码扫描守卫锁定，防回归。
///
/// TODO-697 item①：两阶段编排（门控→begin→intResult→postFrame→commit）的**运行时序列**
/// 由 `ui_scale_reanchor_continuous_runtime_test.dart` 真执行 [runUiScaleReanchorOrchestration]
/// 锁定（源码扫描对「调用仍在、顺序仍对」假绿）；本文件保留真值表 + JS/Dart 源码扫描守卫。
void main() {
  group('readerUiScaleReanchorAllowed（appUiScale 连续重锚门控真值表）', () {
    test('连续模式 + 全部就绪：触发重锚', () {
      expect(
        readerUiScaleReanchorAllowed(
          controllerAvailable: true,
          readerContentReady: true,
          lyricsMode: false,
          restoreInFlight: false,
          continuousMode: true,
        ),
        isTrue,
      );
    });

    test('分页模式（continuousMode==false）一律抑制——分页有 snap/lock 保护', () {
      expect(
        readerUiScaleReanchorAllowed(
          controllerAvailable: true,
          readerContentReady: true,
          lyricsMode: false,
          restoreInFlight: false,
          continuousMode: false,
        ),
        isFalse,
        reason: '分页模式 registerSnapScroll/lockRootViewport 已挡住 reflow 归零，'
            '不需要也不应触发本重锚',
      );
    });

    test('歌词模式（lyricsMode）抑制——非正文阅读无章内 scrollY 语义', () {
      expect(
        readerUiScaleReanchorAllowed(
          controllerAvailable: true,
          readerContentReady: true,
          lyricsMode: true,
          restoreInFlight: false,
          continuousMode: true,
        ),
        isFalse,
      );
    });

    test('恢复期（restoreInFlight）抑制——程序化恢复滚动期不重锚，避免竞态', () {
      expect(
        readerUiScaleReanchorAllowed(
          controllerAvailable: true,
          readerContentReady: true,
          lyricsMode: false,
          restoreInFlight: true,
          continuousMode: true,
        ),
        isFalse,
      );
    });

    test('内容未就绪（!readerContentReady）抑制——锚还算不出', () {
      expect(
        readerUiScaleReanchorAllowed(
          controllerAvailable: true,
          readerContentReady: false,
          lyricsMode: false,
          restoreInFlight: false,
          continuousMode: true,
        ),
        isFalse,
      );
    });

    test('控制器已释放（!controllerAvailable）抑制——dispose 竞态', () {
      expect(
        readerUiScaleReanchorAllowed(
          controllerAvailable: false,
          readerContentReady: true,
          lyricsMode: false,
          restoreInFlight: false,
          continuousMode: true,
        ),
        isFalse,
      );
    });

    test('多守卫同时不满足仍抑制', () {
      expect(
        readerUiScaleReanchorAllowed(
          controllerAvailable: false,
          readerContentReady: false,
          lyricsMode: true,
          restoreInFlight: true,
          continuousMode: false,
        ),
        isFalse,
      );
    });
  });

  group('JS 守卫：连续模式两阶段重锚原语 + _reanchorPending 串行契约', () {
    late String js;

    setUpAll(() {
      js = File('lib/src/reader/reader_pagination_scripts.dart')
          .readAsStringSync()
          .replaceAll('\r\n', '\n');
    });

    /// 切出 `beginUiScaleReanchor: function() { ... }` 函数体，避免误命中别处。
    String beginBody() {
      const String marker = 'beginUiScaleReanchor: function()';
      final int start = js.indexOf(marker);
      expect(start, greaterThanOrEqualTo(0),
          reason: '找不到 beginUiScaleReanchor 定义（连续模式重锚阶段1）');
      final int end = js.indexOf('\n  },', start);
      expect(end, greaterThan(start), reason: '找不到 beginUiScaleReanchor 体结尾');
      return js.substring(start, end);
    }

    String commitBody() {
      const String marker = 'commitUiScaleReanchor: function()';
      final int start = js.indexOf(marker);
      expect(start, greaterThanOrEqualTo(0),
          reason: '找不到 commitUiScaleReanchor 定义（连续模式重锚阶段2）');
      final int end = js.indexOf('\n  }', start);
      expect(end, greaterThan(start), reason: '找不到 commitUiScaleReanchor 体结尾');
      return js.substring(start, end);
    }

    test('阶段1 beginUiScaleReanchor 先置 _reanchorPending 再暂存锚', () {
      final String body = beginBody();
      // 已有重锚在飞则让既有序列接管，不重复采样。
      expect(body.contains('this._reanchorPending === true) return -1'), isTrue,
          reason: 'begin 必须在已有重锚在飞时返回 -1（让 setChromeInsets/updatePageSize '
              '等既有序列接管，不重复采样/不抢旗）');
      // 关键时序：采样首个可见字符 → 置旗 → 暂存锚。置旗必须发生（挡住 reflow 归零 scroll）。
      expect(body.contains('getFirstVisibleCharOffset()'), isTrue,
          reason: 'begin 必须用 getFirstVisibleCharOffset 采样精确锚');
      expect(body.contains('this._reanchorPending = true'), isTrue,
          reason: 'begin 必须置 _reanchorPending=true，否则 reflow 归零 scroll 会经 '
              'onReaderScroll 落库 progress≈0 弹回章首（TODO-693 根因）');
      expect(body.contains('this._uiScaleReanchorOffset = charOffset'), isTrue,
          reason: 'begin 必须暂存锚供 commit 阶段提交');
      // 时序：置旗在暂存之前/同段，且无可用锚时早返回不置旗。
      final int idxOffsetInvalid = body.indexOf('charOffset < 0) return -1');
      final int idxSetPending = body.indexOf('this._reanchorPending = true');
      expect(idxOffsetInvalid, greaterThanOrEqualTo(0),
          reason: '无可用锚（caretRangeFromPoint 失败）必须早返回 -1，不置旗');
      expect(idxOffsetInvalid, lessThan(idxSetPending),
          reason: '锚有效性检查必须在置旗之前，避免锚无效却把旗卡住');
    });

    test('阶段2 commitUiScaleReanchor 滚回锚并在 finally 清旗', () {
      final String body = commitBody();
      // 仅当 begin 成功暂存了有效锚才提交，否则 no-op（绝不误清别处的 _reanchorPending）。
      expect(
          body.contains('off === undefined || off < 0) return false'), isTrue,
          reason: 'commit 必须在无有效暂存锚时整体 no-op，绝不误清别处重锚旗');
      expect(body.contains('this.scrollToCharOffset(off)'), isTrue,
          reason: 'commit 必须把锚滚回视口首边（settle 后的真实位置）');
      // finally 清旗 + 清暂存，保证异常路径也不卡死 _reanchorPending（HBK-REG-004 同形）。
      expect(body.contains('finally'), isTrue,
          reason: 'commit 必须在 finally 清旗，异常路径也不能卡死 _reanchorPending');
      expect(body.contains('this._reanchorPending = false'), isTrue,
          reason: 'commit 必须清 _reanchorPending，否则后续滚动回传被永久挡住');
      expect(body.contains('this._uiScaleReanchorOffset = undefined'), isTrue,
          reason: 'commit 必须清暂存锚，避免下次缩放误用旧锚');
    });

    test('两阶段重锚只存在于连续模式 shell（分页 shell 无此原语）', () {
      // 分页模式有 snap/lock 保护，无需此重锚；原语应只出现在连续 shell。
      // 简化校验：beginUiScaleReanchor 在文件里只定义一次（连续 shell）。
      expect('beginUiScaleReanchor: function()'.allMatches(js).length, 1,
          reason: '两阶段重锚原语只应定义在连续模式 shell（分页模式无需）');
    });

    test('invocation builder 用 typeof 守卫使分页模式整体 no-op', () {
      expect(
        js.contains(
            "typeof window.hoshiReader.beginUiScaleReanchor === 'function'"),
        isTrue,
        reason: 'beginUiScaleReanchorInvocation 必须 typeof 守卫——分页 shell 缺此函数，'
            '误调时整体 no-op 返回 -1',
      );
      expect(
        js.contains(
            "typeof window.hoshiReader.commitUiScaleReanchor === 'function'"),
        isTrue,
        reason: 'commitUiScaleReanchorInvocation 必须 typeof 守卫',
      );
    });
  });

  group('Dart 守卫：ref.listen(appUiScale) 接线 + 两阶段先置旗后提交', () {
    late String src;

    setUpAll(() {
      src = readReaderPageSource();
    });

    test('build 用 ref.listen 监听 appUiScale 变化并调连续重锚', () {
      // 用 select 只监听 appUiScale 标量，避免 AppModel 任意字段变更都触发。
      expect(
        src.contains('appProvider.select((AppModel m) => m.appUiScale)'),
        isTrue,
        reason: '必须用 ref.listen + select 只监听 appUiScale 标量变化（TODO-693）',
      );
      expect(src.contains('_reanchorContinuousForUiScale()'), isTrue,
          reason: 'appUiScale 变化必须触发 _reanchorContinuousForUiScale 重锚');
    });

    test('_reanchorContinuousForUiScale 委托给 top-level 编排核心并绑入实例字段', () {
      // TODO-697：两阶段编排（门控→begin→intResult→postFrame→commit）已抽到 top-level
      // runUiScaleReanchorOrchestration（运行时序列由 *_runtime_test.dart 真执行锁定）。
      // 这里只静态守卫「方法把本 State 实例字段正确绑进编排回调」这层接线。
      final int idx =
          src.indexOf('Future<void> _reanchorContinuousForUiScale()');
      expect(idx, greaterThan(0), reason: '_reanchorContinuousForUiScale 必须存在');
      final String body = src.substring(idx, idx + 2000);
      expect(body.contains('runUiScaleReanchorOrchestration('), isTrue,
          reason: '方法必须委托给 top-level runUiScaleReanchorOrchestration（编排核心，'
              '运行时序列由 runtime 测试锁定）');
      // TODO-718：编排核心改由调用方注入门控结果（gateAllowed）。693 缩放重锚路径必须绑
      // readerUiScaleReanchorAllowed（含 !restoreInFlight 早返回）。
      expect(
          body.contains('gateAllowed: readerUiScaleReanchorAllowed('), isTrue,
          reason: '缩放重锚必须把 readerUiScaleReanchorAllowed 结果绑进 gateAllowed');
      // 门控的五个实例字段必须绑进 readerUiScaleReanchorAllowed（撤任一 → 对应抑制不再受控）。
      expect(body.contains('controllerAvailable: _controller != null'), isTrue,
          reason: '必须把控制器存活绑进门控');
      expect(
          body.contains('continuousMode: _settings?.isContinuousMode == true'),
          isTrue,
          reason: '必须把连续模式绑进门控（分页模式抑制的来源）');
      expect(body.contains('readerContentReady: _readerContentReady'), isTrue);
      expect(body.contains('lyricsMode: _lyricsMode'), isTrue);
      expect(body.contains('restoreInFlight: _restoreInFlight'), isTrue);
      // begin / commit 回调必须绑各自的 invocation；postFrame 必须经 addPostFrameCallback。
      final int idxBegin = body
          .indexOf('ReaderPaginationScripts.beginUiScaleReanchorInvocation()');
      final int idxCommit = body
          .indexOf('ReaderPaginationScripts.commitUiScaleReanchorInvocation()');
      expect(idxBegin, greaterThan(0),
          reason: 'evalBegin 回调必须绑 beginUiScaleReanchorInvocation（同步采锚+置旗）');
      expect(idxCommit, greaterThan(0),
          reason:
              'evalCommit 回调必须绑 commitUiScaleReanchorInvocation（settle 后滚回清旗）');
      expect(body.contains('addPostFrameCallback'), isTrue,
          reason:
              'schedulePostFrame 必须经 WidgetsBinding.addPostFrameCallback 等过渡帧 '
              'settle（box.size 是 FittedBox 逐帧过渡，沿用 _syncPageSize 的 settle 时机）');
    });

    test('top-level 编排 runUiScaleReanchorOrchestration 保留两阶段先后 + begin<0 早返回',
        () {
      // 编排核心的源码切片守卫：运行时序列已由 runtime 测试锁定，这里再静态确认
      // 「门控 → begin → intResult → charOffset<0 早返回 → postFrame → commit」骨架在源码里。
      final int idx =
          src.indexOf('Future<void> runUiScaleReanchorOrchestration(');
      expect(idx, greaterThan(0),
          reason: 'runUiScaleReanchorOrchestration top-level 编排核心必须存在');
      final String body = src.substring(idx, idx + 1600);
      expect(body.contains('if (!gateAllowed)'), isTrue,
          reason: '编排核心必须先过调用方注入的门控结果 gateAllowed（TODO-718：不再硬编码'
              '单一门控函数，缩放/恢复两路径各传自己的门控真值表）');
      final int idxBegin = body.indexOf('await evalBegin()');
      final int idxIntResult =
          body.indexOf('ReaderPaginationScripts.intResult(begin)');
      final int idxEarlyReturn = body.indexOf('if (charOffset < 0) return');
      final int idxPostFrame = body.indexOf('schedulePostFrame(');
      final int idxCommit = body.indexOf('await evalCommit()');
      expect(idxBegin, greaterThan(0),
          reason: '必须 await evalBegin（阶段1 同步采锚置旗）');
      expect(idxIntResult, greaterThan(idxBegin),
          reason: '必须在 begin 之后用 intResult 解析 JS 结果（含字符串 "-1"）');
      expect(idxEarlyReturn, greaterThan(idxIntResult),
          reason: 'begin<0（无锚/已有重锚在飞）必须早返回，跳过 postFrame/commit，不误清旗');
      expect(idxPostFrame, greaterThan(idxEarlyReturn),
          reason: 'postFrame 调度必须发生在 begin<0 早返回之后');
      expect(idxCommit, greaterThan(idxPostFrame),
          reason: 'commit 必须在 schedulePostFrame 回调内（settle 之后）');
    });
  });

  group('TODO-718 readerRestoreReanchorAllowed（恢复完成重锚门控真值表）', () {
    test('连续模式 + 全部就绪：触发重锚（恢复完成路径）', () {
      expect(
        readerRestoreReanchorAllowed(
          controllerAvailable: true,
          readerContentReady: true,
          lyricsMode: false,
          continuousMode: true,
        ),
        isTrue,
      );
    });

    test('分页模式（continuousMode==false）抑制——分页有 snap/lock 保护', () {
      expect(
        readerRestoreReanchorAllowed(
          controllerAvailable: true,
          readerContentReady: true,
          lyricsMode: false,
          continuousMode: false,
        ),
        isFalse,
        reason: '分页 registerSnapScroll/lockRootViewport 已挡归零，恢复路径同样无需重锚',
      );
    });

    test('歌词模式（lyricsMode）抑制——非正文阅读无章内 scrollY 语义', () {
      expect(
        readerRestoreReanchorAllowed(
          controllerAvailable: true,
          readerContentReady: true,
          lyricsMode: true,
          continuousMode: true,
        ),
        isFalse,
      );
    });

    test('内容未就绪（!readerContentReady）抑制——锚还算不出', () {
      expect(
        readerRestoreReanchorAllowed(
          controllerAvailable: true,
          readerContentReady: false,
          lyricsMode: false,
          continuousMode: true,
        ),
        isFalse,
      );
    });

    test('控制器已释放（!controllerAvailable）抑制——dispose 竞态', () {
      expect(
        readerRestoreReanchorAllowed(
          controllerAvailable: false,
          readerContentReady: true,
          lyricsMode: false,
          continuousMode: true,
        ),
        isFalse,
      );
    });

    test(
        '门控不含 restoreInFlight 参数——恢复完成路径下 _restoreInFlight 必为 false，'
        '复用含早返回的 readerUiScaleReanchorAllowed 会误抑制（要求②）', () {
      // 反向锁定：本门控签名故意没有 restoreInFlight。若有人把它合并回
      // readerUiScaleReanchorAllowed（带 !restoreInFlight），_onRestoreComplete 调用点的
      // 时序就会脆弱化。纯函数全就绪即放行，不依赖任何恢复期标志。
      expect(
        readerRestoreReanchorAllowed(
          controllerAvailable: true,
          readerContentReady: true,
          lyricsMode: false,
          continuousMode: true,
        ),
        isTrue,
        reason: '恢复完成门控不应被任何 restoreInFlight 语义牵制',
      );
    });
  });

  group('TODO-718 Dart 守卫：_onRestoreComplete 归零前采锚 + 恢复重锚接线', () {
    late String src;

    setUpAll(() {
      src = readReaderPageSource();
    });

    test(
        '_onRestoreComplete 在 _restoreInFlight=false 之后、_refreshProgress() 之前采锚',
        () {
      // 要求①③：采锚必须在 reflow 归零前。归零发生在恢复完成后的 settle 帧，
      // _refreshProgress() 会把（被归零冲掉的）progress 落库——故采锚+置旗必须在它之前，
      // 置旗后 webview 守卫挡住归零 scroll 不回传，_refreshProgress 读到恢复后正确位置。
      final int idxRestoreFalse = src.indexOf('_restoreInFlight = false;');
      final int idxReanchor = src.indexOf('_reanchorContinuousAfterRestore();');
      // _onRestoreComplete 里最后一处 _refreshProgress(); 调用（恢复完成收尾）。
      final int idxStartPoll = src.indexOf('_startProgressPoll();');
      expect(idxRestoreFalse, greaterThan(0),
          reason: '_onRestoreComplete 必须先把 _restoreInFlight 置 false');
      expect(idxReanchor, greaterThan(idxRestoreFalse),
          reason: '恢复重锚必须在 _restoreInFlight=false 之后（_onRestoreComplete 内）');
      // 采锚必须在 _startProgressPoll 之前的那段收尾（紧邻 _refreshProgress 之前）。
      expect(idxReanchor, lessThan(idxStartPoll),
          reason: '采锚必须在恢复完成收尾的 _refreshProgress()/_startProgressPoll() 之前，'
              '否则归零会先污染落库（要求①③：采锚在归零前）');
      // 同段内 _refreshProgress() 必须出现在采锚之后。
      final String afterReanchor = src.substring(idxReanchor, idxStartPoll);
      expect(afterReanchor.contains('_refreshProgress();'), isTrue,
          reason: '采锚之后才轮到 _refreshProgress()（置旗已挡住归零，读到正确位置）');
    });

    test('_reanchorContinuousAfterRestore 委托编排核心并绑恢复完成门控', () {
      final int idx =
          src.indexOf('Future<void> _reanchorContinuousAfterRestore()');
      expect(idx, greaterThan(0),
          reason: '_reanchorContinuousAfterRestore 必须存在（TODO-718）');
      final String body = src.substring(idx, idx + 2000);
      expect(body.contains('runUiScaleReanchorOrchestration('), isTrue,
          reason: '恢复重锚必须复用 top-level 编排核心（同 693 两阶段序列）');
      // 要求②：必须绑恢复完成专用门控 readerRestoreReanchorAllowed（不含 restoreInFlight 早返回），
      // 绝不复用 readerUiScaleReanchorAllowed。
      expect(
          body.contains('gateAllowed: readerRestoreReanchorAllowed('), isTrue,
          reason: '恢复重锚必须绑 readerRestoreReanchorAllowed（避开会早返回的门控，要求②）');
      expect(body.contains('readerUiScaleReanchorAllowed('), isFalse,
          reason:
              '恢复重锚不得复用含 !restoreInFlight 早返回的 readerUiScaleReanchorAllowed');
      // 门控不绑 restoreInFlight（恢复完成路径下必为 false）。
      expect(body.contains('restoreInFlight:'), isFalse,
          reason: '恢复重锚门控不应再绑 restoreInFlight');
      // 复用同一两阶段 begin/commit invocation（与 _reanchorPending 串行旗一致）。
      final int idxBegin = body
          .indexOf('ReaderPaginationScripts.beginUiScaleReanchorInvocation()');
      final int idxCommit = body
          .indexOf('ReaderPaginationScripts.commitUiScaleReanchorInvocation()');
      expect(idxBegin, greaterThan(0),
          reason: 'evalBegin 必须绑 beginUiScaleReanchorInvocation（归零前采锚+置旗）');
      expect(idxCommit, greaterThan(0),
          reason:
              'evalCommit 必须绑 commitUiScaleReanchorInvocation（settle 后滚回清旗）');
      expect(body.contains('addPostFrameCallback'), isTrue,
          reason: 'schedulePostFrame 必须经 addPostFrameCallback 等 settle 时机');
      expect(
          body.contains('continuousMode: _settings?.isContinuousMode == true'),
          isTrue,
          reason: '必须把连续模式绑进门控（分页抑制来源）');
    });
  });
}
