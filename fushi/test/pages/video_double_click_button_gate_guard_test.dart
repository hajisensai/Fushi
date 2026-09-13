import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/shortcuts/input_binding.dart'
    show domMouseButtonFromPointerButtons;

import 'video_fushi_page_source_corpus.dart';

/// BUG-2403：视频页「双击画面」判定（桌面 → 切全屏 / 双击左右区 seek，移动 → 暂停）
/// 必须**只认左键与触摸**。
///
/// 根因不是某个分支写错，而是判据整个不存在：`_handleVideoPointerUp` 手写 400ms +
/// 48px 的双击窗口，从头到尾没读过按钮号，于是右键 / 中键 / 侧键的两次抬起照样命中，
/// 桌面直接 `_toggleVideoFullscreen()`——用户看到的是「右键双击把全屏关掉」。挂载点
/// 的注释一直写着「左键双击全屏」，那句话此前只是注释。
///
/// 为什么判据必须在**按下侧**记账：[PointerUpEvent.buttons] 在抬起那一刻恒为 0
/// （按钮已释放），抬起事件自己拿不到「刚才按的是哪个键」。下面第一组是这条前提的
/// 真断言——它一旦不成立（Flutter 改了语义），整个修复的形状就该重来，而不是让守卫
/// 继续绿着。
///
/// 真实双击时序 / media_kit 控制条跑不了 headless（与 `video_double_tap_seek_guard_test`
/// / `video_orientation_fullscreen_guard_test` 同范式），故行为不变式用源码守卫钉。
/// 钉的是**不变式**而不是写法：门在哪一行、布尔叫什么名字都可以改，但
/// 「记账与判定挂同一个 Listener」「门排在双击执行体之前」「按钮折叠只走全仓那个
/// 唯一函数」这三条一旦被绕开，本 bug 就原样复发。
void main() {
  group('前提：抬起事件拿不到按钮号', () {
    test('PointerUpEvent.buttons 恒为 0，按钮判据只能在按下侧记账', () {
      const PointerUpEvent up = PointerUpEvent(pointer: 7);
      expect(up.buttons, 0);
      expect(domMouseButtonFromPointerButtons(up.buttons), isNull);
    });

    test('按下侧的折叠：左键与触摸不可绑，右键 / 中键 / 侧键各有唯一号', () {
      // 左键与触摸合成事件的 buttons 都是 kPrimaryButton → 折不出按钮号 → 恒不入账，
      // 双击全屏 / 双击 seek / 移动端双击暂停因此逐字不变。
      expect(domMouseButtonFromPointerButtons(kPrimaryMouseButton), isNull);
      expect(domMouseButtonFromPointerButtons(0), isNull);
      // 会被门挡住的那三类。
      expect(domMouseButtonFromPointerButtons(kMiddleMouseButton), 1);
      expect(domMouseButtonFromPointerButtons(kSecondaryMouseButton), 2);
      expect(domMouseButtonFromPointerButtons(kBackMouseButton), 3);
      expect(domMouseButtonFromPointerButtons(kForwardMouseButton), 4);
    });
  });

  group('源码守卫：双击判定的按钮门', () {
    late String corpus;
    late String layoutSrc;

    setUpAll(() {
      corpus = readVideoFushiSource();
      layoutSrc = File(
        '$kVideoFushiPartDir/layout.part.dart',
      ).readAsStringSync();
    });

    /// 取一个方法体（签名行到匹配的收尾大括号），大括号配对避免误截嵌套闭包。
    String methodBody(String source, String namePrefix) {
      final int start = source.indexOf(namePrefix);
      expect(start, greaterThanOrEqualTo(0), reason: '找不到方法: $namePrefix');
      final int braceStart = source.indexOf('{', start);
      expect(braceStart, greaterThanOrEqualTo(0),
          reason: '找不到方法体: $namePrefix');
      int depth = 0;
      for (int i = braceStart; i < source.length; i++) {
        if (source[i] == '{') depth++;
        if (source[i] == '}') {
          depth--;
          if (depth == 0) return source.substring(start, i + 1);
        }
      }
      fail('方法体大括号未闭合: $namePrefix');
    }

    test('记账与双击判定挂在同一个 Listener 上', () {
      final int downAt =
          layoutSrc.indexOf('onPointerDown: _recordVideoPointerButton');
      final int upAt = layoutSrc.indexOf('onPointerUp: _handleVideoPointerUp');
      expect(downAt, greaterThanOrEqualTo(0),
          reason: '按下侧记账没挂上：抬起侧的按钮门永远拿不到账，右键双击会重新切全屏');
      expect(upAt, greaterThan(downAt),
          reason: '记账应排在同一个 Listener 的 onPointerUp 之前');
      // 两者之间不允许另起一层 Listener / 进入 child 子树——换挂载点两者的命中集合
      // 就不再一致（记了账收不到抬起，或收到抬起却没有账），门会时灵时不灵。
      final String between = layoutSrc.substring(downAt, upAt);
      expect(between.contains('Listener('), isFalse,
          reason: '记账与判定之间不能夹另一个 Listener');
      expect(between.contains('child:'), isFalse,
          reason: '记账与判定必须是同一个 Listener 的参数，不能跨 child 子树');
      // 指针被取消时销账，否则该 pointer 的记录永远留在集合里（抬起不会再来）。
      expect(layoutSrc.contains('onPointerCancel: _forgetVideoPointerButton'),
          isTrue,
          reason: '缺 onPointerCancel 销账 → 非主键记录泄漏');
    });

    /// 返回「按钮账被用作早返回条件」那条语句在方法体里的结束位置。
    ///
    /// 判据刻意不认变量名、也不认写成一条还是两条语句，但**必须**是那笔账自己在
    /// 决定 return——只要求「门之后某处有 return」是空壳：方法体里本来就有 episode
    /// 横轨 / 侧栏 / chrome 三条早返回，`contains('return')` 恒真（实测：删掉真正的
    /// 按钮门，那种写法照样全绿）。
    int buttonGateEndOffset(String body) {
      const String account = '_nonPrimaryVideoPointers.remove(';
      // 写法一：直接把账用作 if 条件。
      final RegExp inline = RegExp(
        r'if\s*\(\s*_nonPrimaryVideoPointers\.remove\([^)]*\)\s*\)\s*(\{\s*)?return',
      );
      final RegExpMatch? inlineHit = inline.firstMatch(body);
      if (inlineHit != null) return inlineHit.end;
      // 写法二：先记到一个局部布尔，再由它决定 return。
      final RegExp assign = RegExp(
        r'(\w+)\s*=\s*' + RegExp.escape(account),
        multiLine: true,
      );
      final RegExpMatch? assignHit = assign.firstMatch(body);
      expect(assignHit, isNotNull,
          reason: '_handleVideoPointerUp 不再读按钮账 = 双击判定又变成不看按钮号');
      final String variable = assignHit!.group(1)!;
      final RegExp gate = RegExp(
        r'if\s*\(\s*' + variable + r'\s*\)\s*(\{\s*)?return',
      );
      final RegExpMatch? gateHit = gate.firstMatch(body);
      expect(gateHit, isNotNull,
          reason: '按钮账（$variable）读了却没用作早返回条件 → 非主键照样触发双击');
      return gateHit!.end;
    }

    test('按钮门排在双击执行体之前', () {
      final String body = methodBody(corpus, 'void _handleVideoPointerUp(');
      final int gateEnd = buttonGateEndOffset(body);
      for (final String executor in <String>[
        '_handleDoubleTapSeek(',
        '_toggleVideoFullscreen(',
      ]) {
        final int execAt = body.indexOf(executor);
        expect(execAt, greaterThanOrEqualTo(0), reason: '找不到执行体: $executor');
        expect(execAt, greaterThan(gateEnd),
            reason: '$executor 排在了按钮门之前 → 非主键仍能触发双击行为');
      }
    });

    test('按钮折叠只走全仓唯一的那个函数', () {
      final String body = methodBody(corpus, 'void _recordVideoPointerButton(');
      expect(body.contains('domMouseButtonFromPointerButtons('), isTrue,
          reason: '记账必须复用全仓统一的按钮折叠（设置页录制 / 鼠标绑定 / 右键菜单同源）');
      // 手写按钮比较会与录制侧错位（本仓 BUG-1269 的老账），这里直接禁掉。
      for (final String raw in <String>[
        'kSecondaryMouseButton',
        'kMiddleMouseButton',
        'kBackMouseButton',
        'kForwardMouseButton',
      ]) {
        expect(body.contains(raw), isFalse,
            reason: '不要在这里手写按钮比较（$raw），会与设置页的录制判据错位');
      }
    });
  });
}
