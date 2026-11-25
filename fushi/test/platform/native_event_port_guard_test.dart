import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// 守卫（BUG-5413 / 反馈 Wgbo462Sfc）：活得比 Dart isolate 久的原生代码不拿 Dart 函数指针。
///
/// Android 上 audio_service 在 Activity 走后同步 `FlutterEngine.destroy()`，主 isolate 的
/// `NativeCallable` 跳板随之被删，而进程、libmpv 播放器和 fushi_compute 的进程级引擎都还活着：
/// 它们再回调一次就是 `Callback invoked after it has been deleted` → SIGABRT。Dart 侧没有可挂的
/// 同步时机先摘回调，所以修法是机制本身：事件一律投 Dart 原生端口（`Dart_PostCObject`）。
///
/// 这套修法有两处一删就悄悄退回崩溃、而功能测试照样全绿的地方，这里钉住（fushi_compute 的 Dart
/// 绑定不建 `NativeCallable` 由 `packages/fushi_compute/test/native_lifetime_guard_test.dart` 守）：
/// - `main.dart` 必须在 `MediaKit.ensureInitialized()` 之后装 `useNativePortWakeup(...)`——
///   不装时 media_kit 覆盖补丁回落到上游的 `NativeCallable.listener`，播放照常；
/// - fushi_compute 的 Rust 导出不再收函数指针回调（`extern "C" fn` 形参 / 类型别名），新域照抄
///   旧写法也会被拦下。
void main() {
  // 测试 cwd 是 `fushi/`。
  String read(String path) {
    final File file = File(path);
    expect(file.existsSync(), isTrue, reason: '${file.absolute.path} 不存在');
    return file.readAsStringSync().replaceAll('\r\n', '\n');
  }

  test('main.dart 在 MediaKit 初始化后、同一启动段里装 libmpv 端口唤醒', () {
    final String? body = topLevelFunctionBody(read('lib/main.dart'), 'main');
    expect(body, isNotNull, reason: 'main.dart 找不到顶层 main');
    final String code = maskComments(body!);
    final RegExpMatch? init = identifierCall(
      'MediaKit.ensureInitialized',
      allowNamedConstructor: false,
    ).firstMatch(code);
    final RegExpMatch? install = identifierCall(
      'useNativePortWakeup',
      allowNamedConstructor: false,
    ).firstMatch(code);
    expect(init, isNotNull, reason: 'main 里没有 MediaKit.ensureInitialized()');
    expect(
      install,
      isNotNull,
      reason:
          'main 里没装 useNativePortWakeup()：media_kit 会回落到 NativeCallable 唤醒，'
          'Android 引擎销毁后 libmpv 再唤醒就整进程 abort（BUG-5413）',
    );
    expect(
      install!.start,
      greaterThan(init!.start),
      reason: '端口唤醒要紧跟 MediaKit.ensureInitialized()，在建第一个播放器之前装',
    );
  });

  test('fushi_compute 的 Rust 导出不收函数指针回调（事件走 dart_port.rs）', () {
    // `Option<extern "C" fn ...>` 形参与 `type X = extern "C" fn ...` 别名是「把 Dart 函数指针交给
    // 原生」的两种写法。唯一例外是 dart_port.rs 的 `PostCObjectFn`：它是 VM 导出的
    // `Dart_PostCObject`（进程内永久有效），不是 Dart 跳板。
    final RegExp alias = RegExp(
      r'type\s+(\w+)\s*=\s*(?:unsafe\s+)?extern\s+"C"\s+fn',
    );
    final RegExp optionalFn = RegExp(
      r'Option\s*<\s*(?:unsafe\s+)?extern\s+"C"\s+fn',
    );
    final List<String> offenders = <String>[];
    final List<File> sources = Directory('../native/fushi_compute/src')
        .listSync(recursive: true)
        .whereType<File>()
        .where((File f) => f.path.endsWith('.rs'))
        .toList();
    expect(sources, isNotEmpty);
    for (final File file in sources) {
      final String code = maskComments(
        file.readAsStringSync().replaceAll('\r\n', '\n'),
      );
      for (final RegExpMatch m in alias.allMatches(code)) {
        if (m.group(1) != 'PostCObjectFn') {
          offenders.add('${file.path}: ${m[0]}');
        }
      }
      for (final RegExpMatch m in optionalFn.allMatches(code)) {
        offenders.add('${file.path}: ${m[0]}');
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          '原生 → Dart 事件改投 Dart 原生端口（DartPort / ffc_port_wakeup），不要再收 '
          'NativeCallable 函数指针（BUG-5413）',
    );
  });
}
