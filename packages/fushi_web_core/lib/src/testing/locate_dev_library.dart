import 'dart:io';

import '../fushi_web_core_library.dart';

/// 仓库里 fushi_web_core 原生库的开发产物路径：`FUSHI_WEB_CORE_LIB` 优先，否则从
/// [start]（缺省当前目录）向上找 `native/fushi_web_core`，依次看
/// `target/release/`、`prebuilt/<平台>/`。都没有返回 null。
String? locateDevFushiWebCoreLibrary({Directory? start}) {
  final String? fromEnv = Platform.environment[kFushiWebCoreLibEnv];
  if (fromEnv != null && fromEnv.isNotEmpty) return fromEnv;
  final String name = FushiWebCoreLibrary.defaultLibraryName();
  final String platformDir = Platform.isWindows
      ? 'windows-x64'
      : Platform.isMacOS
      ? 'macos'
      : 'linux-x64';
  Directory? dir = (start ?? Directory.current).absolute;
  while (dir != null) {
    final Directory crate = Directory('${dir.path}/native/fushi_web_core');
    if (crate.existsSync()) {
      for (final String rel in <String>[
        'target/release/$name',
        'prebuilt/$platformDir/$name',
      ]) {
        final File f = File('${crate.path}/$rel');
        if (f.existsSync()) return f.absolute.path;
      }
      return null;
    }
    final Directory parent = dir.parent;
    dir = parent.path == dir.path ? null : parent;
  }
  return null;
}

/// 测试入口调一次：找到开发产物就设成 [FushiWebCoreLibrary.overridePath]。找不到不在这里报错
/// ——第一次真用到库时 [FushiWebCoreLibrary.load] 会抛 [FushiWebCoreLibraryMissing]，测试照常
/// 失败（原生库是硬依赖，测试不 skip）。
void useDevFushiWebCoreLibrary({Directory? start}) {
  FushiWebCoreLibrary.overridePath ??= locateDevFushiWebCoreLibrary(
    start: start,
  );
}

/// 仓库里的回归向量目录（`native/fushi_web_core/tests/vectors`）；找不到返回 null。
Directory? locateWebCoreVectors({Directory? start}) {
  Directory? dir = (start ?? Directory.current).absolute;
  while (dir != null) {
    final Directory v = Directory(
      '${dir.path}/native/fushi_web_core/tests/vectors',
    );
    if (v.existsSync()) return v;
    final Directory parent = dir.parent;
    dir = parent.path == dir.path ? null : parent;
  }
  return null;
}
