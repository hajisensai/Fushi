import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import '../helpers/source_guard.dart';
import 'video_fushi_page_source_corpus.dart';

/// 源码守卫（BUG-176 ②）：控制条自动隐藏计时只在 media_kit 的鼠标 hover/进度条
/// 拖动时重置，键盘快进/跳句与底部按钮 tap 都不触发重置 → 控制条只活 2 秒就消失，
/// 用户「一直快进它也只保持两三秒然后消失」。修复=每次快进/跳句/seek 都
/// [_pokeControlsVisible]，驱动 media_kit 自身的重置路径。
///
/// 「驱动」的形态在 BUG-2453 换过一次：旧实现往视频区几何中心派合成 hover 去命中
/// media_kit 的 MouseRegion，那条假鼠标设备在 MouseTracker 里永不注销、退出播放器后
/// 一直悬停在库页中心卡上；现在页面**不再合成任何指针事件**，两端只
/// `_restartHideTimerSignal.poke()`——桌面 fork 经 `wakeSignal` 收到即调自己的
/// `onHover()`（唤起 + 重排隐藏 Timer），移动 fork 经 `restartHideTimerSignal` 只重排
/// Timer。本文件只钉页面侧「每个入口都到达这条信号」的接线；信号 → fork 的装配与
/// 「语料无指针事件」由 video_controls_wake_signal_guard_test.dart 钉。
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
/// TODO-148/BUG-215 ② 去重抖动守卫并入本文件第二个 group；BUG-2453 后该 group 改成
/// 反向钉「抖动机制不得回来」（见 group 注释）。
void main() {
  late String src;

  setUpAll(() {
    src = readVideoFushiSource();
  });

  group('BUG-176② 入口接线', () {
    test('存在 _pokeControlsVisible 助手，唯一出口是 _restartHideTimerSignal.poke()', () {
      // methodBody 找不到签名会直接 fail——「必须有唤醒控制条的助手」由它兜住。
      final String body = methodBody(src, 'void _pokeControlsVisible()');
      expect(containsCodeLine(body, '_restartHideTimerSignal.poke();'), isTrue,
          reason: 'poke 必须发 _restartHideTimerSignal：桌面 fork 的 wakeSignal 收到即调'
              '自己的 onHover() 重置隐藏计时（BUG-176 ② 的原始诉求），页面不再合成指针'
              '事件去命中 MouseRegion（BUG-2453）');
      // 反向：旧的「派指针事件命中 MouseRegion」路径不得以任何形式回到 poke 体内——
      // 那正是幽灵设备的来源。
      expect(containsCodeLine(body, 'handlePointerEvent('), isFalse,
          reason: 'poke 不得再派发指针事件（BUG-2453：合成设备永不注销）');
      expect(containsCodeLine(body, 'PointerHoverEvent('), isFalse,
          reason: 'poke 不得再构造合成 hover（BUG-2453）');
    });

    test('poke 两端都发信号；桌面只多续命侧边锁按钮', () {
      expect(containsCodeLine(src, 'bool get _isDesktopVideoControls'), isTrue);
      // TODO-1059 把移动端改成「经 _restartHideTimerSignal 续命隐藏 Timer」；BUG-2453 把
      // 桌面也并到同一条信号上。于是 poke 体内唯一的平台分支只剩 `_pokeLockButton()`
      // （合成 hover 时代它经页面根 Listener 顺带续命锁按钮，改信号后显式补上），而
      // 信号本身**必须在平台分支之外**无条件发出——否则任一端都会回到「控制条 2 秒消失」。
      final String body = methodBody(src, 'void _pokeControlsVisible()');
      final int branchAt =
          maskComments(body).indexOf('if (_isDesktopVideoControls)');
      expect(branchAt, greaterThanOrEqualTo(0),
          reason: 'poke 应保留桌面分支续命侧边锁按钮（键盘 seek 时锁按钮跟着露出）');
      final String desktopBranch =
          balancedBlockFrom(body, branchAt, what: 'poke 的桌面分支');
      expect(containsCodeLine(desktopBranch, '_pokeLockButton();'), isTrue,
          reason: '桌面分支必须续命侧边锁按钮');
      expect(
        containsCodeLine(desktopBranch, '_restartHideTimerSignal.poke();'),
        isFalse,
        reason: '信号不得被桌面分支包住——移动端也靠它续命隐藏 Timer（TODO-1059）',
      );
      expect(containsCodeLine(body, '_restartHideTimerSignal.poke();'), isTrue,
          reason: '信号在平台分支之外无条件发出（两端共用，BUG-2453）');
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
        reason: '续命原语必须以「不可见就早退」开路——门控只能做在发信号'
            '**之前**：桌面 fork 的 wakeSignal 处理就是它自己的 onHover，无条件 '
            '`visible = true`，信号本身分不出续命与唤起（BUG-2030）',
      );
      // 早退之后才是真正的续命动作，否则这方法就成了空壳。
      expect(containsCodeLine(body, '_pokeControlsVisible();'), isTrue,
          reason: '已可见时必须真的续命（复用 poke 的信号路径）');
    });

    test('media_kit fork 的桌面 onHover 仍是无条件唤起（BUG-2030 门控前提）', () {
      // 本条守的是「为什么门控必须在 Hibiki 侧、发信号之前」这个前提：wakeSignal 的处理
      // 就是调 onHover()（video_controls_wake_signal_guard_test.dart 钉），一旦上游/fork 把
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

  /// 源码守卫（TODO-148/BUG-215 ②）：连按快进/跳句时控制条自动隐藏计时**每次都**续命。
  ///
  /// 历史：旧实现把合成 hover 派发到控制条固定中心点，Flutter `MouseTracker` 对「同一
  /// 设备落同一坐标」的连续 hover 去重 → 第二次起 media_kit 的 `onHover` 不再触发、
  /// 隐藏 Timer 不重置。当时的修法是每次派发把 x 坐标 ±1px 抖动（`_pokeParity` 翻转）。
  ///
  /// BUG-2453 删掉了整套合成派发，去重问题随之**在结构上消失**：信号是 Listenable，
  /// `poke()` 每次都无条件通知 fork 调 `onHover()`，没有坐标、没有设备、没有去重。
  /// 所以这组不再钉抖动，改成反向钉「抖动脚手架不得回来」——它们只在合成派发存在时才有
  /// 意义，任何一个重新出现都说明有人把合成设备（幽灵指针的来源）带回来了。
  /// 「每次都续命」这条原始不变量在新实现里的形态，就是上一组钉的「信号在平台分支之外
  /// 无条件发出」。
  group('poke 去重抖动脚手架不得回来 (BUG-215/TODO-148 → BUG-2453)', () {
    test('语料里没有 _pokeParity / pokePosition', () {
      for (final String needle in <String>['_pokeParity', 'pokePosition']) {
        expect(containsIdentifier(src, needle), isFalse,
            reason: '$needle 是合成 hover 抖动的脚手架，只在派指针事件时有意义；'
                '它回来 = 合成设备回来（BUG-2453）');
      }
    });

    test('poke 体内没有任何去重 / 折叠：每次调用都到达信号', () {
      final String body = methodBody(src, 'void _pokeControlsVisible()');
      // BUG-425 的微任务去重旗与 BUG-215 的抖动一样，都是合成派发的附属物；poke 一旦
      // 再按「已排程 / 同坐标」折叠调用，连按就回到「第二次起不续命」。
      expect(containsCodeLine(body, '_pokeDispatchScheduled'), isFalse,
          reason: '不得再用去重旗折叠 poke（BUG-425 脚手架，随合成派发一起删除）');
      expect(containsCodeLine(body, '_restartHideTimerSignal.poke();'), isTrue,
          reason: '每次 poke 都必须无条件到达信号（BUG-215 原始不变量）');
    });
  });
}
