import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../helpers/source_guard.dart';

/// BUG-2081 守卫：Android Mihon 通道的 void 方法必须回 `null`，不能把
/// `kotlin.Unit` 塞给 `result.success`。
///
/// `dispatch()` 是 `when` 表达式；分支若调的是没有返回类型的 Kotlin 函数
/// （`uninstall` / `clearSourceData` / `loader.invalidate` / `loader.clear`），
/// 表达式值就是 `kotlin.Unit` 单例。StandardMessageCodec 不认它，
/// `result.success(Unit)` 在主线程抛 `IllegalArgumentException: Unsupported
/// value: 'kotlin.Unit'` 直接把进程带崩。用户可见症状：预览扩展失败/取消后
/// `_discardPreview` 走 `uninstallPrivateExtension` 崩一次，预览标记清不掉，
/// 之后每次进漫画 Discover/Import 初始化 MihonManager 时
/// `_recoverAbandonedPreview` 再崩一次，永久循环。
///
/// 仓库没有 Android JVM 单测基建，能落地的最强层是源码守卫：钉住
/// 「回复只经 `handle()` 出口，`handle()` 把 Unit 收口成 null」。
void main() {
  late final String code = maskComments(
    File(
      'android/app/src/main/kotlin/app/fushi/reader/mihon/MihonChannelHandler.kt',
    ).readAsStringSync(),
  );

  test('handle() 把 dispatch() 的 Unit 收口成 null', () {
    final String body = _handleBody(code);
    expect(
      body.contains('dispatch(call)'),
      isTrue,
      reason: 'handle() 不再经 dispatch() 取值，守卫锚点漂了：\n$body',
    );
    expect(
      RegExp(r'===\s*Unit\)\s*null').hasMatch(body),
      isTrue,
      reason:
          'handle() 丢了 `if (value === Unit) null else value`；'
          'void 分支会把 kotlin.Unit 送进 StandardMessageCodec 崩进程：\n$body',
    );
  });

  test('MethodChannel 回复只走 handle()，实参只能是 null 或收口后的 value', () {
    expect(
      code.contains('val value = handle(call)'),
      isTrue,
      reason: 'register() 里回复值不再来自 handle(call)，Unit 收口被绕过。',
    );
    final Iterable<RegExpMatch> calls = RegExp(
      r'result\.success\(([^)]*)\)',
    ).allMatches(code);
    expect(calls, isNotEmpty, reason: '找不到任何 result.success(...) 调用');
    for (final RegExpMatch call in calls) {
      final String argument = call.group(1)!.trim();
      expect(
        argument == 'null' || argument == 'value',
        isTrue,
        reason:
            'result.success($argument) 绕过了 handle() 的 Unit 收口；'
            '所有回复必须经 handle() 出口。',
      );
    }
  });
}

/// 截出 `private fun handle(` 到 `private fun dispatch(` 之间的函数体。
String _handleBody(String source) {
  const String start = 'private fun handle(call: MethodCall): Any?';
  const String end = 'private fun dispatch(call: MethodCall): Any?';
  final int from = source.indexOf(start);
  final int to = source.indexOf(end);
  if (from < 0 || to < 0 || to < from) {
    fail('MihonChannelHandler.kt 里找不到相邻的 handle()/dispatch() 声明');
  }
  return source.substring(from, to);
}
