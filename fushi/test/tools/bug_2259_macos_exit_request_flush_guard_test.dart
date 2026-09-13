import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-2259 守卫：macOS 的「退出应用」必须跑退出 flush。
///
/// window_manager 的 `setPreventClose(true)` 只拦 NSWindow 的
/// `windowShouldClose:`（点红叉）。macOS 上最常用的退出方式——⌘Q / 菜单
/// 「退出 Hibiki」/ Dock 右键退出——走的是 NSApplication 的
/// `applicationShouldTerminate:`，**完全不经过 `onWindowClose`**。于是整条
/// `_flushAndExitForWindowClose`（窗口几何落盘 → ExitFlushRegistry 把活跃阅读 /
/// 听书 / 观看页尚未落库的位置与统计写穿 → 关书同步 drain → close database 做 WAL
/// checkpoint）在那条路径上一次都不跑：阅读位置只剩 500ms 去抖那一档、有声书位置
/// 只剩「整秒变化」那一档、阅读统计段落（StudyClock / ReadUnitLedger）整段丢失。
///
/// `AppLifecycleListener.onExitRequested` 正是 `applicationShouldTerminate:` 在
/// Dart 侧的落点，且系统会等它的 Future 完成后才终止进程——这正是 flush 需要的
/// 「退出前还活着」的窗口。
///
/// 这层守卫是本 bug **可落地的最强层**：真正的行为验证要求进程真的走到
/// `exit(0)`，没有任何单测宿主能容纳；而「注册了没有、注册在哪个平台、回调是不是
/// 同一条退出链」恰好全是源码层的静态事实。
void main() {
  group('BUG-2259 macOS 退出请求 → 退出 flush', () {
    late String src;

    setUpAll(() {
      final File f = File('lib/main.dart');
      expect(f.existsSync(), isTrue, reason: 'main.dart 被移动了，守卫需同步更新');
      src = f.readAsStringSync();
    });

    test('macOS 必须注册 AppLifecycleListener(onExitRequested:)', () {
      final int at = src.indexOf('AppLifecycleListener(');
      expect(
        at,
        greaterThan(-1),
        reason: '没有 exit-request 监听 ⇒ ⌘Q / 菜单退出 / Dock 退出全都不 flush，'
            '阅读位置与有声书进度停在最后一次去抖落库（BUG-2259 回归）',
      );
      expect(
        src.substring(at, at + 200).contains('onExitRequested:'),
        isTrue,
        reason: '监听器没接 onExitRequested ⇒ applicationShouldTerminate: 仍然直通终止',
      );
      // 注册点必须门控在 macOS：Windows/Linux 的关闭信号已由 window_manager 的
      // preventClose 完整覆盖，两条路同时挂只会让同一次退出跑两遍。
      final String before = src.substring((at - 1600).clamp(0, at), at);
      expect(
        before.contains('Platform.isMacOS'),
        isTrue,
        reason: '注册点缺平台门控，守卫需同步更新（或注册被搬到了别处）',
      );
    });

    test('退出请求回调走的是与关窗口同一条 flush 链', () {
      final int at = src.indexOf(
        'Future<AppExitResponse> _handleExitRequested() async {',
      );
      expect(at, greaterThan(-1), reason: '回调改名了，守卫需同步更新');
      final String body = src.substring(at, at + 400);
      expect(
        body.contains('await _flushAndExitForWindowClose()'),
        isTrue,
        reason: '退出请求必须复用关窗口那条链（几何落盘 + ExitFlushRegistry + 关书同步 '
            'drain + close database），否则「关窗口能保住的数据，⌘Q 保不住」又会成立',
      );
      expect(
        body.contains('AppExitResponse.exit'),
        isTrue,
        reason: '不答 exit 就等于把退出请求卡住 ⇒ 用户 ⌘Q 关不掉 app',
      );
    });

    test('监听器在 dispose 注销', () {
      final int at = src.indexOf('void dispose() {');
      expect(at, greaterThan(-1));
      expect(
        src.substring(at, at + 500).contains('_exitRequestListener?.dispose()'),
        isTrue,
        reason: '不注销会把监听器留在 binding 上（热重载 / 重建后累积）',
      );
    });
  });
}
