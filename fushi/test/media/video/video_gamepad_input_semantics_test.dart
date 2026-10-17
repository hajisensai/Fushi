import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/video/video_player_shortcuts.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';

import '../../helpers/source_guard.dart';
import '../../pages/video_fushi_page_source_corpus.dart';

/// 视频页手柄输入的两条语义（反馈 #e6hKBVvAcQ / #m32Z1LFu2u）。
///
/// BUG-3339：手柄「上一句字幕」曾复用键盘 Ctrl+← 的执行体，上一句离得远时退化成
/// 回退 3 秒（用户：「像固定秒数倒退，连跳一两下才到句首」），而屏幕双击一直恒跳句。
/// 输入种类现在是构造动作表的显式参数 [VideoActionInput]。
///
/// BUG-3330：手柄「按住临时倍速」只有按下沿，退化成点按翻转。现在键盘与手柄共用
/// 同一个按住状态机 [resolveHoldSpeedTransition]，手柄的松开沿来自 Android 原生
/// KeyUpEvent 或桌面轮询的 GamepadButtonReleaseIntent。
void main() {
  group('BUG-3339：上一句字幕按输入种类分语义', () {
    test('只有键盘把太远的上一句退化成时间回退；按钮类输入恒跳句', () {
      expect(
        videoPrevSubtitleDegradesFarCue(VideoActionInput.keyboard),
        isTrue,
      );
      expect(videoPrevSubtitleDegradesFarCue(VideoActionInput.button), isFalse);
    });

    test('每个派发点都显式声明输入种类，且手柄 / 鼠标 / 屏幕按钮是 button', () {
      final String src = maskComments(readVideoFushiSource());
      String inputAt(String signature) {
        final String body = methodBody(src, signature);
        final RegExpMatch? m = RegExp(
          r'_buildVideoShortcutActions\(\s*\w+!?,\s*input:\s*VideoActionInput\.(\w+)',
        ).firstMatch(body);
        expect(m, isNotNull, reason: '$signature 里找不到带 input 的动作表构造');
        return m!.group(1)!;
      }

      expect(inputAt('bool _handleVideoGamepadButton('), 'button');
      expect(inputAt('void _handleVideoPointerDown('), 'button');
      expect(inputAt('bool _handleVideoKeyboardShortcut('), 'keyboard');
      // 动作表构造本身必须要求 input（不是带默认值的可选参数）——默认值会让新派发点
      // 静默继承某一类语义，正是本 bug 的形态。
      expect(
        RegExp(
          r'_buildVideoShortcutActions\(\s*VideoPlayerController controller,\s*\{\s*required VideoActionInput input,',
        ).hasMatch(src),
        isTrue,
      );
      expect(
        containsCodeLine(
          src,
          'degradeFarCueToTimeSeek: videoPrevSubtitleDegradesFarCue(input),',
        ),
        isTrue,
        reason: '上一句字幕的退化开关必须来自 input，不能写死',
      );
    });
  });

  group('BUG-3330：手柄按住临时倍速与键盘同一状态机', () {
    const GamepadButton x = GamepadButton.x;
    const GamepadButton lb = GamepadButton.lb;

    HoldSpeedKeyTransition step(
      HoldSpeedEdge edge,
      GamepadButton button, {
      GamepadButton? active,
      bool matches = true,
    }) => resolveHoldSpeedTransition<GamepadButton>(
      edge: edge,
      trigger: button,
      activeTrigger: active,
      matchesHoldSpeedBinding: matches,
    );

    test('按下进入、按住中重复被吞、松开恢复', () {
      expect(step(HoldSpeedEdge.press, x), HoldSpeedKeyTransition.engage);
      expect(
        step(HoldSpeedEdge.repeat, x, active: x),
        HoldSpeedKeyTransition.swallow,
      );
      // 桌面 D-pad 自动重复以「按下」到达：同一触发物照样吞掉，不翻转。
      expect(
        step(HoldSpeedEdge.press, x, active: x),
        HoldSpeedKeyTransition.swallow,
      );
      expect(
        step(HoldSpeedEdge.release, x, active: x),
        HoldSpeedKeyTransition.release,
      );
    });

    test('长按不再被当成一次点按：按下与松开之间没有第二次翻转', () {
      // 修复前手柄走 toggle：按下开、再按下关；长按只有一次按下 → 永远开着直到再按。
      // 状态机下，松开沿本身就是恢复，与按住时长无关。
      expect(
        step(HoldSpeedEdge.release, x, active: x),
        HoldSpeedKeyTransition.release,
      );
      expect(step(HoldSpeedEdge.release, x), HoldSpeedKeyTransition.none);
    });

    test('别的按钮的松开 / 重复不影响按住态', () {
      expect(
        step(HoldSpeedEdge.release, lb, active: x),
        HoldSpeedKeyTransition.none,
      );
      expect(
        step(HoldSpeedEdge.repeat, lb, active: x),
        HoldSpeedKeyTransition.none,
      );
      expect(
        step(HoldSpeedEdge.press, lb, active: x),
        HoldSpeedKeyTransition.none,
      );
    });

    test('页面接线：按下 / 松开 / 重复三条手柄入口都进同一个状态机', () {
      final String src = maskComments(readVideoFushiSource());
      final String press = methodBody(src, 'bool _handleVideoGamepadButton(');
      expect(
        press.contains(
          '_handleHoldSpeedGamepadEdge(HoldSpeedEdge.press, button)',
        ),
        isTrue,
        reason: '手柄按下 videoHoldSpeed 必须进按住状态机，不能再走翻转回调',
      );
      final String native = methodBody(
        src,
        'KeyEventResult _handleVideoGamepadNativeKey(',
      );
      expect(
        native.contains('KeyUpEvent() =>'),
        isTrue,
        reason: 'Android 手柄松开沿（KeyUpEvent）必须送进页面',
      );
      expect(native.contains('HoldSpeedEdge.repeat'), isTrue);
      final String wrap = methodBody(src, 'Widget _wrapVideoGamepadControls(');
      expect(
        wrap.contains('GamepadButtonReleaseIntent:'),
        isTrue,
        reason: '桌面轮询的松开沿经 GamepadButtonReleaseIntent 派发到本页',
      );
      final String edge = methodBody(src, 'bool _handleHoldSpeedGamepadEdge(');
      expect(
        edge.contains('resolveHoldSpeedTransition<GamepadButton>('),
        isTrue,
      );
    });
  });
}
