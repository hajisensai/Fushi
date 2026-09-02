import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import '../helpers/source_guard.dart';
import 'video_fushi_page_source_corpus.dart';

/// 源码守卫（BUG-176 ②）：控制条自动隐藏计时只在 media_kit 的鼠标 hover/进度条
/// 拖动时重置，键盘快进/跳句与底部按钮 tap 都不触发重置 → 控制条只活 2 秒就消失，
/// 用户「一直快进它也只保持两三秒然后消失」。修复=每次快进/跳句/seek 都
/// [_pokeControlsVisible] 往控制条区派发合成 hover，驱动 media_kit 自身的重置路径。
///
/// media_kit headless 不可跑视频 widget（无 native player / 无 hover 管线），故在
/// 源码层钉死接线契约，防回归把任一入口的续命/唤起删掉。
///
/// BUG-2030 后这份契约按输入通道**分成两半**（原来是一刀切「都接 poke」）：
/// - 指针交互（底栏按钮 tap / 双击 / hover 字幕盒 / 关面板）→ [_pokeControlsVisible]，
///   唤起 + 续命；
/// - 键盘 / 手柄快捷键（跳句 / ±秒 seek / 跳章 / 重播句）→ `_keepControlsAliveIfVisible`，
///   **只在控制条已可见时**续命，隐藏时什么都不做。用户报「快捷键上下句字幕会弹出 OSC」：
///   旧实现让键盘也走 poke，控制条隐藏时按一次跳句就把底栏弹出来、字幕跟着上顶一次。
///   BUG-176 ②/BUG-215 的原始诉求（连按时别 2 秒消失）落在「已可见」那一支，未被削弱。
///
/// 合并（守卫审计）：原 video_controls_poke_dedup_guard_test.dart 的
/// TODO-148/BUG-215 ② 去重抖动守卫并入本文件第二个 group，断言逐字搬运。
void main() {
  late String src;

  setUpAll(() {
    src = readVideoFushiSource();
  });

  group('BUG-176② 入口接线', () {
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
      final String body = methodBody(src, 'void _pokeControlsVisible()');
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

    test('键盘 / 手柄六个入口只【续命】控制条，不唤起（BUG-2030）', () {
      // BUG-2030 把 BUG-176 ② 的「每个入口都 poke」拆成两个语义：
      //   指针交互（底栏按钮 tap / 双击 / hover）→ _pokeControlsVisible（唤起 + 续命）
      //   键盘 / 手柄快捷键          → _keepControlsAliveIfVisible（只在已可见时续命）
      // 旧实现在控制条隐藏时按跳句也会派合成 hover → media_kit `onHover` 无条件
      // `visible = true` → 底栏凭空弹出 + 字幕上顶一次（用户报「快捷键上下句字幕会弹出
      // OSC」）。这里正向断言「走 keepAlive」+ 负向断言「回调里不再有裸 poke」，两条一起
      // 才挡得住回退：只留正向的话，有人再把 poke 加回去（两句都在）守卫照样绿。
      for (final String entry in <String>[
        'previousSubtitle',
        'nextSubtitle',
        'seekBackward',
        'seekForward',
        'previousChapter',
        'nextChapter',
      ]) {
        final List<String> callbacks = namedArgumentValues(src, entry);
        expect(callbacks, isNotEmpty, reason: '缺快捷键入口 $entry:');
        for (final String callback in callbacks) {
          expect(containsCodeLine(callback, '_keepControlsAliveIfVisible()'),
              isTrue,
              reason: '$entry: 键盘/手柄回调必须走 _keepControlsAliveIfVisible()'
                  '（控制条隐藏时不得唤起，BUG-2030）；注释里写着这句不算实现');
          expect(containsCodeLine(callback, '_pokeControlsVisible()'), isFalse,
              reason: '$entry: 键盘/手柄回调不得直接 poke——那会把隐藏的控制条整个'
                  '弹出来（BUG-2030）');
        }
      }
    });

    test('重播当前句 / 上一句同样只续命（仅快捷键入口，BUG-2030）', () {
      for (final String signature in <String>[
        'Future<void> _replayCurrentCueAndKeepControls() async {',
        'Future<void> _replayPreviousCueAndKeepControls() async {',
      ]) {
        final String body = methodBody(src, signature);
        expect(containsCodeLine(body, '_keepControlsAliveIfVisible()'), isTrue,
            reason: '$signature 必须走 keepAlive（BUG-2030）');
        expect(containsCodeLine(body, '_pokeControlsVisible()'), isFalse,
            reason: '$signature 不得唤起隐藏的控制条（BUG-2030）');
      }
    });

    test('_keepControlsAliveIfVisible 在控制条不可见时早退', () {
      final String body = methodBody(src, 'void _keepControlsAliveIfVisible()');
      expect(
        containsCodeLine(body, 'if (!_mediaKitControlsVisible.value) return;'),
        isTrue,
        reason: '续命原语必须以「不可见就早退」开路——门控只能做在派发合成 hover '
            '**之前**：media_kit 的 onHover 无条件 `visible = true`，合成 hover 本身'
            '分不出续命与唤起（BUG-2030）',
      );
      // 早退之后才是真正的续命动作，否则这方法就成了空壳。
      expect(containsCodeLine(body, '_pokeControlsVisible();'), isTrue,
          reason: '已可见时必须真的续命（复用 poke 的合成 hover 派发路径）');
    });

    test('media_kit fork 的桌面 onHover 仍是无条件唤起（BUG-2030 门控前提）', () {
      // 本条守的是「为什么门控必须在 Hibiki 侧、派发之前」这个前提：一旦上游/fork 把
      // onHover 改成条件式唤起，_keepControlsAliveIfVisible 的实现方式就该重新评估，
      // 而不是让它继续基于一个已经不成立的事实。
      final String fork = File(
        '../third_party/media_kit_video/lib/media_kit_video_controls/'
        'src/controls/material_desktop.dart',
      ).readAsStringSync().replaceAll('\r\n', '\n');
      final String body = methodBody(fork, 'void onHover() {');
      expect(containsCodeLine(body, 'visible = true;'), isTrue,
          reason: 'fork 的 onHover 应当仍是无条件把控制条翻可见');
      expect(
        RegExp(r'if\s*\(\s*!\s*visible\s*\)').hasMatch(maskComments(body)),
        isFalse,
        reason: 'onHover 里出现了可见性判断——fork 语义变了，请重新评估 '
            '_keepControlsAliveIfVisible 的门控位置（BUG-2030）',
      );
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
  });

  /// 源码守卫（TODO-148/BUG-215 ②）：连按快进/跳句时控制条自动隐藏计时不续命。
  ///
  /// 根因=[_pokeControlsVisible] 每次都把合成 hover 派发到控制条**固定中心点**，
  /// Flutter `MouseTracker` 对「同一设备落同一坐标」的连续 hover 去重 → 第二次起
  /// media_kit 的 `MouseRegion.onHover` 不再触发、隐藏 `Timer` 不重置，控制条仍只
  /// 活 2 秒就消失。修复=每次派发把 x 坐标 ±1px 抖动（[_pokeParity] 翻转），使坐标
  /// 始终变化、强制每次都回调 onHover 续命。
  ///
  /// media_kit headless 不可跑视频 widget（无 native player / 无 hover 管线 / 无
  /// MouseTracker 去重），故在源码层钉死「合成 hover 位置每次抖动、不再用固定
  /// center」契约，防回归把抖动删回固定坐标。
  group('poke 去重抖动 (BUG-215/TODO-148)', () {
    /// 取 _pokeControlsVisible 方法体：花括号配对，边界完全由源码结构给出。
    /// 演进史（两次塌陷都不是行为退化，是守卫自己塌掉）：固定 1200 字窗 →
    /// TODO-1059（平台无关门控前置）+ BUG-425（派发拆到 _dispatchPokeHover 微任务）
    /// 把方法体撑过 1200 字，pokePosition/派发落到窗外 → 改按「下一成员
    /// _dispatchPokeHover 的签名」切片 → 该成员一旦改名/挪位又会 indexOf 落空。
    /// 现在只依赖方法自身的花括号，且右界收在 `}` 上（比旧窗口更紧，
    /// `position: center` 这条禁止型断言不会再被下一个成员的代码污染）。
    String pokeBody() => methodBody(src, 'void _pokeControlsVisible()');

    test('存在 _pokeParity 抖动开关字段', () {
      expect(src.contains('bool _pokeParity = false;'), isTrue,
          reason: '必须有合成 hover 位置抖动开关字段（TODO-148/BUG-215）');
    });

    test('每次 poke 翻转 _pokeParity 并据此 ±1px 偏移合成 hover 位置', () {
      final String body = pokeBody();
      expect(body.contains('_pokeParity = !_pokeParity;'), isTrue,
          reason: 'poke 必须翻转 _pokeParity，使每次派发坐标都不同');
      expect(
        RegExp(r'_pokeParity \? 1\.0 : -1\.0').hasMatch(body),
        isTrue,
        reason: 'poke 必须据 _pokeParity 把 x 坐标 ±1px 偏移（绕开 MouseTracker 同坐标去重）',
      );
    });

    test('合成 hover 派发用抖动后的位置，而非固定 center', () {
      final String body = pokeBody();
      // 抖动后的位置变量喂给 PointerHoverEvent，而不是直接 position: center。
      expect(body.contains('Offset pokePosition ='), isTrue,
          reason: '必须先算出抖动后的 pokePosition');
      expect(
        RegExp(r'PointerHoverEvent\(\s*position: pokePosition,').hasMatch(body),
        isTrue,
        reason: '派发的 hover 必须用抖动后的 pokePosition（不是固定 center → 会被去重）',
      );
      expect(
        RegExp(r'PointerHoverEvent\(\s*position: center,').hasMatch(body),
        isFalse,
        reason: '不得回退用固定 center 派发（会触发 MouseTracker 同坐标去重，回归 BUG-215）',
      );
    });
  });
}
