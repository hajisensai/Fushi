import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-3321：Windows 选文件夹后几秒整个 app 0xC0000005 崩溃的源码守卫。
///
/// 根因在 file_picker 8.3.7 的 `getDirectoryPath()`：它在平台线程上用 win32 5.x
/// 的 COM 包装类，而这些包装类构造时自带 `Finalizer` 自动 `Release`。结果
/// `IShellItem` 被手动 `release()` 一次、Finalizer 再 release 一次，对话框最终
/// 释放时 `CFileOpenSave::_ClearResults` 读到已释放的 item（用户两份 dump 栈一致；
/// PageHeap 下旧实现必崩在 `IUnknown._finalizer → _release`，新实现不崩）。
///
/// 修复落在整文件覆盖补丁 `ci/patches/hosted/file_picker-<版本>/`，这里咬住三点：
/// ① 补丁目录版本 = lock 里的 file_picker 版本（升级后补丁会被静默跳过，bug 回归）；
/// ② 对话框跑在后台 isolate，不在平台线程上模态阻塞；
/// ③ 每个 COM 包装对象创建即 `detach()`，并且都有显式 `release()`。
void main() {
  final String repo = Directory(_fushiDir()).parent.path;
  final String lockedVersion = _lockedVersion(repo, 'file_picker');
  final String overlayPath =
      '$repo/ci/patches/hosted/file_picker-$lockedVersion/lib/src/windows/'
      'file_picker_windows.dart';

  test('locked file_picker version still has the Windows overlay', () {
    expect(
      File(overlayPath).existsSync(),
      isTrue,
      reason:
          'file_picker 升到 $lockedVersion 后没有对应的覆盖补丁：'
          'getDirectoryPath 的 COM 双重 Release（BUG-3321）会原样回来',
    );
  });

  test('getDirectoryPath runs the dialog off the platform thread', () {
    final String src = _read(overlayPath);
    final String body = _between(
      src,
      'Future<String?> getDirectoryPath(',
      'static String? pickDirectorySync(',
    );
    expect(body, contains('Isolate.run('));
    expect(body, isNot(contains('CoInitializeEx')));
    expect(body, isNot(contains('.show(')));
  });

  test('every COM wrapper is detached from its finalizer and released', () {
    final String src = _read(overlayPath);
    final String impl = _between(
      src,
      'static String? pickDirectorySync(',
      'static void _checkHr(',
    );
    final RegExp wrapper = RegExp(
      r'(IShellItem\([^)]*\)|FileOpenDialog\.createInstance\(\))',
    );
    final List<RegExpMatch> wrappers = wrapper.allMatches(impl).toList();
    expect(wrappers, isNotEmpty);
    for (final RegExpMatch m in wrappers) {
      expect(
        impl.substring(m.end).startsWith('..detach()'),
        isTrue,
        reason:
            '${m.group(0)} 必须立刻 ..detach()，否则 win32 的 Finalizer 会再 Release 一次',
      );
    }
    expect(
      RegExp(r'\.release\(\)').allMatches(impl).length,
      wrappers.length,
      reason: '每个 detach 掉的包装对象都要且只要显式 release 一次',
    );
    expect(impl, contains('CoUninitialize()'));
  });
}

String _between(String src, String start, String end) {
  final int a = src.indexOf(start);
  final int b = src.indexOf(end, a);
  expect(a, greaterThanOrEqualTo(0), reason: 'missing: $start');
  expect(b, greaterThan(a), reason: 'missing: $end');
  return src.substring(a, b);
}

String _lockedVersion(String repo, String package) {
  final List<String> lines = _read('$repo/pubspec.lock').split('\n');
  final int at = lines.indexOf('  $package:');
  if (at < 0) throw StateError('$package not in pubspec.lock');
  for (final String line in lines.skip(at + 1)) {
    final RegExpMatch? m = RegExp(r'^    version: "([^"]+)"').firstMatch(line);
    if (m != null) return m.group(1)!;
  }
  throw StateError('$package has no version in pubspec.lock');
}

String _fushiDir() {
  final Directory cwd = Directory.current;
  if (File('${cwd.path}/pubspec.yaml').existsSync() &&
      Directory('${cwd.path}/windows/runner').existsSync()) {
    return cwd.path;
  }
  return '${cwd.path}/fushi';
}

String _read(String path) =>
    File(path).readAsStringSync().replaceAll('\r\n', '\n');
