import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-2838：Windows 版长时间运行（3.5~7 小时）后被
/// `flutter_local_notifications_windows.dll` 里未捕获的 C++ 异常整进程打死
/// （HRESULT 0x800401FD CO_E_OBJNOTCONNECTED，minidump 证实）。
///
/// 根因两层，补丁在 `ci/patches/hosted/flutter_local_notifications_windows-2.0.1/src/`：
///
/// 1. 上游 `init()` 把 `ToastNotifier`（跨进程 COM 代理）与 `History` 缓存一辈子；
///    通知平台服务重启 / 会话变化后代理断开，之后每次 `Show()` 都抛。补丁删掉
///    这份缓存状态，每次调用现取。
/// 2. 所有 FFI 导出函数都没有 catch，C++ 异常越过 FFI 边界——Dart 的 try/catch
///    抓不到，运行时直接 terminate。补丁让每个导出函数把任何异常转成它既有的
///    失败返回值。
///
/// 这两条都是「补丁文件里的源码事实」，C++ 不在任何 Dart 测试的编译面上，所以
/// 用源码扫描钉住：有人从上游重新拷一份 ffi_api.cpp 覆盖补丁、或给插件新加一个
/// 导出函数忘了包边界，这里立刻红。
void main() {
  /// 测试 cwd 恒为 `fushi/`，仓库根是它的父目录（别往上找 .git，worktree 里会
  /// 爬到主 checkout）。
  final Directory repoRoot = Directory.current.parent;
  const String patchDir =
      'ci/patches/hosted/flutter_local_notifications_windows-2.0.1/src';

  File repoFile(String relative) => File('${repoRoot.path}/$relative');

  /// 去掉 `//` 行注释与 `/* */` 块注释（本文件不含带 `//` 的字符串字面量）。
  String stripComments(String source) => source
      .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '')
      .replaceAll(RegExp(r'//[^\n]*'), '');

  /// 从 [open]（必须指向 `{`）开始做括号配对，返回配对的 `}` 下标。
  int matchBrace(String source, int open) {
    int depth = 0;
    for (int i = open; i < source.length; i++) {
      final String c = source[i];
      if (c == '{') depth++;
      if (c == '}' && --depth == 0) return i;
    }
    throw StateError('unbalanced braces from offset $open');
  }

  /// 上游头文件里声明的全部导出函数名。头文件不打补丁，取 pub cache 里的原件
  /// 不稳定（CI 上路径不同），所以从补丁 cpp 的签名反推的同时，用固定清单兜底。
  const List<String> upstreamExports = <String>[
    'hasPackageIdentity',
    'isValidXml',
    'createPlugin',
    'disposePlugin',
    'init',
    'showNotification',
    'scheduleNotification',
    'updateNotification',
    'cancelAll',
    'cancelNotification',
    'getActiveNotifications',
    'getPendingNotifications',
    'freeDetailsArray',
    'freeLaunchDetails',
  ];

  /// 顶层（列 0 起头、不在匿名 namespace 里）的函数定义：名字 → 函数体
  /// （含首尾花括号）。
  Map<String, String> topLevelDefinitions(String source) {
    String code = stripComments(source);
    // 匿名 namespace 里是内部 helper，不是导出面：整块剔除。
    for (
      int at = code.indexOf(RegExp(r'^namespace\s*\{', multiLine: true));
      at >= 0;
      at = code.indexOf(RegExp(r'^namespace\s*\{', multiLine: true))
    ) {
      final int close = matchBrace(code, code.indexOf('{', at));
      code = code.substring(0, at) + code.substring(close + 1);
    }
    final Map<String, String> bodies = <String, String>{};
    final RegExp signature = RegExp(
      r'^[A-Za-z_][\w\s\*:<>]*?\b(\w+)\(',
      multiLine: true,
    );
    int cursor = 0;
    while (true) {
      final RegExpMatch? m = signature.firstMatch(code.substring(cursor));
      if (m == null) break;
      final int start = cursor + m.start;
      final int open = code.indexOf('{', start);
      final int semicolon = code.indexOf(';', start);
      if (open < 0) break;
      final int close = matchBrace(code, open);
      final bool isDeclaration = semicolon >= 0 && semicolon < open;
      if (!isDeclaration) {
        bodies[m.group(1)!] = code.substring(open, close + 1);
      }
      cursor = isDeclaration ? semicolon + 1 : close + 1;
    }
    return bodies;
  }

  /// 函数体是否整个包在 `try { … } catch (…) { … }` 里、且最后有 `catch (...)`
  /// 兜住一切——try 前、catch 后都不许有语句（那些语句就在边界外）。
  bool isFullyGuarded(String body) {
    final String inner = body.substring(1, body.length - 1).trim();
    if (!inner.startsWith('try')) return false;
    final int tryOpen = inner.indexOf('{');
    if (inner.substring(3, tryOpen).trim().isNotEmpty) return false;
    int cursor = matchBrace(inner, tryOpen) + 1;
    bool catchesAll = false;
    while (true) {
      final String rest = inner.substring(cursor).trimLeft();
      if (rest.isEmpty) return catchesAll;
      final RegExpMatch? clause = RegExp(
        r'^catch\s*\(([^)]*)\)\s*\{',
      ).firstMatch(rest);
      if (clause == null) return false;
      catchesAll = clause.group(1)!.trim() == '...';
      final int offset = inner.length - rest.length;
      cursor = matchBrace(inner, offset + clause.end - 1) + 1;
    }
  }

  final File ffiApi = repoFile('$patchDir/ffi_api.cpp');
  final File pluginHpp = repoFile('$patchDir/plugin.hpp');

  test('补丁目录的版本就是 lock 里解析到的版本（否则 apply-patches 静默跳过）', () {
    final String lock = repoFile('pubspec.lock').readAsStringSync();
    final RegExpMatch? entry = RegExp(
      r'\n  flutter_local_notifications_windows:\n(?:    .*\n)*?    version: "([^"]+)"',
    ).firstMatch(lock);
    expect(entry, isNotNull, reason: 'pubspec.lock 里找不到该包');
    expect(entry!.group(1), '2.0.1');
    expect(ffiApi.existsSync(), isTrue);
    expect(pluginHpp.existsSync(), isTrue);
  });

  test('不再缓存 ToastNotifier / History（断开的 COM 代理就是崩溃源）', () {
    final String hpp = stripComments(pluginHpp.readAsStringSync());
    final String cpp = stripComments(ffiApi.readAsStringSync());
    expect(
      hpp,
      isNot(contains('ToastNotifier>')),
      reason: 'NativePlugin 不得持有 ToastNotifier',
    );
    expect(
      hpp,
      isNot(contains('ToastNotificationHistory>')),
      reason: 'NativePlugin 不得持有 ToastNotificationHistory',
    );
    expect(
      cpp,
      isNot(matches(RegExp(r'->\s*(notifier|history)\b'))),
      reason: 'ffi_api.cpp 不得再用缓存的 notifier / history',
    );
    expect(cpp, contains('CreateToastNotifier'), reason: '每次调用现取 notifier');
    expect(
      cpp,
      isNot(contains('stoi')),
      reason: 'std::stoi 遇到非数字 tag 抛 invalid_argument',
    );
  });

  test('每个 FFI 导出函数整个包在 try { } catch (...) { } 里', () {
    final Map<String, String> defs = topLevelDefinitions(
      ffiApi.readAsStringSync(),
    );
    expect(
      defs.keys.toSet(),
      containsAll(upstreamExports),
      reason: '补丁 cpp 缺了导出函数定义',
    );
    final List<String> unguarded = <String>[
      for (final MapEntry<String, String> def in defs.entries)
        if (!isFullyGuarded(def.value)) def.key,
    ];
    expect(unguarded, isEmpty, reason: '这些导出函数的异常会越过 FFI 边界直接 terminate 进程');
  });
}
