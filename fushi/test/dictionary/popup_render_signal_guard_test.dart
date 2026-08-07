import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-712 P5 三镜像源码守卫：多词条查词弹窗 popupRendered 的「早发 + 双发」协议。
///
/// 性能背景：多词条结果此前要等**全部**词条 build 完才发 popupRendered，宿主的
/// 撤盖板/翻可见被尾批词条拖住。P5 改为：
///   ① 首词条同步渲染完（build + 局部 ruby + applyCustomCSS）后，先写仅含首条的
///      临时 counts/domIndex 视图，随即 `_firePopupRendered(true)` 早发一次，
///      宿主立即可见（首屏可见性只依赖首词条）；
///   ② 尾批词条在 setTimeout(..., 0) 宏任务里补建完成后第二次 `_firePopupRendered()`
///      收尾（Windows global-lookup host 依赖第二发把窗口量到全部词条的真实高度）；
///   ③ 早发→尾批完成的窗口内 counts/domIndex 是临时值，updatePopupIncremental 的
///      增量 diff 不可靠（会把尾批在建的词条当新增追加成重复卡片），必须检查
///      `_renderInProgress` 并回退全量 renderPopup（换代自动取消 pending 尾批）；
///   ④ `function _firePopupRendered(stillRendering)` 签名承载 ③ 的置位来源。
///
/// popup.js 有三份镜像（in-app 弹窗 + 两份浏览器扩展 vendor 副本；byte-parity 由
/// browser_extension_popup_parity_guard 另锁），本守卫在三份上各自断言语义约束，
/// 防止任何一份单独回退。flutter test cwd 是 hibiki 包根。
void main() {
  const Map<String, String> jsMirrors = <String, String>{
    'in-app popup': 'assets/popup/popup.js',
    'extension vendor (assets)': 'assets/browser_extension/vendor/popup.js',
    'extension vendor (tools)': '../tools/browser-extension/vendor/popup.js',
  };

  jsMirrors.forEach((String name, String relPath) {
    group('[$name] popupRendered 早发/双发协议 (BUG-712 P5)', () {
      late final String js;
      setUpAll(() => js = File(relPath).readAsStringSync());

      test('④ _firePopupRendered(stillRendering) 签名 + _renderInProgress 置位',
          () {
        // 守的回归：签名被改掉 / stillRendering 参数被删 → 早发 true 无处置位，
        // ③ 的回退守卫失去数据来源，整个窗口保护随之瓦解。
        expect(
          js.contains('function _firePopupRendered(stillRendering)'),
          isTrue,
          reason: '_firePopupRendered 必须保留 stillRendering 参数签名',
        );
        expect(
          js.contains('window._renderInProgress = !!stillRendering;'),
          isTrue,
          reason: '每次发信号都必须同步置 _renderInProgress（true=尾批在途，'
              '无参调用落回 false）',
        );
      });

      test(
          '① 多词条早发：临时首条视图写入后、尾批 setTimeout 之前 '
          '_firePopupRendered(true)', () {
        // 守的回归：早发被删（回到「全部词条 build 完才发」）→ 多词条查词的
        // 可见时刻重新被尾批拖住，BUG-712 P5 的首屏时延优化整体失效。
        final int idxEarly = js.indexOf('_firePopupRendered(true)');
        expect(idxEarly, greaterThan(-1),
            reason: '多词条路径必须保留首词条完成后的早发 _firePopupRendered(true)');

        // 守的回归：早发必须发生在「仅含首条的临时 domIndex 视图」写入之后——
        // 否则早发后的窗口内 DOM 与 counts/domIndex 不一致，增量路径（及 ③ 的
        // 回退判定所依赖的状态）失去依据。
        // `[entryDomIndex[0]]` 这一临时单元素写法全文件唯一，定位可靠。
        final int idxTempDom =
            js.indexOf('window._entryDomIndex = [entryDomIndex[0]]');
        expect(idxTempDom, greaterThan(-1),
            reason: '早发前必须写入仅含首词条的临时 _entryDomIndex 视图');
        expect(idxTempDom, lessThan(idxEarly),
            reason: '临时首条视图写入必须先于早发（顺序不可颠倒）');

        // 守的回归：早发不替代尾批渲染——早发之后必须仍存在尾批 setTimeout。
        final int idxTail = js.indexOf('setTimeout', idxEarly);
        expect(idxTail, greaterThan(idxEarly),
            reason: '_firePopupRendered(true) 之后必须仍有尾批 setTimeout '
                '（早发只提前可见时刻，剩余词条仍要在宏任务里补建）');
      });

      test('② 尾批回调内保留第二次 _firePopupRendered()（双发收尾）', () {
        final int idxEarly = js.indexOf('_firePopupRendered(true)');
        expect(idxEarly, greaterThan(-1));
        final int idxTail = js.indexOf('setTimeout', idxEarly);
        expect(idxTail, greaterThan(idxEarly));
        final int idxTailEnd = js.indexOf('}, 0);', idxTail);
        expect(idxTailEnd, greaterThan(idxTail),
            reason: '尾批必须是 setTimeout(..., 0) 宏任务');

        // 守的回归：第二发被删 → Windows global-lookup host（依赖第二发把窗口
        // 量到全部词条的真实高度）窗口永远停在首条高度；且 _renderInProgress
        // 停在 true，updatePopupIncremental 永远走全量回退。
        final String tailBody = js.substring(idxTail, idxTailEnd);
        expect(tailBody.contains('_firePopupRendered()'), isTrue,
            reason: '尾批回调内必须保留第二次无参 _firePopupRendered()（同 token '
                '双发；无参调用同时把 _renderInProgress 落回 false）');
      });

      test('③ updatePopupIncremental 开头必须有 _renderInProgress 回退全量守卫', () {
        final int idxUpd =
            js.indexOf('window.updatePopupIncremental = function()');
        expect(idxUpd, greaterThan(-1), reason: 'updatePopupIncremental 入口丢失');

        // 守的回归：守卫被删 → 早发窗口内 counts/domIndex 是仅含首条的临时值，
        // 增量 diff 会把尾批在建的词条当「新增」追加成重复卡片。必须回退全量
        // renderPopup（其 _renderGeneration 换代自动取消 pending 尾批）。
        final RegExp guard = RegExp(r'if \(window\._renderInProgress\)\s*\{\s*'
            r'window\.renderPopup\(\);\s*return;');
        final Match? m = guard.firstMatch(js.substring(idxUpd));
        expect(m, isNotNull,
            reason: 'updatePopupIncremental 缺「_renderInProgress → 全量 '
                'renderPopup + return」回退守卫');

        // 守的回归：守卫必须先于任何基于 _renderedGlossaryCounts 的增量 diff——
        // 挪到读 counts 之后就等于没守。
        final int idxCounts = js.indexOf('_renderedGlossaryCounts', idxUpd);
        expect(idxCounts, greaterThan(-1));
        expect(idxUpd + m!.start, lessThan(idxCounts),
            reason: '回退守卫必须出现在读取 _renderedGlossaryCounts 之前');
      });
    });
  });
}
