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

  // TODO-720 / BUG-403: 点弹窗外（barrier onTap + 弹窗 onTapOutside）只关最顶层一层
  // （逐层退回父层），不一次清整栈。这些路径必须接逐层关原语，不能写死 index 0 /
  // 调清整栈的 clearDictionaryResult。
  test(
      'reader tap-outside routes through dismissTopPopup, not whole-stack clear',
      () {
    final String base = read('lib/src/pages/base_source_page.dart');

    // barrier 全屏 onTap 与弹窗 onTapOutside 都走逐层关原语。
    expect(base, contains('onTap: dismissTopPopup'),
        reason: 'barrier 点外只关最顶层一层');
    expect(base, contains('onTapOutside: dismissTopPopup'), reason: '弹窗点外只关本层');
    // 不再用清整栈的会话级路径接「点外」。
    expect(base, isNot(contains('onTap: clearDictionaryResult')),
        reason: '点外不应清整栈');
    expect(base, isNot(contains('onTapOutside: clearDictionaryResult')),
        reason: '点外不应清整栈');
    // 逐层关原语本体仍在（只关最顶层、保留父层）。
    expect(base,
        contains('final int index = _lastVisiblePopupIndex(_popup.entries);'),
        reason: 'dismissTopPopup 取最顶层可见层下标');
    expect(base, contains('if (index >= 0) _dismissPopupAt(index);'),
        reason: 'dismissTopPopup 只关最顶层（-1 时安全 no-op）');
  });

  test('video tap-outside barrier dismisses only the top visible layer', () {
    final String video =
        read('lib/src/pages/implementations/video_hibiki_page.dart');

    expect(video, contains('_popNestedPopupAt(_topVisiblePopupIndex);'),
        reason: '点外只关最顶层可见层');
    expect(video, isNot(contains('_popNestedPopupAt(0);')),
        reason: '不再写死 index 0 清整栈');
  });

  test('mixin tap-outside pops only the top visible layer', () {
    final String mixin =
        read('lib/src/pages/implementations/dictionary_page_mixin.dart');

    expect(mixin,
        contains('onTapOutside: () => onPop(controller.lastVisibleIndex)'),
        reason: '点外只关最顶层可见层');
    expect(mixin, isNot(contains('onTapOutside: () => onPop(0)')),
        reason: '不再写死 index 0 清整栈');
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
    // 门控为假（含嵌套态命中字幕）仍落到逐层关原语。
    expect(
      video,
      contains('_popNestedPopupAt(_topVisiblePopupIndex);'),
      reason: '点外（含嵌套命中字幕）只关最顶层可见层',
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
