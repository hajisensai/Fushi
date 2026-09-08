/// 随包原生库定位：`dart build cli` 的 bundle 布局是 `bin/<exe>` + `lib/<...>`。
///
/// 引擎里各 FFI 加载点的默认行为是「裸名 `DynamicLibrary.open`」= 系统搜索路径
/// （Linux 的 `LD_LIBRARY_PATH` 通常不含 bundle/lib）。服务端在这里按固定次序
/// 找一遍，找到就把**绝对路径**交给引擎；找不到返回 null 让引擎按裸名再试
/// （用户可能装了系统包）。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

/// 候选目录（按优先级）：可执行文件同级 → `../lib`（bundle）→ 当前目录。
List<String> bundledLibraryCandidates(String bareName,
    {String? executablePath}) {
  final String exe = executablePath ?? Platform.resolvedExecutable;
  final String binDir = p.dirname(exe);
  return <String>[
    p.join(binDir, bareName),
    p.normalize(p.join(binDir, '..', 'lib', bareName)),
    p.join(Directory.current.path, bareName),
  ];
}

/// 第一个存在的候选；都不存在 → null。
String? locateBundledLibrary(String bareName, {String? executablePath}) {
  for (final String candidate
      in bundledLibraryCandidates(bareName, executablePath: executablePath)) {
    if (File(candidate).existsSync()) return candidate;
  }
  return null;
}

/// 各平台 onnxruntime 裸库名（与 asr_onnx_ffi 的 `OrtRuntime.defaultLibraryFileName` 同）。
String onnxRuntimeLibraryName() {
  if (Platform.isWindows) return 'onnxruntime.dll';
  if (Platform.isMacOS) return 'libonnxruntime.dylib';
  return 'libonnxruntime.so';
}

/// 各平台内置 torrent 引擎裸库名（与 `EmbeddedTorrentEngine.defaultLibraryNames` 同）。
String torrentLibraryName() {
  if (Platform.isWindows) return 'fushi_torrent_ffi.dll';
  if (Platform.isMacOS) return 'libfushi_torrent_ffi.dylib';
  return 'libfushi_torrent_ffi.so';
}
