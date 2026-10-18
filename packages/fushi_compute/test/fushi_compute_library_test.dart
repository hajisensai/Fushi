// 库定位与加载：缺库抛带原因的异常；候选顺序；真实库 ABI 版本对得上。
//
// fushi_compute 是硬依赖：真实库那组**不 skip**，库找不到直接失败。库定位：环境变量
// FUSHI_COMPUTE_LIB，缺省由加载器在测试宿主下向上找本仓
// native/fushi_compute/prebuilt/<平台>/（先跑对应平台的 build_* 脚本）。
@TestOn('vm')
library;

import 'dart:io';

import 'package:fushi_compute/fushi_compute.dart';
import 'package:test/test.dart';

void main() {
  test('missing explicit library throws with the reason', () {
    expect(
      () =>
          FushiCompute.load(libraryPath: '/definitely/not/here/fushi_compute'),
      throwsA(
        isA<FushiComputeUnavailableError>().having(
          (FushiComputeUnavailableError e) => e.toString(),
          'message',
          allOf(contains('/definitely/not/here'), contains('not found')),
        ),
      ),
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
    // 正式可执行文件不从当前目录的上级找仓库 prebuilt。
    expect(c, hasLength(5));
  });

  test('only test hosts search the repository prebuilt directory', () {
    expect(FushiCompute.isTestHost('/sdk/bin/dart'), isTrue);
    expect(FushiCompute.isTestHost(r'C:\sdk\bin\dart.exe'), isTrue);
    expect(FushiCompute.isTestHost('/cache/flutter_tester'), isTrue);
    expect(FushiCompute.isTestHost(r'C:\app\fushi.exe'), isFalse);
    expect(FushiCompute.isTestHost('/opt/fushi/bin/fushi_server'), isFalse);
  });

  test('real library loads with the expected ABI', () {
    final FushiCompute lib = FushiCompute.require();
    expect(lib.providesSymbol('ffc_abi_version'), isTrue);
    expect(lib.providesSymbol('ffc_free_bytes'), isTrue);
    expect(lib.providesSymbol('ffc_no_such_symbol'), isFalse);
  });
}
