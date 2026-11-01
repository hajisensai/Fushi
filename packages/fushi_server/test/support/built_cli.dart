import 'dart:io';

import 'package:path/path.dart' as p;

import 'dart_executable.dart';

/// 用 `dart build cli` 把 `bin/fushi_server.dart` 编进 `<outDir>/bundle/`，再按发布包布局
/// 把仓库 `native/*/prebuilt/<平台>/` 下编好的原生库拷进 `bundle/lib/`，返回可执行文件路径。
///
/// 测试要起真 serve 进程时用它，不要 `dart run`：`dart run` 每次都会先删再复制
/// workspace 的 `.dart_tool/lib/sqlite3.dll`（dartdev `native_assets_bundling.dart`
/// 的 `copyTo`），而测试进程自己开过库就已加载这份 DLL，Windows 上删不掉，子进程
/// 直接 `PathAccessException` 退出。`dart build cli` 把 native assets 打进
/// `<outDir>/bundle/lib/`，不碰 `.dart_tool/lib`；产物也正是服务端的发布形态。
///
/// Rust / C++ 原生库不是 native asset，发布流程（release-server.yml）把它们从
/// `native/*/prebuilt/` 拷进 `bundle/lib/`，服务端按 `<exe>/../lib/<裸名>` 定位；
/// AOT 产物不是测试宿主，不会回退去仓库里找 prebuilt，所以这里照发布流程拷一遍。
/// 缺某个硬依赖库时 serve 会明确报错退出，不在这里吞掉。
Future<String> buildFushiServerCli(String outDir) async {
  final ProcessResult r = await Process.run(dartExecutable(), <String>[
    'build',
    'cli',
    '--target',
    p.join('bin', 'fushi_server.dart'),
    '-o',
    outDir,
  ]);
  if (r.exitCode != 0) {
    throw StateError(
      'dart build cli 失败 ${r.exitCode}:\n${r.stdout}\n${r.stderr}',
    );
  }
  final String bundle = p.join(outDir, 'bundle');
  final String exe = p.join(
    bundle,
    'bin',
    Platform.isWindows ? 'fushi_server.exe' : 'fushi_server',
  );
  if (!File(exe).existsSync()) {
    throw StateError('dart build cli 没产出 $exe:\n${r.stdout}');
  }
  _copyPrebuiltNativeLibs(p.join(bundle, 'lib'));
  return exe;
}

void _copyPrebuiltNativeLibs(String libDir) {
  final String platformDir = Platform.isWindows
      ? 'windows-x64'
      : Platform.isMacOS
      ? 'macos'
      : 'linux-x64';
  final Directory native = Directory(p.join(_repoRoot(), 'native'));
  for (final FileSystemEntity module in native.listSync()) {
    if (module is! Directory) continue;
    final Directory prebuilt = Directory(
      p.join(module.path, 'prebuilt', platformDir),
    );
    if (!prebuilt.existsSync()) continue;
    for (final FileSystemEntity f in prebuilt.listSync()) {
      if (f is File && _isDynamicLibrary(f.path)) {
        f.copySync(p.join(libDir, p.basename(f.path)));
      }
    }
  }
}

bool _isDynamicLibrary(String path) {
  final String name = p.basename(path);
  return name.endsWith('.dll') ||
      name.endsWith('.dylib') ||
      name.endsWith('.so') ||
      name.contains('.so.');
}

/// 从包目录（`dart test` 的工作目录）向上找到仓库根（worktree 里 `.git` 是文件）。
String _repoRoot() {
  Directory dir = Directory.current.absolute;
  while (FileSystemEntity.typeSync(p.join(dir.path, '.git')) ==
      FileSystemEntityType.notFound) {
    final Directory parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError('从 ${Directory.current.path} 向上找不到仓库根');
    }
    dir = parent;
  }
  return dir.path;
}
