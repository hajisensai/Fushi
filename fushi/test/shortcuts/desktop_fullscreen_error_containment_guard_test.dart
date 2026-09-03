/// 桌面窗口全屏读写的**错误收容**守卫。
///
/// `readDesktopWindowFullscreen` / `setDesktopWindowFullscreen` 的每个平台分支都
/// 包在 try/catch 里，目的只有一个：platform channel 不可用时安静地返回 null，
/// 因为调用点是 `unawaited(...)`——逃出去的异常没有任何人接。
///
/// 但 async 函数里 `return <future>;` **不会**被外层 try/catch 收住：try 块在该
/// future 完成之前就已经退出了，只有 `return await <future>;` 才会。历史上
/// Linux / macOS 两个分支正是裸 return，于是：
///
///   - Windows（分支里有 await）：channel 缺失 → TypeError 被 catch → 返回 null，
///     漫画页照常渲染，本机测试恒绿；
///   - Linux（分支里没有 await）：同一个 TypeError 逃出 catch → initState 里的
///     `unawaited(_readInitialFullscreenState())` 变成未处理的 zone 异常 →
///     **每一条挂载漫画页的 widget test 在 Linux CI 上全红**，而报错只有一句
///     "Test failed. See exception logs above."。
///
/// 这条守卫钉的是不变式（异常必须留在 try 里），不是某个方法名。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

void main() {
  group('desktop fullscreen error containment', () {
    test('平台分支一律 `return await`，异常不得逃出 try', () {
      final String source = maskComments(
        File('lib/src/shortcuts/global_navigation.dart').readAsStringSync(),
      );

      // 先证明判据落在真实代码上：锚点没了就是改名 / 搬家，守卫不能静默变空转。
      expect(
        source,
        contains('Future<bool?> readDesktopWindowFullscreen()'),
        reason: '锚点函数不见了——守卫失去判据，请跟着改名更新',
      );
      expect(
        source,
        contains('Future<bool?> setDesktopWindowFullscreen('),
        reason: '锚点函数不见了——守卫失去判据，请跟着改名更新',
      );
      expect(
        RegExp(r'return\s+await\s+(windowManager|WindowManipulator)\.')
            .allMatches(source)
            .length,
        greaterThanOrEqualTo(3),
        reason: '这些分支本来就该直接返回原生读数，一条都没有说明结构已经变了',
      );

      final List<String> bare = RegExp(
        r'return\s+(?!await\b)(windowManager|WindowManipulator)\.[A-Za-z]+\(',
      ).allMatches(source).map((RegExpMatch m) => m.group(0)!).toList();

      expect(
        bare,
        isEmpty,
        reason: 'async 函数里裸 `return <future>` 不受外层 try/catch 保护；'
            '这些分支存在的唯一目的就是吞掉 channel 失败，逃出去就等于没吞。'
            '写成 `return await ...`。',
      );
    });

    test('Dart 语义前提：裸 return 逃出 try，return await 不会', () async {
      // 守卫的判据建立在这条语义上，所以把它也钉住：哪天语言变了，这里先红，
      // 而不是等到 CI 上出现一堆无从解释的红。
      Future<int> boom() async => throw StateError('boom');

      Future<int?> bare() async {
        try {
          return boom();
        } catch (_) {
          return null;
        }
      }

      Future<int?> awaited() async {
        try {
          return await boom();
        } catch (_) {
          return null;
        }
      }

      await expectLater(bare(), throwsStateError);
      expect(await awaited(), isNull);
    });
  });
}
