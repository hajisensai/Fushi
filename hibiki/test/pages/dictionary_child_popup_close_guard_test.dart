import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/video_hibiki_page.dart';

/// TODO-501 guard: when swipe-to-close is disabled, nested dictionary popups
/// still need a visible, focusable X that pops only the current layer.
void main() {
  String read(String path) => File(path).readAsStringSync();

  test('shared popup layer sizes action affordances consistently', () {
    final String layer =
        read('lib/src/pages/implementations/dictionary_popup_layer.dart');

    expect(layer, contains('final VoidCallback? onBack;'));
    expect(layer, contains('Icons.close'));
    expect(layer, contains('BoxConstraints.tightFor(width: 36, height: 36)'));
    expect(layer, contains('size: 20'));
    expect(layer, contains('onTap: onBack'));
    expect(layer, contains('onTap: onClose'));
  });

  test('reader host routes nested layers through right-side close', () {
    final String base = read('lib/src/pages/base_source_page.dart');

    expect(base, contains('onClose: () => _dismissPopupAt(index)'));
    expect(base, contains('onBack: null'));
  });

  test('mixin hosts route nested layers through right-side close', () {
    final String mixin =
        read('lib/src/pages/implementations/dictionary_page_mixin.dart');

    expect(mixin, contains('onClose: () => onPop(index)'));
    expect(mixin, contains('onBack: null'));
  });

  test('standalone popup keeps search close for base and X-pops child layers',
      () {
    final String popup =
        read('lib/src/pages/implementations/popup_dictionary_page.dart');

    expect(popup, contains('onClose: isBase ? null : () => _popAt(index)'));
    expect(popup, contains('onBack: null'));
    expect(popup, contains('swipeDismissible: !isBase'));
  });

  test('swipe dismiss keeps host layer routing separate from onBack', () {
    final String base = read('lib/src/pages/base_source_page.dart');
    final String mixin =
        read('lib/src/pages/implementations/dictionary_page_mixin.dart');
    final String popup =
        read('lib/src/pages/implementations/popup_dictionary_page.dart');

    expect(base, contains('onDismiss: () => _dismissPopupAt(index)'));
    expect(base, contains('onClose: () => _dismissPopupAt(index)'));

    expect(mixin, contains('onDismiss: () => onPop(index)'));
    expect(mixin, contains('onClose: () => onPop(index)'));

    expect(popup, contains('onDismiss: isBase ? _close : () => _popAt(index)'));
    expect(popup, contains('onClose: isBase ? null : () => _popAt(index)'));
  });

  // TODO-834（反转 TODO-720 / BUG-403）：区分两种「点外」——
  //  (A) 点**所有弹窗矩形外**的真空白（全屏 barrier onTap）= 清整栈（会话收尾）。
  //  (B) 点**某层弹窗本体的空白区**（弹窗 onTapOutside）= 只关该层衍生的后代层、
  //      保留本层 + 祖先（点顶层无后代 = no-op）。
  // barrier 必须走清整栈路径；onTapOutside 必须带本层 index 走 truncateTo 关后代，
  // 不能再写死 dismissTopPopup / lastVisibleIndex / index 0。
  test('reader barrier clears the whole stack; onTapOutside closes descendants',
      () {
    final String base = read('lib/src/pages/base_source_page.dart');

    // (A) barrier 全屏 onTap = 清整栈（会话级路径，触发 onAllPopupsDismissed + 留热槽）。
    expect(base, contains('onTap: clearDictionaryResult'),
        reason: 'barrier 点所有弹窗外清整栈');
    // (B) 弹窗本体 onTapOutside = 关本层后代（带本层 index）。
    expect(base, contains('onTapOutside: () => dismissDescendantsOf(index)'),
        reason: '点某层本体空白只关其后代');
    // 不再用逐层关一层的 dismissTopPopup 接「点外」。
    expect(base, isNot(contains('onTap: dismissTopPopup')),
        reason: 'barrier 不再逐层关一层（改清整栈）');
    expect(base, isNot(contains('onTapOutside: dismissTopPopup')),
        reason: 'onTapOutside 不再逐层关一层（改关后代）');
    // 关后代原语本体：truncateTo(index+1)，无后代时 no-op。
    expect(base, contains('void dismissDescendantsOf(int index)'),
        reason: '关后代 helper 存在');
    expect(base, contains('_popup.truncateTo(index + 1);'),
        reason: '关后代用 truncateTo(index+1) 精确裁后代');
    expect(
        base,
        contains(
            'if (index < 0 || index >= _popup.entries.length - 1) return;'),
        reason: '点顶层（无后代）no-op 栈不变');
    expect(base, contains('onDictionaryStackChanged();'),
        reason: '关后代后调一次让光标跟随新顶层');
  });

  test('video barrier clears the whole stack (descendants + parents)', () {
    final String video =
        read('lib/src/pages/implementations/video_hibiki_page.dart');

    // 点所有弹窗外清整栈（保留热槽 + 会话收尾恢复播放/清草稿/收回焦点）。
    // 取 _onDismissBarrierTap 方法体（到下一个方法 _handleSubtitleLookupTap 之前），
    // 精确断言 barrier 分支清整栈，且不串到 back/Esc 逐层退回的 _handleBackOrExit。
    final int barrierStart = video.indexOf('void _onDismissBarrierTap(');
    expect(barrierStart, greaterThanOrEqualTo(0), reason: 'barrier 方法存在');
    final int barrierEnd =
        video.indexOf('void _handleSubtitleLookupTap(', barrierStart);
    expect(barrierEnd, greaterThan(barrierStart));
    final String barrierBody = video.substring(barrierStart, barrierEnd);

    expect(barrierBody, contains('_popNestedPopupAt(0);'),
        reason: 'barrier 点所有弹窗外清整栈到 index 0');
    expect(barrierBody,
        isNot(contains('_popNestedPopupAt(_topVisiblePopupIndex)')),
        reason: 'barrier 不再逐层关一层（改清整栈）');
    // TODO-758 / BUG-410 字幕反查门控仍在（点字幕换词只在非嵌套态）。
    expect(
        barrierBody, contains('VideoHibikiPage.shouldSwitchWordOnBarrierTap('),
        reason: '字幕反查门控保持不变');
    // 红线：back/Esc 逐层退回（_handleBackOrExit）保持不变，仍逐层关一层。
    expect(video, contains('Future<void> _handleBackOrExit()'),
        reason: 'back/Esc 退出汇聚点仍在');
    final int backStart = video.indexOf('Future<void> _handleBackOrExit()');
    final String backBody = video.substring(backStart, backStart + 220);
    expect(backBody, contains('_popNestedPopupAt(_topVisiblePopupIndex);'),
        reason: 'back/Esc 仍逐层退回（不受 TODO-834 barrier 改动影响）');
  });

  test('mixin onTapOutside closes descendants of the tapped layer', () {
    final String mixin =
        read('lib/src/pages/implementations/dictionary_page_mixin.dart');

    expect(
        mixin,
        contains(
            'onTapOutside: () => _dismissDescendantsOfLayer(index, controller)'),
        reason: '点本层本体空白只关其后代');
    expect(mixin, isNot(contains('onTapOutside: () => onPop(0)')),
        reason: '不再写死 index 0 清整栈');
    expect(
        mixin,
        isNot(
            contains('onTapOutside: () => onPop(controller.lastVisibleIndex)')),
        reason: '不再逐层关一层（改关后代）');
    // 关后代原语本体：truncateTo(index+1)，无后代时 no-op。
    expect(
        mixin,
        contains(
            'void _dismissDescendantsOfLayer(\n    int index,\n    DictionaryPopupController controller,\n  )'),
        reason: '关后代 helper 存在');
    expect(mixin, contains('controller.truncateTo(index + 1)'),
        reason: '关后代用 truncateTo(index+1) 精确裁后代');
    expect(
        mixin,
        contains(
            'if (index < 0 || index >= controller.entries.length - 1) return;'),
        reason: '点顶层（无后代）no-op 栈不变');
  });

  // TODO-758 / BUG-410: 视频嵌套查词时点弹窗外面常落在底部仍渲染的字幕文字上，barrier
  // 无条件反查字幕命中 → _lookupAt(replaceStack) 把整栈替换（顶层窗没关而是被换成新词）。
  // 「点字幕换词」只在非嵌套（topVisibleIndex<=0）才合理；嵌套态一律逐层关一层。
  group('barrier subtitle-tap is gated to non-nested (BUG-410)', () {
    test('nested stack never switches word even when a subtitle char is hit',
        () {
      // index 0 父词 + index 1 子词，点外落在字幕上：必须逐层关，不换词。
      expect(
        VideoHibikiPage.shouldSwitchWordOnBarrierTap(
          topVisibleIndex: 1,
          hitSubtitle: true,
        ),
        isFalse,
        reason: '嵌套态点字幕也不换词（否则整栈被 replaceStack）',
      );
      expect(
        VideoHibikiPage.shouldSwitchWordOnBarrierTap(
          topVisibleIndex: 2,
          hitSubtitle: true,
        ),
        isFalse,
      );
    });

    test('single visible layer keeps tap-subtitle-to-switch-word', () {
      // 单层查词点同句另一个字符切换查词是合理交互，保留。
      expect(
        VideoHibikiPage.shouldSwitchWordOnBarrierTap(
          topVisibleIndex: 0,
          hitSubtitle: true,
        ),
        isTrue,
        reason: '单层（仅顶层可见）保留点字幕换词',
      );
    });

    test('hitting blank (no subtitle char) never switches word', () {
      for (final int top in <int>[-1, 0, 1, 2]) {
        expect(
          VideoHibikiPage.shouldSwitchWordOnBarrierTap(
            topVisibleIndex: top,
            hitSubtitle: false,
          ),
          isFalse,
          reason: '点空白/控件区任意层都逐层关，不换词 (top=$top)',
        );
      }
    });

    test('warm-slot-only stack (top == -1) keeps the normal first-lookup path',
        () {
      // 仅剩隐藏热槽（lastVisibleIndex == -1）= 无可见弹窗：点字幕字符是「首次查词」
      // 入口，与旧行为一致换词（无害）。不是嵌套，故 `<=0` 门控正确放行。
      expect(
        VideoHibikiPage.shouldSwitchWordOnBarrierTap(
          topVisibleIndex: -1,
          hitSubtitle: true,
        ),
        isTrue,
        reason: '仅热槽（top=-1）= 无可见弹窗，点字幕首次查词走旧路（无害）',
      );
    });
  });

  test('video barrier tap-subtitle branch is gated by non-nested check', () {
    final String video =
        read('lib/src/pages/implementations/video_hibiki_page.dart');

    // 反查字幕命中分支必须经纯函数门控，不再无条件 `if (hit != null)` 直接换词。
    expect(
      video,
      contains('VideoHibikiPage.shouldSwitchWordOnBarrierTap('),
      reason: '点字幕换词必须门控在非嵌套态',
    );
    expect(
      video,
      contains('topVisibleIndex: _topVisiblePopupIndex'),
      reason: '门控判据用最顶层可见层下标',
    );
    // TODO-834：门控为假（含嵌套态命中字幕、点真空白）落到清整栈。
    expect(
      video,
      contains('_popNestedPopupAt(0);'),
      reason: '点外（含嵌套命中字幕、真空白）清整栈到 index 0',
    );
  });

  test('shouldSwitchWordOnBarrierTap is the documented non-nested gate', () {
    final String video =
        read('lib/src/pages/implementations/video_hibiki_page.dart');

    expect(
      video,
      contains('topVisibleIndex <= 0 && hitSubtitle'),
      reason: '门控纯函数判据：仅非嵌套且命中字幕才换词',
    );
  });
}
