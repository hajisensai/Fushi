import 'dart:io';

import 'package:fushi_srs/src/ffi/fushi_fsrs_library.dart';
import 'package:fushi_srs/src/search/anki_search.dart';
import 'package:test/test.dart';

/// 本仓构建脚本的默认产物路径（相对 packages/fushi_srs）。
String _defaultPrebuiltPath() {
  final String sep = Platform.pathSeparator;
  final String root = '..$sep..${sep}native${sep}fushi_fsrs${sep}prebuilt';
  if (Platform.isWindows) return '$root${sep}windows-x64${sep}fushi_fsrs.dll';
  if (Platform.isMacOS) return '$root${sep}macos${sep}libfushi_fsrs.dylib';
  return '$root${sep}linux-x64${sep}libfushi_fsrs.so';
}

/// 搜索求值只有原生实现：库加载失败直接让测试红（不 skip——skip 会让「搜索整个不可用」显示成绿）。
FushiFsrs requireSearchLibrary() {
  final String? env = Platform.environment[kFushiFsrsLibEnv];
  final String path = env != null && env.isNotEmpty
      ? env
      : File(_defaultPrebuiltPath()).absolute.path;
  final FushiFsrs? lib = FushiFsrs.tryLoad(libraryPath: path);
  if (lib == null) {
    throw StateError(
      'fushi_fsrs native library not loadable at $path '
      '(build it with native/fushi_fsrs/build_*.{ps1,sh} or set $kFushiFsrsLibEnv)',
    );
  }
  return lib;
}

Matcher throwsSearch(SrsSearchErrorKind kind) => throwsA(
  isA<SrsSearchUnsupported>().having(
    (SrsSearchUnsupported e) => e.kind,
    'kind',
    kind,
  ),
);
