import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_player_shortcuts.dart';

/// BUG-1864 跟进 / BUG-962 同源：页级裸空格覆盖 `_withPageSpaceOverride` 的判据。
///
/// 这些用例打的是**生产纯函数** [decidePageSpaceOverride] 本身，不是同构副本——
/// `VideoFushiPage` 驱动 media_kit、离屏起不来整页 widget 树，把判据留在页面里就只能
/// 靠副本测，而副本改坏了生产照样绿（这正是本轮要消掉的测试形态）。
void main() {
  const KeyDownEvent spaceDown = KeyDownEvent(
    physicalKey: PhysicalKeyboardKey.space,
    logicalKey: LogicalKeyboardKey.space,
    timeStamp: Duration.zero,
  );
  const KeyRepeatEvent spaceRepeat = KeyRepeatEvent(
    physicalKey: PhysicalKeyboardKey.space,
    logicalKey: LogicalKeyboardKey.space,
    timeStamp: Duration.zero,
  );
  const KeyUpEvent spaceUp = KeyUpEvent(
    physicalKey: PhysicalKeyboardKey.space,
    logicalKey: LogicalKeyboardKey.space,
    timeStamp: Duration.zero,
  );
  const KeyDownEvent enterDown = KeyDownEvent(
    physicalKey: PhysicalKeyboardKey.enter,
    logicalKey: LogicalKeyboardKey.enter,
    timeStamp: Duration.zero,
  );

  PageSpaceOverrideDecision decide(
    KeyEvent event, {
    bool hasModifier = false,
    bool hasEditableFocus = false,
    bool hasVisiblePopup = false,
    bool hasController = true,
  }) =>
      decidePageSpaceOverride(
        event: event,
        hasModifier: hasModifier,
        hasEditableFocus: hasEditableFocus,
        hasVisiblePopup: hasVisiblePopup,
        hasController: hasController,
      );

  test('裸空格按下沿 → 播放/暂停（TODO-755 的兜底本体）', () {
    expect(decide(spaceDown), PageSpaceOverrideDecision.togglePlayPause);
  });

  test('BUG-962 同源：文本框持焦时必须让位给 text-input，不得当成播放/暂停', () {
    expect(
      decide(spaceDown, hasEditableFocus: true),
      PageSpaceOverrideDecision.yieldToTextInput,
      reason: '本层比全局中和层更近、先看到按键；不自带 focusedEditableText 豁免，'
          '视频页侧栏的 mpv.conf / 弹幕屏蔽规则 / 弹幕手动匹配搜索框就打不出空格，'
          '而且每按一次空格还误触播放/暂停',
    );
  });

  test('BUG-962 同源：文本框持焦时**重复沿**也必须让位（长按打连续空格）', () {
    expect(
      decide(spaceRepeat, hasEditableFocus: true),
      PageSpaceOverrideDecision.yieldToTextInput,
    );
  });

  test('文本框持焦优先于词典浮层：先保证能打字', () {
    expect(
      decide(spaceDown, hasEditableFocus: true, hasVisiblePopup: true),
      PageSpaceOverrideDecision.yieldToTextInput,
    );
  });

  test('重复沿：消费但不重复触发（旧 SingleActivator includeRepeats 会连点暂停）', () {
    expect(
      decide(spaceRepeat),
      PageSpaceOverrideDecision.swallowRepeat,
      reason: '必须仍然消费——放行会漏给 WidgetsApp 默认的 space→ActivateIntent，'
          '长按空格变成连点激活当前焦点控件（全局 _neutralizeBareSpace 只吃按下沿）',
    );
  });

  test('抬起沿放行（旧 SingleActivator 也从不匹配抬起沿）', () {
    expect(decide(spaceUp), PageSpaceOverrideDecision.passThrough);
  });

  test('非空格键放行', () {
    expect(decide(enterDown), PageSpaceOverrideDecision.passThrough);
  });

  test('带修饰键放行（Ctrl/Shift/Alt/Meta + Space 旧实现本就不匹配）', () {
    expect(
      decide(spaceDown, hasModifier: true),
      PageSpaceOverrideDecision.passThrough,
    );
  });

  test('加载态 / 资源缺失态（无 controller）按下沿放行给全局中和层', () {
    expect(
      decide(spaceDown, hasController: false),
      PageSpaceOverrideDecision.passThrough,
      reason: '与本层上提到 _wrapVideoGamepadControls 之前一致：'
          '那时本层根本不挂在加载态那条分支上',
    );
  });

  test('词典浮层可见时先关浮层（BUG-924）', () {
    expect(
      decide(spaceDown, hasVisiblePopup: true),
      PageSpaceOverrideDecision.dismissPopup,
    );
  });
}
