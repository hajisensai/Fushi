import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/reader_hibiki_page.dart'
    show readerUiScaleReanchorAllowed;

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

    test('_reanchorContinuousForUiScale 门控走纯函数 readerUiScaleReanchorAllowed',
        () {
      final int idx =
          src.indexOf('Future<void> _reanchorContinuousForUiScale()');
      expect(idx, greaterThan(0), reason: '_reanchorContinuousForUiScale 必须存在');
      final String body = src.substring(idx, idx + 2000);
      expect(body.contains('readerUiScaleReanchorAllowed('), isTrue,
          reason: '门控必须走纯函数 readerUiScaleReanchorAllowed（含分页模式抑制）');
      // 阶段1：先置旗 begin → 取锚 → 阶段2：postFrame settle 后 commit。
      final int idxBegin = body
          .indexOf('ReaderPaginationScripts.beginUiScaleReanchorInvocation()');
      final int idxPostFrame = body.indexOf('addPostFrameCallback');
      final int idxCommit = body
          .indexOf('ReaderPaginationScripts.commitUiScaleReanchorInvocation()');
      expect(idxBegin, greaterThan(0),
          reason: '阶段1 必须先调 beginUiScaleReanchorInvocation（同步采锚+置旗）');
      expect(idxPostFrame, greaterThan(idxBegin),
          reason: 'commit 必须在 addPostFrameCallback 里等过渡帧 settle '
              '（box.size 是 FittedBox 逐帧过渡，沿用 _syncPageSize 的 settle 时机）');
      expect(idxCommit, greaterThan(idxPostFrame),
          reason: '阶段2 commit 必须发生在 postFrame settle 之后');
    });

    test('begin 返回 -1（无锚/已有重锚在飞）时不提交，不误清旗', () {
      final int idx =
          src.indexOf('Future<void> _reanchorContinuousForUiScale()');
      final String body = src.substring(idx, idx + 2000);
      expect(body.contains('if (charOffset < 0) return'), isTrue,
          reason: 'begin 返回 -1 时必须跳过提交阶段，旗由对应入口 finally 清，不在此误清');
    });
  });
}
