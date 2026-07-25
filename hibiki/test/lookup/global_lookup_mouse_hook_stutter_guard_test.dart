import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-1077 的静态守卫：app 外**嵌套**查词瞬间全局鼠标不得再卡一下。
///
/// BUG-1048 把 `WH_MOUSE_LL` 挪到了专用线程，但留下两个残余机制，正好在嵌套查词
/// 的瞬间叠加发作：
///   ① 钩子线程默认 NORMAL 优先级——嵌套查词瞬间进程内 CPU 风暴（同步 FFI 词典
///      查询 + 整栈 JSON 序列化 + WebView2 COM + 窗口区域重建）把它抢占几十毫秒，
///      而 LL 钩子是同步的：系统等它返回才分发输入，全系统鼠标跟着卡一下；
///   ② 剪贴板面板 / galgame 浮窗路径的嵌套查词走「reset Hide → 再 Reveal」，
///      Hide 无条件 Disarm、Reveal 再 Arm——每次嵌套做两回全局钩子表变更（桌面级
///      钩子链更新与 Raw Input 线程串行，各是一次全系统输入短暂停顿）。
///
/// 纯 Win32 输入队列行为无法在 Dart 侧行为测试里复现，最强可落地层是锁住修复结构：
///   ① 钩子线程必须以 TIME_CRITICAL 优先级运行；
///   ② Disarm 必须是「清目标 + 宽限期延迟真卸」（SetTimer/KillTimer 线程定时器），
///      不允许退回收到 Disarm 就立即 UnhookWindowsHookEx 的立卸立装；
///   ③ 首次建线程等待 id 发布必须走事件（WaitForSingleObject），不允许退回
///      Sleep(1) 自旋——那段等待跑在 platform 线程上，默认定时器精度下一次就能
///      睡 ~15ms。
void main() {
  final String hook =
      File('windows/runner/low_level_mouse_hook.cpp').readAsStringSync();

  test('钩子线程以 TIME_CRITICAL 优先级运行', () {
    expect(
      hook.contains('SetThreadPriority(GetCurrentThread(),'
          ' THREAD_PRIORITY_TIME_CRITICAL)'),
      isTrue,
      reason: 'BUG-1077：LL 钩子承载线程被普通优先级抢占时全系统鼠标会卡，'
          '必须提到 TIME_CRITICAL',
    );
  });

  test('Disarm 走宽限期延迟真卸，不立卸立装', () {
    expect(hook.contains('kDisarmGraceMs'), isTrue,
        reason: '必须有宽限期常量：嵌套查词 Hide→Reveal 间隔内不得真卸钩子');
    expect(hook.contains('SetTimer(nullptr,'), isTrue,
        reason: '延迟卸载靠钩子线程自己的线程定时器');
    expect(hook.contains('KillTimer(nullptr,'), isTrue,
        reason: '新的 Arm 到来必须取消挂起的延迟卸载');
  });

  test('等待钩子线程就绪用事件，不用 Sleep 自旋', () {
    expect(hook.contains('WaitForSingleObject('), isTrue,
        reason: '首次 Arm 在 platform 线程上等 id 发布，必须事件等待');
    expect(
      hook.contains('Sleep('),
      isFalse,
      reason: 'Sleep(1) 自旋在默认定时器精度下单次可睡 ~15ms，会卡 platform 线程',
    );
  });
}
