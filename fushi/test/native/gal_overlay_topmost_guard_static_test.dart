import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-2365 源码守卫：台词浮窗**正文窗**的置顶重申。
///
/// 根因：穿透态下浮层是两个窗口——正文窗 + 独立逃生工具条窗。
/// `HookToolbarWindow::Sync` 每次渲染都无条件重申 `HWND_TOPMOST`（BUG-951 的不变式），
/// 正文窗却只在 show / clamp / DPI 变化时设过一次。galgame 切全屏会把游戏窗口抬进
/// 置顶带，同一带内是「最后一次 SetWindowPos 的赢」（BUG-1479 已在查词卡上确认过同一
/// 机制），于是正文窗被压到游戏底下再也上不来，而工具条下一帧就爬回去——用户看到的
/// 正是「字幕栏顶条还在、文字没了」。
///
/// 修复：正文窗拿到与查词卡同形状的 800ms 置顶守卫（`ReassertTopmost` + WM_TIMER），
/// 并在守卫里让位给可见的查词卡（否则两个 800ms 守卫互相抢置顶带最顶，卡片会周期性
/// 闪到浮窗底下）。
///
/// 守卫断言这三段结构在位：定时器接线、pin 语义、Z 序天花板。删掉任一段即红。
void main() {
  String read(String rel) {
    final File f = File(rel);
    expect(f.existsSync(), isTrue, reason: '文件不存在：$rel');
    return f.readAsStringSync().replaceAll('\r\n', '\n');
  }

  late final String body = read('windows/runner/floating_lyric_window.cpp');
  late final String bodyHeader = read('windows/runner/floating_lyric_window.h');
  late final String card = read('windows/runner/global_lookup_window.cpp');
  late final String wiring = read('windows/runner/flutter_window.cpp');

  test('正文窗有周期性置顶重申，且真的挂在定时器上', () {
    expect(body.contains('void FloatingLyricWindow::ReassertTopmost()'), isTrue,
        reason: 'BUG-2365：正文窗必须有置顶重申实现');
    expect(body.contains('kTopmostGuardTimerId'), isTrue,
        reason: '置顶守卫必须有自己的定时器 id');
    // 光有函数不算接线：WM_TIMER 必须真的把这个 id 分派到重申上，否则守卫永不触发。
    final int timerCase = body.indexOf('case WM_TIMER:');
    expect(timerCase, greaterThan(0), reason: '找不到 WM_TIMER 分支');
    final int dispatch = body.indexOf('kTopmostGuardTimerId', timerCase);
    expect(dispatch, greaterThan(0),
        reason: 'WM_TIMER 必须分派 kTopmostGuardTimerId → ReassertTopmost');
    expect(body.indexOf('ReassertTopmost();', dispatch), greaterThan(0),
        reason: 'kTopmostGuardTimerId 分支必须调 ReassertTopmost');
    // 显示时起表、隐藏 / 句柄失效时停表——留着就是后台空转，且下一次 Show 不再起表。
    expect(body.contains('StartTopmostGuard();'), isTrue,
        reason: 'Show 成功后必须起置顶守卫');
    expect(body.contains('StopTopmostGuard();'), isTrue,
        reason: '隐藏 / 句柄失效时必须停置顶守卫');
  });

  test('置顶守卫尊重 pin：用户取消置顶后不得把正文窗顶回去', () {
    // 📌 是显式意图。守卫无条件抬窗 = 这个按钮再也关不掉置顶。
    final int fn = body.indexOf('void FloatingLyricWindow::ReassertTopmost()');
    expect(fn, greaterThan(0));
    final int end = body.indexOf('\n}\n', fn);
    expect(end, greaterThan(fn));
    final String bodyBlock = body.substring(fn, end);
    expect(bodyBlock.contains('!topmost_'), isTrue,
        reason: 'BUG-2365：topmost_ 为假（用户取消置顶）时守卫必须早退');
  });

  test('置顶守卫让位给查词卡，两个守卫不互相抢最顶', () {
    // 查词卡自己也有 800ms 置顶守卫（BUG-1479）。两边都抢 HWND_TOPMOST 的话，
    // 卡片会周期性闪到浮窗底下——所以正文窗有卡片时插在卡片正下方。
    expect(card.contains('kTopmostGuardTimerId'), isTrue,
        reason: 'BUG-1479：查词卡的置顶守卫是本条让位逻辑的前提');
    expect(
        card.contains('HWND GlobalLookupWindow::TopmostCeilingHandle() const'),
        isTrue,
        reason: '查词卡必须暴露 Z 序天花板句柄');
    expect(bodyHeader.contains('void SetTopmostCeilingProvider('), isTrue,
        reason: '正文窗必须能接收 Z 序天花板');
    final int fn = body.indexOf('void FloatingLyricWindow::ReassertTopmost()');
    final int end = body.indexOf('\n}\n', fn);
    final String bodyBlock = body.substring(fn, end);
    expect(bodyBlock.contains('topmost_ceiling_'), isTrue,
        reason: 'BUG-2365：重申时必须查天花板');
    // 有天花板时是「插到它下面」（insertAfter = ceiling），不是抢最顶。
    expect(bodyBlock.contains('SetWindowPos(hwnd_, ceiling,'), isTrue,
        reason: '有可见查词卡时正文窗必须插在卡片之下，而不是 HWND_TOPMOST');
    // 抬完正文窗必须把逃生工具条重新顶上去，否则 BUG-951 的唯一出路被自己的正文盖住。
    expect(bodyBlock.contains('SyncPassThroughToolbar();'), isTrue,
        reason: 'BUG-951：重申后必须把逃生工具条重新顶到正文之上');
  });

  test('两个 FloatingLyricWindow 实例都接了 Z 序天花板', () {
    // 有声书悬浮字幕与 galgame 台词浮窗是同一个类的两个实例，Z 策略必须同一份。
    expect('SetTopmostCeilingProvider'.allMatches(wiring).length, 2,
        reason: 'floating_lyric_window_ 与 gal_hook_text_window_ 都要接天花板');
  });
}
