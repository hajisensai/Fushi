import 'package:flutter_test/flutter_test.dart';
import 'video_hibiki_page_source_corpus.dart';

/// 源码守卫（BUG-176 ②）：控制条自动隐藏计时只在 media_kit 的鼠标 hover/进度条
/// 拖动时重置，键盘快进/跳句与底部按钮 tap 都不触发重置 → 控制条只活 2 秒就消失，
/// 用户「一直快进它也只保持两三秒然后消失」。修复=每次快进/跳句/seek 都
/// [_pokeControlsVisible] 往控制条区派发合成 hover，驱动 media_kit 自身的重置路径。
///
/// media_kit headless 不可跑视频 widget（无 native player / 无 hover 管线），故在
/// 源码层钉死「交互入口都接了 poke」契约，防回归把任一入口的 poke 删掉。
void main() {
  late String src;

  setUpAll(() {
    src = readVideoHibikiSource();
  });

  test('存在 _pokeControlsVisible 助手且经 GestureBinding 派发合成 hover', () {
    expect(src.contains('void _pokeControlsVisible()'), isTrue,
        reason: '必须有唤醒控制条的助手');
    expect(src.contains('GestureBinding.instance.handlePointerEvent'), isTrue,
        reason: 'poke 必须经 GestureBinding 派发指针事件以驱动 media_kit MouseRegion');
    expect(src.contains('PointerHoverEvent('), isTrue,
        reason: 'poke 必须派发 hover 事件（media_kit 在 onHover 重置隐藏计时）');
  });

  test('poke 仅桌面派发合成 hover（移动端 controls 无 hover 自动隐藏问题）', () {
    expect(src.contains('bool get _isDesktopVideoControls'), isTrue);
    // TODO-1059：平台无关的压制门控（沉浸锁 / 侧栏 / 字幕列表 / 编辑态）前置到
    // _isDesktopVideoControls 之前，且移动端改走 _restartHideTimerSignal.poke() 续命隐藏
    // Timer 而**不派合成 hover**（无 hover 语义）。故桌面门控不再是方法体首语句——守卫改成
    // 「方法体内存在 !_isDesktopVideoControls 早退」，不变量强度不变：移动端绝不派合成 hover。
    final int at = src.indexOf('void _pokeControlsVisible()');
    expect(at, greaterThanOrEqualTo(0), reason: '缺 _pokeControlsVisible 助手');
    final int end = src.indexOf('void _dispatchPokeHover', at);
    expect(end, greaterThan(at), reason: '缺 _dispatchPokeHover（方法体终点锚）');
    final String body = src.substring(at, end);
    expect(
      RegExp(r'if \(!_isDesktopVideoControls\)\s*\{').hasMatch(body),
      isTrue,
      reason:
          '_pokeControlsVisible 必须门控 _isDesktopVideoControls（移动端不派合成 hover）',
    );
    // 移动端分支续命隐藏 Timer 而非派合成 hover（TODO-1059）。
    expect(body.contains('_restartHideTimerSignal.poke();'), isTrue,
        reason: '移动端经 _restartHideTimerSignal 续命，而非派合成 hover');
  });

  test('键盘快进/跳句四个入口都调用 _pokeControlsVisible', () {
    // previousSubtitle / nextSubtitle / seekBackward / seekForward 各一次。
    for (final String entry in <String>[
      'previousSubtitle:',
      'nextSubtitle:',
      'seekBackward:',
      'seekForward:',
    ]) {
      final int at = src.indexOf(entry);
      expect(at, greaterThanOrEqualTo(0), reason: '缺快捷键入口 $entry');
      // 入口回调体（到下一个逗号分隔的下一个 action 之前一段）里必须有 poke。
      final String window = src.substring(at, at + 200);
      expect(window.contains('_pokeControlsVisible()'), isTrue,
          reason: '$entry 回调必须 poke 控制条（BUG-176 ②）');
    }
  });

  test('_seekRelative 与底部跳句按钮都唤醒控制条', () {
    // _seekRelative（底部 ±10 共用）内部 poke。
    expect(
      RegExp(r'Future<void> _seekRelative\(int deltaMs\) async \{\s*_pokeControlsVisible\(\);')
          .hasMatch(src),
      isTrue,
      reason: '_seekRelative 必须 poke（底部 ±10 按钮共用，tap 不触发 media_kit 重置）',
    );
    // 底部「上/下一句」按钮经 _skipCueAndPokeControls。
    expect(src.contains('_skipCueAndPokeControls(forward: false)'), isTrue);
    expect(src.contains('_skipCueAndPokeControls(forward: true)'), isTrue);
    expect(
      RegExp(r'Future<void> _skipCueAndPokeControls\(\{required bool forward\}\) async \{\s*_pokeControlsVisible\(\);')
          .hasMatch(src),
      isTrue,
      reason: '_skipCueAndPokeControls 必须先 poke',
    );
  });
}
