import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../helpers/source_guard.dart';

/// BUG-2081 守卫：Android Mihon 通道的回复只能从 `reply()` 一个出口走，
/// 出口把 `kotlin.Unit` 收口成 `null`，编不了的值转 error 回复。
///
/// `handle()` 是 `when` 表达式；分支若调的是没有返回类型的 Kotlin 函数
/// （`uninstall` / `clearSourceData` / `loader.invalidate` / `loader.clear`），
/// 表达式值就是 `kotlin.Unit` 单例。StandardMessageCodec 不认它，
/// `result.success(Unit)` 在主线程 Runnable 里抛 `IllegalArgumentException:
/// Unsupported value: 'kotlin.Unit'` 直接把进程带崩。用户可见症状：预览扩展
/// 失败/取消后 `_discardPreview` 走 `uninstallPrivateExtension` 崩一次，预览
/// 标记清不掉，之后每次进漫画 Discover/Import 初始化 MihonManager 时
/// `_recoverAbandonedPreview` 再崩一次，永久循环。
///
/// 仓库没有 Android JVM 单测基建，能落地的最强层是源码守卫。
void main() {
  late final String code = maskComments(
    File(
      'android/app/src/main/kotlin/app/fushi/reader/mihon/MihonChannelHandler.kt',
    ).readAsStringSync(),
  );
  const String replySignature =
      'private fun reply(result: MethodChannel.Result, value: Any?)';

  test('reply() 把 Unit 收口成 null，编码失败转 error 而不是让主线程裸奔', () {
    final String body = methodBody(code, replySignature);
    expect(
      RegExp(
        r'result\.success\(\s*if\s*\(value === Unit\)\s*null\s*else\s*value\s*\)',
      ).hasMatch(body),
      isTrue,
      reason:
          'reply() 丢了 `if (value === Unit) null else value`；'
          'void 分支会把 kotlin.Unit 送进 StandardMessageCodec 崩进程：\n$body',
    );
    expect(
      body.contains('catch (error: IllegalArgumentException)') &&
          body.contains('result.error("ENCODE_FAILED"'),
      isTrue,
      reason:
          'reply() 不再把编码失败转成 ENCODE_FAILED 回复；'
          'StandardMessageCodec 编不了的值会在主线程 Runnable 里抛未捕获异常：\n$body',
    );
  });

  // methodBody() 走的是 **Dart** 词法器（SourceLexicon 只有 dart/js）。Kotlin 的字符
  // 字面量 `'{'` / `'}'` 会被它当成 Dart 单引号串的开头，从而把后面的花括号一起掩掉、
  // 函数体窗口静默配对错位——本文件的所有断言会在一个错的窗口上「全绿」。今天这份 .kt
  // 里一个单引号都没有，把这个前提钉死：将来引入字符字面量时这条先响，而不是判据变哑。
  test('被扫的 .kt 不含单引号——Dart 词法器切 Kotlin 函数体的前提', () {
    expect(code.contains("'"), isFalse,
        reason: 'Kotlin 字符字面量会让 methodBody 的花括号配对错位，判据将静默失效；'
            '出现时应改用 Kotlin 词法器或换非词法锚点。');
  });

  test('result.success 只在 reply() 里出现，业务回复全部经 reply() 出口', () {
    final String replyBody = methodBody(code, replySignature);
    final String outside = code.replaceFirst(replyBody, '');
    expect(
      RegExp(
        r'mainHandler\.post\s*\{\s*reply\(result, value\)\s*\}',
      ).hasMatch(outside),
      isTrue,
      reason: 'register() 里的回复不再经 reply(result, value)，Unit 收口被绕过。',
    );
    // 接收者名**不能写死成 `result`**：本文件里已经有一个同形快路径
    // （cancelImageRequests 那处），照抄一份改成 `val res = result; res.success(...)`
    // 就重新引入 Unit 崩溃，而写死 `result\.` 的判据对它零命中（实测存活变异）。
    final Iterable<RegExpMatch> stray = RegExp(r'\.success\(([^)]*)\)')
        .allMatches(outside)
        .where((RegExpMatch call) => call.group(1)!.trim() != 'null');
    expect(
      stray.map((RegExpMatch call) => call.group(0)).toList(),
      isEmpty,
      reason: 'reply() 之外出现了带值的 <任意接收者>.success(...)，绕过了唯一出口。',
    );
  });
}
