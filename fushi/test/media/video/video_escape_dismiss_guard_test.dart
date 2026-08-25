import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-1862 源码守卫：视频页的「返回上一级」必须先逐级关前台浮层，再退全屏 / 退页，
/// 且三条输入通道（键盘 Escape / [PopScope] 系统返回键 / 手柄 B）共用同一个层级表。
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

  test('视频页与 layout part 都在（守卫不能因为文件改名而静默空转）', () {
    expect(page.existsSync(), isTrue, reason: '${page.path} 不存在');
    expect(layout.existsSync(), isTrue, reason: '${layout.path} 不存在');
  });

  test('退出汇聚点 _handleBackOrExit 第一件事是逐级关前台层', () {
    final String src = read(page);
    final int at = src.indexOf('Future<void> _handleBackOrExit() async {');
    expect(at, greaterThan(0), reason: '找不到 _handleBackOrExit 定义');
    final String body = src.substring(at, at + 400);
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
    final String body = src.substring(at, at + 900);
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

  test('层级表只有一处：关闭动作不在页面里散落第二份', () {
    final String src = read(page);
    // 每个关闭动作在整份主体里只应被层级表调用一次（定义处的调用）。
    // 其它入口（按钮 / 互斥逻辑）走各自的 part 文件，不在本文件里。
    expect(
      '_hideVideoSidePanel();'.allMatches(src).length,
      1,
      reason: '_hideVideoSidePanel 在 video_fushi_page.dart 里出现了不止一次，'
          '逐级退出的层级表可能又被抄了一份',
    );
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
    final String src = read(layout);
    final int at = src.indexOf('Widget _wrapVideoControlsBackKey(');
    expect(at, greaterThan(0), reason: '找不到 _wrapVideoControlsBackKey 定义');
    final String body = src.substring(at, at + 1600);
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
