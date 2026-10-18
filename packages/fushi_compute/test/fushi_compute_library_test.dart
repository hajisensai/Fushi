// 库定位与加载：缺库不可用且不抛；候选顺序；有真实库时 ABI 版本对得上。
//
// 库定位：环境变量 FUSHI_COMPUTE_LIB，缺省用本仓 native/fushi_compute/prebuilt/<平台>/ 下
// 构建脚本的产物。库不可用时真实库那组 skip 并打印 'native library not found'
// （CI 用它断言没有被静默跳过，与 fushi_fsrs / fushi_p2p 同一约定）。
@TestOn('vm')
library;

import 'dart:io';

import 'package:fushi_compute/fushi_compute.dart';
import 'package:test/test.dart';

String _defaultPrebuiltPath() {
  final String sep = Platform.pathSeparator;
  final String root = '..$sep..${sep}native${sep}fushi_compute${sep}prebuilt';
  if (Platform.isWindows) {
    return '$root${sep}windows-x64${sep}fushi_compute.dll';
  }
  if (Platform.isMacOS) return '$root${sep}macos${sep}libfushi_compute.dylib';
  return '$root${sep}linux-x64${sep}libfushi_compute.so';
}

String _libraryPath() {
  final String? env = Platform.environment[kFushiComputeLibEnv];
  if (env != null && env.isNotEmpty) return env;
  return File(_defaultPrebuiltPath()).absolute.path;
}

void main() {
  test('missing library => unavailable, never throws', () {
    expect(
      FushiCompute.tryLoad(libraryPath: '/definitely/not/here/fushi_compute'),
      isNull,
    );
  });

  test('candidate order: explicit, env, exe dir, bin/../lib, bare name', () {
    final String sep = Platform.pathSeparator;
    final String exe = '${sep}app${sep}bin${sep}fushi_server';
    final List<String> c = FushiCompute.libraryCandidates(
      libraryPath: 'explicit',
      environment: <String, String>{kFushiComputeLibEnv: 'from-env'},
      executablePath: exe,
    );
    final String name = FushiCompute.defaultLibraryName();
    expect(c.first, 'explicit');
    expect(c[1], 'from-env');
    expect(c[2], '${sep}app${sep}bin$sep$name');
    expect(c[3], endsWith('lib$sep$name'));
    expect(c.last, name);
  });

  final FushiCompute? lib = FushiCompute.tryLoad(libraryPath: _libraryPath());
  final String? skipReason = lib == null
      ? 'native library not found: ${_libraryPath()}'
      : null;
  if (skipReason != null) {
    // ignore: avoid_print
    print('SKIP: $skipReason');
  }

  group('FushiCompute (real native library)', skip: skipReason, () {
    test('loads with the expected ABI and resolves only real symbols', () {
      expect(lib, isNotNull);
      expect(lib!.providesSymbol('ffc_abi_version'), isTrue);
      expect(lib.providesSymbol('ffc_free_bytes'), isTrue);
      expect(lib.providesSymbol('ffc_no_such_symbol'), isFalse);
    });
  });
}
