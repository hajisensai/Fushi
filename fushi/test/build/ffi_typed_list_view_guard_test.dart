import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/scan_scale.dart';

/// `Pointer.asTypedList` 只能经 `package:fushi_ffi_view` 的 `asTypedListOutOfLine` 调。
///
/// Dart VM（JIT）会把只在本函数里按下标读写的 asTypedList 视图做分配下沉；函数在视图
/// 存活期间去优化时，物化出来的外部 typed data 数据指针是 Smi 标记过的地址（真地址 × 2），
/// 下一次读写 SIGSEGV。`--experimental-faster-testing` 下所有 suite 共用一个 isolate
/// group 的 JIT 状态，fushi_compute 的 `Utf16BatchBuffer.fill` 就这样把 flutter_tester
/// 打成 exit 245（PR #2422 撤回 faster-testing 的原因）。复现与清理条件见
/// `packages/fushi_ffi_view/lib/fushi_ffi_view.dart` 与它的 canary 测试。
///
/// 本守卫扫本仓自有 Dart 源码（app 的 lib / test / integration_test / tool，自有包的
/// lib / test / bin / tool）。vendored / fork 包与 `ci/patches/` 下的上游补丁不在范围内。
void main() {
  // 拆开写，免得本文件自己命中。
  const String raw =
      '.asTyped'
      'List(';
  const Set<String> notOwned = <String>{
    'flutter_inappwebview_linux',
    'flutter_inappwebview_windows',
    'gamepads_android_stub',
    'gamepads_windows',
    // 唯一允许直接调用的地方。
    'fushi_ffi_view',
  };

  List<Directory> roots() {
    final List<Directory> out = <Directory>[
      for (final String d in <String>[
        'lib',
        'test',
        'integration_test',
        'tool',
      ])
        Directory(d),
    ];
    for (final FileSystemEntity pkg in Directory('../packages').listSync()) {
      if (pkg is! Directory) continue;
      final String name = pkg.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (notOwned.contains(name)) continue;
      for (final String d in <String>['lib', 'test', 'bin', 'tool']) {
        out.add(Directory('${pkg.path}/$d'));
      }
    }
    return out.where((Directory d) => d.existsSync()).toList();
  }

  test('no raw Pointer.asTypedList outside package:fushi_ffi_view', () {
    int scanned = 0;
    final List<String> offenders = <String>[];
    for (final Directory root in roots()) {
      for (final FileSystemEntity e in root.listSync(recursive: true)) {
        if (e is! File || !e.path.endsWith('.dart')) continue;
        scanned++;
        final List<String> lines = e.readAsLinesSync();
        for (int i = 0; i < lines.length; i++) {
          if (lines[i].contains(raw)) {
            offenders.add('${e.path.replaceAll('\\', '/')}:${i + 1}');
          }
        }
      }
    }
    expectScanScale(
      scanned,
      what: 'own Dart sources (fushi/ + packages/)',
      atLeast: 6600,
      measured: 8261,
    );
    expect(
      offenders,
      isEmpty,
      reason:
          'Use asTypedListOutOfLine from package:fushi_ffi_view instead of '
          'Pointer.asTypedList (JIT deopt mis-materializes sunk views; see '
          'packages/fushi_ffi_view/lib/fushi_ffi_view.dart).',
    );
  });

  test('every helper keeps its view creation out of line', () {
    final String source = File(
      '../packages/fushi_ffi_view/lib/fushi_ffi_view.dart',
    ).readAsStringSync();
    final RegExp helper = RegExp(
      r"@pragma\('vm:never-inline'\)\s+(\w+List) asTypedListOutOfLine\(int length\) =>\s+asTypedList\(length\);",
    );
    final Set<String> covered = helper
        .allMatches(source)
        .map((RegExpMatch m) => m.group(1)!)
        .toSet();
    // 每种 asTypedList 支持的元素类型都要有（缺一个，调用方只能回退到裸调用）。
    expect(covered, <String>{
      'Int8List',
      'Int16List',
      'Int32List',
      'Int64List',
      'Uint8List',
      'Uint16List',
      'Uint32List',
      'Uint64List',
      'Float32List',
      'Float64List',
    });
    expect(
      RegExp('asTypedListOutOfLine').allMatches(source).length,
      covered.length,
      reason: 'every asTypedListOutOfLine must carry vm:never-inline',
    );
  });
}
