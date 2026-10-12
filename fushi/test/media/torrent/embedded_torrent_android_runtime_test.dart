// BUG-3284：Android 内置下载引擎在发布包里「.so 在、却被判缺少运行库」。
//
// 根因：libfushi_torrent_ffi.so 以 ANDROID_STL=c++_shared 链接，依赖 APK 里唯一那份
// libc++_shared.so；那份由 Gradle pickFirst 从插件 AAR 里挑（实测 NDK r27-beta1），
// 而本库用 CI runner 的最新 NDK（r30）编，引用了老 libc++ 里没有的
// std::__ndk1::__hash_memory → 设备上 dlopen 失败 → probeAvailable 判 false。
// 失败原因又被 probeAvailable 整个吞掉，用户日志里一个字都没有。
//
// 本文件守两件事：
// 1. 构建契约：Android .so 必须 c++_static + --exclude-libs，且两条构建它的
//    workflow 都调用「C++ 运行时自包含」产物校验（文本守卫，任何 CI 都能跑）；
// 2. 运行时契约：probeAvailable 失败必须留下原因（lastProbeFailure + 日志）。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/media/torrent/embedded_torrent_host.dart';

class _RecordingSink implements EngineLogSink {
  final List<String> sources = <String>[];

  @override
  void log(String source, Object error, [StackTrace? stack]) =>
      sources.add(source);

  @override
  void logDiagnostic(String source, Object info) => sources.add(source);

  @override
  void logFatal(String source, Object error, [StackTrace? stack]) =>
      sources.add(source);
}

String _read(String repoRelative) =>
    File('../$repoRelative').readAsStringSync();

/// 去掉 `#` 行注释（cmake / shell / PowerShell），只看真正生效的代码。
String _stripHashComments(String text) => text
    .split('\n')
    .map((String line) {
      final int hash = line.indexOf('#');
      return hash < 0 ? line : line.substring(0, hash);
    })
    .join('\n');

void main() {
  group('BUG-3284 Android .so 自带 C++ 运行时（构建契约）', () {
    for (final String script in <String>[
      'native/fushi_torrent/build_android_so.sh',
      'native/fushi_torrent/build_android_so.ps1',
    ]) {
      test('$script 用 c++_static，不再链 libc++_shared', () {
        final String code = _stripHashComments(_read(script));
        expect(
          code.contains('-DANDROID_STL=c++_static'),
          isTrue,
          reason:
              '依赖 APK 里那份 libc++_shared 时，新 NDK 编出的 .so 会 '
              'dlopen 失败（BUG-3284）',
        );
        expect(code.contains('c++_shared'), isFalse);
      });
    }

    test('CMakeLists 的 Android 分支隐藏静态归档符号', () {
      final String code = _stripHashComments(
        _read('native/fushi_torrent/CMakeLists.txt'),
      );
      final int start = code.indexOf('if(ANDROID)');
      expect(start, isNonNegative);
      final int end = code.indexOf('endif()', start);
      final String android = code.substring(start, end);
      expect(
        android.contains('-Wl,--exclude-libs,ALL'),
        isTrue,
        reason:
            '静态链入的 libc++ 不得进动态符号表，否则会与插件自带的 '
            'libc++_shared 互相插桩',
      );
    });

    for (final String workflow in <String>[
      '.github/workflows/release.yml',
      '.github/workflows/native-torrent-gate.yml',
    ]) {
      test('$workflow 校验 .so 的 C++ 运行时自包含', () {
        final String code = _stripHashComments(_read(workflow));
        expect(
          code.contains(
            'bash .github/scripts/verify_android_cxx_self_contained.sh "\$so"',
          ),
          isTrue,
          reason: '只验「文件在 + ht_* 导出齐」挡不住 dlopen 期的未定义符号',
        );
      });
    }

    test('校验脚本只放行系统库依赖与 bionic 版本符号', () {
      final String code = _stripHashComments(
        _read('.github/scripts/verify_android_cxx_self_contained.sh'),
      );
      expect(code.contains(r"grep -vxE 'libc\.so|libm\.so|libdl\.so'"), isTrue);
      expect(code.contains("grep -v '@LIBC'"), isTrue);
      expect(code.contains('exit 1'), isTrue);
    });
  });

  group('BUG-3284 probeAvailable 失败留下原因（运行时契约）', () {
    late EngineLogSink saved;

    setUp(() {
      saved = engineLog;
      EmbeddedTorrentHost.resetAvailabilityProbeForTesting();
    });

    tearDown(() {
      engineLog = saved;
      EmbeddedTorrentHost.resetAvailabilityProbeForTesting();
    });

    test('库加载失败：返回 false、记下错误文本并写日志', () {
      final _RecordingSink sink = _RecordingSink();
      engineLog = sink;
      final String missing =
          '${Directory.systemTemp.path}'
          '/fushi_no_such_dir_bug3284/libfushi_torrent_ffi_missing.so';

      expect(EmbeddedTorrentHost.probeAvailable(libraryPath: missing), isFalse);
      expect(EmbeddedTorrentHost.lastProbeFailure, isNotNull);
      expect(
        EmbeddedTorrentHost.lastProbeFailure,
        contains('libfushi_torrent_ffi_missing'),
      );
      expect(sink.sources, <String>['EmbeddedTorrentHost.probeAvailable']);
    });

    test('reset 同时清掉失败原因', () {
      engineLog = _RecordingSink();
      EmbeddedTorrentHost.probeAvailable(
        libraryPath: '${Directory.systemTemp.path}/nope_bug3284.so',
      );
      expect(EmbeddedTorrentHost.lastProbeFailure, isNotNull);
      EmbeddedTorrentHost.resetAvailabilityProbeForTesting();
      expect(EmbeddedTorrentHost.lastProbeFailure, isNull);
    });
  });
}
