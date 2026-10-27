/// macOS `AppDelegate` 的 `super.` 调用守卫（BUG-3856）。
///
/// 2026-10-28 的崩溃：打开系统访达（文件 / 文件夹选择面板）时切到别的 app 再切回来，
/// 应用直接 SIGABRT。崩溃报告里的原因是
/// `-[fushi.AppDelegate applicationDidBecomeActive:]: unrecognized selector`，
/// 而现场就是 `AppDelegate.swift` 的 `super.applicationDidBecomeActive(notification)`。
///
/// 为什么它会抛：`FlutterAppDelegate` 是纯 ObjC 的
/// `NSObject <NSApplicationDelegate, FlutterAppLifecycleProvider>`，它的方法表里只有
/// `applicationWillFinishLaunching:` / `application:openURLs:` /
/// `applicationShouldTerminate:` 三个 `NSApplicationDelegate` 方法（其余都是属性
/// getter/setter 与生命周期注册）。`applicationDidBecomeActive:` 等**只是协议声明、
/// 没有实现**，所以 `super.` 走 `objc_msgSendSuper2` 找不到方法就落到转发 → 抛
/// `NSInvalidArgumentException`。
///
/// 为什么平时不崩、只有访达面板开着才崩：这个异常每次激活 / 失活都在抛，普通事件循环
/// 里被 AppKit 记一条 `An uncaught exception was raised` 就吞掉了；而
/// `-[NSSavePanel runModal]` 的 `_NSTryRunModal` 会把模态循环里抓到的异常**重新抛出**
/// 给 `runModal()` 的调用方，`file_picker` 的 Swift 侧没有 catch，于是
/// `_objc_terminate` → abort。
///
/// 插件生命周期事件也不靠我们转发：`FlutterAppLifecycleRegistrar` 自己就是
/// `NSApplicationDidBecomeActiveNotification` 等通知的观察者（FlutterAppLifecycleDelegate.mm），
/// 注册到它的插件照常收到事件——所以正确的写法是**不调 super**，而不是补上实现。
///
/// 这类错误没有任何编译期信号（Swift 允许对「父类通过协议继承来的可选方法」写
/// `super.`），本机 Dart 测试也碰不到，只能靠这条静态守卫钉住。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

void main() {
  final String raw = File('macos/Runner/AppDelegate.swift').readAsStringSync();
  // 剥注释再判：本文件的注释里就写着 `super.applicationDidBecomeActive(...)` 这个
  // 反面例子，不剥的话守卫永远红。
  final String swift = maskComments(raw);

  /// `FlutterAppDelegate` **确实实现**、因此可以安全 `super.` 的 Swift 调用名。
  ///
  /// `application` 对应 ObjC 的 `application:openURLs:`（Swift 把
  /// `- (void)application:(NSApplication*)app openURLs:(NSArray<NSURL*>*)urls`
  /// 导入成 `application(_:open:)`），它是有实现的，转发给插件是对的。
  const Map<String, String> allowedSupers = <String, String>{
    'application': 'application:openURLs: —— FlutterAppDelegate 实现了，转发给插件',
  };

  test(
    'AppDelegate.swift 不得 super 调用 FlutterAppDelegate 没实现的 NSApplicationDelegate 方法',
    () {
      // 扫描面塌了（文件被改名 / 内容被搬走）时下面两条哨兵先红，而不是「零命中=绿」。
      expect(raw, contains('override func applicationDidBecomeActive'));
      expect(raw, contains('override func applicationDidFinishLaunching'));

      final RegExp superCall = RegExp(r'super\.([A-Za-z_][A-Za-z0-9_]*)');
      final List<String> offenders = <String>[];
      for (final RegExpMatch m in superCall.allMatches(swift)) {
        final String name = m.group(1)!;
        if (allowedSupers.containsKey(name)) continue;
        final int line =
            '\n'.allMatches(swift.substring(0, m.start)).length + 1;
        offenders.add('AppDelegate.swift:$line: super.$name(...)');
      }
      expect(
        offenders,
        isEmpty,
        reason:
            'FlutterAppDelegate 没实现这些 NSApplicationDelegate 方法，super 调用会抛 '
            'unrecognized selector（访达面板开着时必崩，BUG-3856）。删掉 super 调用即可——'
            '插件生命周期事件由 FlutterAppLifecycleRegistrar 自己的通知观察者分发：\n'
            '${offenders.join('\n')}',
      );
    },
  );
}
