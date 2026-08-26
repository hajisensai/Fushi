import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-1862 源码守卫：视频页的「返回上一级」必须先逐级关前台浮层，再退全屏 / 退页，
/// 且四条输入通道（键盘 Escape / [PopScope] 系统返回键 / 手柄 B / 屏幕上的返回箭头
/// 按钮）共用同一个层级表。
///
/// 纯函数层序由 `video_foreground_layers_test.dart` 断言；本文件守的是**接线**：
///   ① 退出汇聚点 `_handleBackOrExit` 必须先问 `_dismissTopForegroundLayer`——它是
///      [PopScope] / 系统返回键 / 手柄 B 的落点，漏了就等于 BUG-1862 原样复发；
///   ② Escape 快捷键回调也走同一个单点，不许再抄一份 if 链回来；
///   ③ controls builder 外面必须包着 `_wrapVideoControlsBackKey`——媒体页把侧栏等
///      overlay 挂在 media_kit controls 的**兄弟**位置，那层快捷键表够不着它们。
void main() {
  final File page = File(
    'lib/src/pages/implementations/video_fushi_page.dart',
  );
  final File layout = File(
    'lib/src/pages/implementations/video_fushi/layout.part.dart',
  );

  /// 统一按 LF 读源码：换行风格一变（CRLF checkout）就让所有子串断言恒不匹配、
  /// 整套守卫静默空转，比没有守卫更糟。
  String read(File f) => f.readAsStringSync().replaceAll('\r\n', '\n');

  /// 从方法签名切到方法体闭合的 `\n  }\n`（2 空格缩进的成员收尾）。
  ///
  /// 不用「起点 + 魔法长度」窗口：那种窗口一旦长过方法体，负向（`isNot`）断言就会
  /// 悄悄扩到隔壁方法上——既可能被隔壁的合法代码误伤，也可能把本该覆盖的尾部漏掉。
  String methodBody(String src, String signature) {
    final int start = src.indexOf(signature);
    expect(start, greaterThan(0), reason: '找不到 $signature');
    final int end = src.indexOf('\n  }\n', start);
    expect(end, greaterThan(start), reason: '$signature 的方法体没有闭合');
    return src.substring(start, end);
  }

  test('视频页与 layout part 都在（守卫不能因为文件改名而静默空转）', () {
    expect(page.existsSync(), isTrue, reason: '${page.path} 不存在');
    expect(layout.existsSync(), isTrue, reason: '${layout.path} 不存在');
  });

  test('退出汇聚点 _handleBackOrExit 第一件事是逐级关前台层', () {
    final String src = read(page);
    final String body =
        methodBody(src, 'Future<void> _handleBackOrExit() async {');
    expect(
      body.contains('if (_dismissTopForegroundLayer()) return;'),
      isTrue,
      reason: '_handleBackOrExit 必须先问 _dismissTopForegroundLayer 再 pop 路由，'
          '否则侧栏 / 字幕列表开着时按系统返回键会直接退掉整页（BUG-1862）',
    );
    // pop 路由必须排在关层之后。
    final int dismissAt = body.indexOf('_dismissTopForegroundLayer()');
    final int popAt = body.indexOf('nav.pop()');
    expect(popAt, greaterThan(dismissAt), reason: '真正 pop 路由必须排在逐级关层之后');
  });

  test('Escape 快捷键回调复用同一个层级表，不另抄一份 if 链', () {
    final String src = read(page);
    final int at = src.indexOf('      escape: () {');
    expect(at, greaterThan(0), reason: '找不到 escape 快捷键回调');
    final int end = src.indexOf('\n      },\n', at);
    expect(end, greaterThan(at), reason: 'escape 回调没有闭合');
    final String body = src.substring(at, end);
    expect(
      body.contains('if (_dismissTopForegroundLayer()) return;'),
      isTrue,
      reason: 'escape 回调必须走 _dismissTopForegroundLayer 单点',
    );
    for (final String forbidden in <String>[
      '_hideVideoSidePanel();',
      '_closeEpisodeList();',
      '_toggleSubtitleJumpList();',
    ]) {
      expect(
        body.contains(forbidden),
        isFalse,
        reason: 'escape 回调里又出现了 $forbidden —— 层级顺序被抄成第二份，'
            '它必然与 _dismissTopForegroundLayer 漂开（BUG-1862 的根因形态）',
      );
    }
  });

  test('层级表覆盖 controls Stack 里可关的兄弟层，pinned popover 不许漏', () {
    final String body =
        methodBody(read(page), 'bool _dismissTopForegroundLayer() {');
    expect(
      body.contains('controlPopoverOpen: _videoControlPopover.value != null'),
      isTrue,
      reason: '层级表必须读控制按钮 popover 的开合：点击打开那次会被 pin 住常驻，'
          '漏了就是「pinned popover 开着按 Esc，页面退了、浮层还在」（BUG-1862 同形）',
    );
    final int popoverGate =
        body.indexOf('controlPopoverOpen: _videoControlPopover.value != null');
    final int popoverClose = body.indexOf('_hideControlPopover();');
    expect(popoverClose, greaterThan(popoverGate),
        reason: '层级表读了 popover 却没关它，等于只判不做');
  });

  test('层级表只有一处：关闭动作只在表体内，两个退出口都不许自己关层', () {
    final String src = read(page);
    final String table =
        methodBody(src, 'bool _dismissTopForegroundLayer() {');
    final String exitPoint =
        methodBody(src, 'Future<void> _handleBackOrExit() async {');
    final int escapeAt = src.indexOf('      escape: () {');
    expect(escapeAt, greaterThan(0), reason: '找不到 escape 快捷键回调');
    final int escapeEnd = src.indexOf('\n      },\n', escapeAt);
    expect(escapeEnd, greaterThan(escapeAt), reason: 'escape 回调没有闭合');
    final String escapeBody = src.substring(escapeAt, escapeEnd);

    // 判据是**作用域**不是出现次数：数次数会被任何一处合法的新调用点误伤，报错
    // 文案还会误导成「层级表被抄了一份」。真正的不变式是「关闭动作只在层级表里
    // 执行，两个退出口只问它的返回值」。
    for (final String close in <String>[
      '_hideVideoSidePanel();',
      '_closeEpisodeList();',
      '_toggleSubtitleJumpList();',
      '_toggleImmersiveLock();',
      '_hideControlPopover();',
      '_hideVideoControlEditOverlay(revealControls: false);',
    ]) {
      expect(table.contains(close), isTrue,
          reason: '层级表里缺 $close —— 这一层没人关了');
      expect(
        exitPoint.contains(close),
        isFalse,
        reason: '_handleBackOrExit 里出现了 $close —— 层级顺序被抄成第二份，'
            '它必然与 _dismissTopForegroundLayer 漂开（BUG-1862 的根因形态）',
      );
      expect(
        escapeBody.contains(close),
        isFalse,
        reason: 'escape 回调里出现了 $close —— 同上，第二份层级表',
      );
    }
  });

  test('controls builder 外层包着 back 键兜底层', () {
    final String src = read(layout);
    final int at = src.indexOf('return VideoControlsFocusGate(');
    expect(at, greaterThan(0), reason: '找不到 VideoControlsFocusGate 挂载点');
    final String body = src.substring(at, at + 300);
    expect(
      body.contains('_wrapVideoControlsBackKey('),
      isTrue,
      reason: 'controls builder 必须包 _wrapVideoControlsBackKey：侧栏 / rail / '
          'popover 是 media_kit controls 的兄弟节点，焦点进了侧栏后 Esc 根本不经过 '
          'media_kit 的 keyboardShortcuts（BUG-1862）',
    );
    expect(
      body.contains('_buildVideoControlsInner('),
      isTrue,
      reason: '兜底层必须真的包住 controls 内容',
    );
  });

  test('back 键兜底层只在真关掉了一层时消费按键', () {
    final String body = methodBody(
      read(layout),
      'Widget _wrapVideoControlsBackKey(Widget child) {',
    );
    expect(body.contains('canRequestFocus: false'), isTrue, reason: '兜底层不得夺焦');
    expect(body.contains('skipTraversal: true'), isTrue,
        reason: '兜底层不得进 Tab 遍历');
    expect(
      body.contains('return _dismissTopForegroundLayer()'),
      isTrue,
      reason: '消费与否必须由 _dismissTopForegroundLayer() 的**返回值**决定；'
          '把它调完就丢、无条件返回 handled，会把 Esc 整个吞掉——视频页再也退不出去',
    );
    expect(
      body.contains('return KeyEventResult.handled;'),
      isFalse,
      reason: '兜底层里出现了无条件 handled：没有前台层可关时必须放行，'
          '否则退全屏 / 退页语义被这层改写',
    );
    expect(
      body.contains('KeyEventResult.ignored'),
      isTrue,
      reason: '没有前台层可关时必须放行，不能改写退全屏 / 退页语义',
    );
  });
}
