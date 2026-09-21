import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';

/// 悬停查词的收尾：鼠标离开字幕与查词浮层 ⇒ 自动关浮层 + 恢复播放（用户诉求：悬停查完
/// 词把鼠标移开就该继续播，不用再点一下空白）。
///
/// 两层守：
/// ① 判据纯函数 [VideoFushiPage.shouldAutoResumeOnHoverLeave] 的真值表——每条门控单独翻
///    一次，确认它各自都能独立否决（避免某条门控被后来的重构写成恒真而无人察觉）。
/// ② 源码接线守卫——判据再对，没接到 barrier hover / 浮层 MouseRegion / 关栈汇聚点上也
///    不会发生任何事。这几处接线没有单测能在 widget 层跑到（需要真 media_kit 播放器 +
///    真 WebView 浮层 + 真 OS hover），故按源码文本钉死，改动时必须连同本文件一起想清楚。
void main() {
  group('shouldAutoResumeOnHoverLeave 真值表', () {
    // 基线：悬停发起的会话、浮层可见、指针既不在浮层上也不在字幕上、光标会话没接管。
    bool call({
      bool enabled = true,
      bool openedByHover = true,
      bool hasVisiblePopup = true,
      bool pointerOverPopup = false,
      bool overSubtitle = false,
      bool caretHoldsPause = false,
      bool hiddenByDialog = false,
    }) =>
        VideoFushiPage.shouldAutoResumeOnHoverLeave(
          enabled: enabled,
          openedByHover: openedByHover,
          hasVisiblePopup: hasVisiblePopup,
          pointerOverPopup: pointerOverPopup,
          overSubtitle: overSubtitle,
          caretHoldsPause: caretHoldsPause,
          hiddenByDialog: hiddenByDialog,
        );

    test('全部条件成立 ⇒ 关栈续播', () {
      expect(call(), isTrue);
    });

    test('偏好关掉 ⇒ 保持既有行为（要再点一下才播）', () {
      expect(call(enabled: false), isFalse);
    });

    test('点击发起的查词会话 ⇒ 鼠标移开不关（BUG-072 既有行为不变）', () {
      expect(call(openedByHover: false), isFalse);
    });

    test('已无可见浮层 ⇒ 无事可做（只剩隐藏热槽时会话早已结束）', () {
      expect(call(hasVisiblePopup: false), isFalse);
    });

    test('指针停在查词浮层上 ⇒ 用户正在读词条，绝不关', () {
      expect(call(pointerOverPopup: true), isFalse);
    });

    test('指针仍在字幕字符上 ⇒ 那是换词不是离开', () {
      expect(call(overSubtitle: true), isFalse);
    });

    test('字级选词光标会话激活 ⇒ 暂停由它接管，不替它决定续播', () {
      expect(call(caretHoldsPause: true), isFalse);
    });

    test('对话框期（制卡 / 选句上下文 / 打开卡片）⇒ 不关栈', () {
      // BUG-797/1040/1327 同族：这些对话框把浮层**停靠到屏外**，浮层那层 MouseRegion
      // 随之离开指针并报 exit，而 hasVisiblePopup 看的是 controller 级 visible、仍为
      // true。不挡这条，用户点「制卡」后 320ms 就会被整栈关掉：草稿清空、视频在对话框
      // 背后播起来。
      expect(call(hiddenByDialog: true), isFalse);
    });

    test('意图确认窗口是正数且不至于长到让人以为卡住', () {
      expect(
        VideoFushiPage.hoverLeaveResumeGrace.inMilliseconds,
        greaterThan(0),
      );
      expect(
        VideoFushiPage.hoverLeaveResumeGrace.inMilliseconds,
        lessThanOrEqualTo(600),
      );
    });

    test('离开判定的节流阈值与换词那条分开记账，且更灵敏', () {
      expect(VideoFushiPage.hoverLeaveThresholdPx, greaterThan(0));
      expect(
        VideoFushiPage.hoverLeaveThresholdPx,
        lessThan(VideoFushiPage.barrierHoverThresholdPx),
      );
    });
  });

  group('接线守卫（源码文本）', () {
    late final String pageSource = File(
      'lib/src/pages/implementations/video_fushi_page.dart',
    ).readAsStringSync();

    test('barrier hover 在 Shift 门控**之前**先做离开判定', () {
      // 顺序是本功能的正确性前提：Shift-悬停开的会话，用户松开 Shift 再移开鼠标是最
      // 自然的「看完了」动作，而那之后的 hover 事件会被 Shift 早退整段吞掉。
      final int evaluateAt = pageSource.indexOf(
        '_evaluateHoverLeave(event.position)',
      );
      final int shiftGateAt = pageSource.indexOf(
        'if (!HardwareKeyboard.instance.isShiftPressed &&',
      );
      expect(evaluateAt, greaterThan(0), reason: 'barrier hover 未接离开判定');
      expect(shiftGateAt, greaterThan(0));
      expect(
        evaluateAt,
        lessThan(shiftGateAt),
        reason: '离开判定被排到 Shift 早退之后 = 松开 Shift 后永不触发',
      );
    });

    test('悬停入口带 fromHover: true，点击入口默认 false', () {
      expect(pageSource, contains('fromHover: true'));
      expect(pageSource, contains('bool fromHover = false'));
      expect(pageSource, contains('_lookupOpenedByHover = fromHover'));
    });

    test('浮层层外包 MouseRegion 回报指针进出（opaque: false 不改命中语义）', () {
      expect(pageSource, contains('_setPointerOverLookupPopup(true)'));
      expect(pageSource, contains('_setPointerOverLookupPopup(false)'));
      expect(pageSource, contains('opaque: false'));
    });

    test('自动关走既有关栈汇聚点，不另起一套恢复逻辑', () {
      // _popNestedPopupAt(0) 里已经含恢复播放 / 清制卡草稿 / 收回焦点全套；另写一份
      // play() 会立刻和 BUG-072 的单一恢复真相源打架。
      final int fireAt = pageSource.indexOf('void _fireHoverLeaveResume()');
      expect(fireAt, greaterThan(0));
      final String fireBody = pageSource.substring(fireAt, fireAt + 1400);
      expect(fireBody, contains('_popNestedPopupAt(0)'));
      expect(
        fireBody.contains('_controller?.play()'),
        isFalse,
        reason: '恢复播放必须继续由关栈汇聚点统一负责',
      );
    });

    test('指针移出整个窗口也会起表（全屏 barrier 的 MouseRegion exit）', () {
      // barrier 铺满全屏 ⇒ 它的 exit 只可能是指针离开窗口。那之后 barrier 一个 hover
      // 事件都不会再来，不自己起表就会卡在暂停等不到人。
      expect(pageSource, contains('_handlePointerLeftLookupSurface()'));
      expect(pageSource, contains('void _handlePointerLeftLookupSurface()'));
    });

    test('字幕列表侧栏的 hover 换词同样算悬停会话', () {
      // barrier 的列表 hover 分支若不标来源，「侧栏悬停查词 → 移开鼠标」永远不会续播。
      final int hoverAt = pageSource.indexOf(
        'void _onDismissBarrierHover(PointerHoverEvent event)',
      );
      expect(hoverAt, greaterThan(0));
      final int hoverEnd = pageSource.indexOf(
        'void _handleSubtitleHoverLookup(',
        hoverAt,
      );
      expect(hoverEnd, greaterThan(hoverAt));
      final String hoverBody = pageSource.substring(hoverAt, hoverEnd);
      expect(hoverBody, contains('_handleSubtitleListLookup('));
      expect(hoverBody, contains('fromHover: true'));
    });

    test('Shift 在静止指针处查词（BUG-880）两条分支都算悬停会话', () {
      final int shiftAt = pageSource.indexOf(
        'void _triggerShiftLookupAtLastPointer()',
      );
      expect(shiftAt, greaterThan(0));
      final String shiftBody = pageSource.substring(shiftAt, shiftAt + 1400);
      // 画面字幕那条走悬停去重入口（入口内部已标 fromHover: true），列表那条显式标。
      expect(shiftBody, contains('_handleSubtitleHoverLookup('));
      expect(shiftBody, contains('fromHover: true'));
    });

    test('关栈收尾复位会话状态，不跨到下一次查词', () {
      expect(pageSource, contains('_lookupOpenedByHover = false'));
      expect(pageSource, contains('_pointerOverLookupPopup = false'));
    });

    test('dispose 收掉意图确认表', () {
      final int disposeAt = pageSource.indexOf('  void dispose() {');
      expect(disposeAt, greaterThan(0));
      final String disposeBody = pageSource.substring(
        disposeAt,
        disposeAt + 3000,
      );
      expect(
        disposeBody,
        contains('_cancelHoverLeaveResume()'),
        reason: '表活过本页 ⇒ 在已 dispose 的 State 上 setState',
      );
    });
  });

  group('浮层 hover 探针的挂载层级（release 下会崩的那一类）', () {
    final String pageSource = File(
      'lib/src/pages/implementations/video_fushi_page.dart',
    ).readAsStringSync();
    final String mixinSource = File(
      'lib/src/pages/implementations/dictionary_page_mixin.dart',
    ).readAsStringSync();

    test('hover 探针经 wrapContent 挂在 Positioned 内部，不套在层外', () {
      // buildNestedPopupLayer 返回的是 parkedPopupLayer 的 Positioned（BUG-135 屏外
      // 停靠靠它的 left/top）。Positioned 是 ParentDataWidget<StackParentData>，与
      // Stack 之间只能隔 Stateless/Stateful widget；在**外面**套 MouseRegion
      // （SingleChildRenderObjectWidget）会让 ParentData 落不到 Stack 上：debug 抛
      // `Incorrect use of ParentDataWidget`、浮层退化成非定位子项画到左上角（热槽
      // 屏外停靠一并失效），release 下 `parentData! as StackParentData` 直接 TypeError。
      expect(
        pageSource,
        contains('wrapContent: _wrapPopupHoverProbe'),
        reason: 'hover 探针必须经 mixin 的 wrapContent 注入到 Positioned 内部',
      );
      final int probeAt = pageSource.indexOf('Widget _wrapPopupHoverProbe(');
      expect(probeAt, greaterThanOrEqualTo(0));
      expect(
        pageSource.substring(probeAt, probeAt + 400),
        contains('MouseRegion('),
      );
      // 反向：层构造函数自己的函数体里不得再套 MouseRegion（那就又回到层外了）。
      final int buildAt =
          pageSource.indexOf('Widget _buildNestedPopupLayer(int');
      expect(buildAt, greaterThanOrEqualTo(0));
      expect(
        pageSource.substring(buildAt, pageSource.indexOf(';', buildAt)),
        isNot(contains('MouseRegion(')),
      );
    });

    test('mixin 的 wrapContent 只作用在 parkedPopupLayer 的 child 上', () {
      expect(
          mixinSource, contains('Widget Function(Widget child)? wrapContent'));
      final int parkedAt = mixinSource.indexOf('return parkedPopupLayer(');
      expect(parkedAt, greaterThanOrEqualTo(0));
      final String layer = mixinSource.substring(parkedAt, parkedAt + 1200);
      expect(
        layer.replaceAll(RegExp(r'\s+'), ''),
        contains('child:_wrapPopupContent(wrapContent'),
        reason: '包装落在 child: 上，顶层仍是 Positioned',
      );
      expect(
        mixinSource.substring(0, parkedAt),
        isNot(contains('wrapContent(parkedPopupLayer')),
        reason: '绝不能反过来把 Positioned 包进去',
      );
    });

    test('到期复核把对话框期一并传进判据', () {
      final int fireAt = pageSource.indexOf('void _fireHoverLeaveResume()');
      expect(fireAt, greaterThanOrEqualTo(0));
      final int end = pageSource.indexOf('\n  }', fireAt);
      expect(
        pageSource.substring(fireAt, end),
        contains('hiddenByDialog: lookupPopupHiddenByDialog'),
      );
    });
  });
}
