import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'ffi/fushi_adblock_bindings.dart';

/// 环境变量：显式指定原生库绝对路径（测试 / harness / 手工部署）。
const String kFushiAdblockLibEnv = 'FUSHI_ADBLOCK_LIB';

/// 已加载的 fushi_adblock 原生库。
///
/// 库缺失是**正常部署形态**（某平台没随包、没装 Rust 的开发机、CI 测试机没编），所以加载
/// 失败不抛，而是 [tryLoad] 返回 null / [isAvailable] 为 false —— 广告拦截能力判不可用，
/// WebView 照常工作（只是不拦）。加载规则与 `packages/fushi_p2p` 的 `FushiP2p` 同一套。
class FushiAdblockLibrary {
  FushiAdblockLibrary._(this.bindings, this.libraryPath);

  /// 底层 FFI 绑定（高级封装之外的逃生口）。
  final FushiAdblockBindings bindings;

  /// 实际加载的路径；按系统搜索路径裸名加载 / iOS 进程内静态链接时为裸名或 null。
  final String? libraryPath;

  static bool _defaultResolved = false;
  static FushiAdblockLibrary? _default;

  /// 按默认规则加载一次并缓存（见 [libraryCandidates]）。
  static FushiAdblockLibrary? get instance {
    if (!_defaultResolved) {
      _default = tryLoad();
      _defaultResolved = true;
    }
    return _default;
  }

  /// 默认规则下原生库是否可用。永不抛。
  static bool get isAvailable => instance != null;

  /// 当前平台的裸库名。
  static String defaultLibraryName() {
    if (Platform.isWindows) return 'fushi_adblock.dll';
    if (Platform.isMacOS || Platform.isIOS) return 'libfushi_adblock.dylib';
    return 'libfushi_adblock.so';
  }

  /// 候选路径，按优先级：
  /// 1. 显式 [libraryPath]；
  /// 2. 环境变量 `FUSHI_ADBLOCK_LIB`；
  /// 3. 可执行文件同级（Windows 桌面包）；
  /// 4. `bin/../lib/<name>`（`dart build cli` 形态的 bundle）；
  /// 5. 裸名（系统搜索路径）。Android 从 APK 的 native lib 目录、macOS 从
  ///    `Contents/Frameworks`（Runner 的 `@executable_path/../Frameworks` rpath）、
  ///    Linux 桌面从 `bundle/lib/`（`$ORIGIN/lib`）加载都走这条。
  ///
  /// iOS 不走候选：静态库（伞形库 native/fushi_ios_umbrella）链进主二进制，见 [tryLoad]。
  static List<String> libraryCandidates({
    String? libraryPath,
    Map<String, String>? environment,
    String? executablePath,
  }) {
    final String name = defaultLibraryName();
    final Map<String, String> env = environment ?? Platform.environment;
    final String exe = executablePath ?? Platform.resolvedExecutable;
    final String binDir = File(exe).parent.path;
    final String sep = Platform.pathSeparator;
    final String? fromEnv = env[kFushiAdblockLibEnv];
    return <String>[
      if (libraryPath != null && libraryPath.isNotEmpty) libraryPath,
      if (fromEnv != null && fromEnv.isNotEmpty) fromEnv,
      '$binDir$sep$name',
      File('$binDir$sep..${sep}lib$sep$name').absolute.path,
      name,
    ];
  }

  /// 按 [libraryCandidates] 顺序加载原生库；全部失败返回 null（不抛）。
  /// [environment] / [executablePath] 仅供测试覆盖定位输入。
  static FushiAdblockLibrary? tryLoad({
    String? libraryPath,
    Map<String, String>? environment,
    String? executablePath,
  }) {
    if (Platform.isIOS) {
      // iOS 以静态库（伞形库）链进主二进制；没链进去时 lookup 抛 ArgumentError → null。
      return _bind(DynamicLibrary.process(), null);
    }
    for (final String candidate in libraryCandidates(
      libraryPath: libraryPath,
      environment: environment,
      executablePath: executablePath,
    )) {
      final bool isBareName =
          !candidate.contains('/') &&
          !candidate.contains(Platform.pathSeparator);
      if (!isBareName && !File(candidate).existsSync()) continue;
      final DynamicLibrary lib;
      try {
        lib = DynamicLibrary.open(candidate);
      } on ArgumentError {
        continue; // 打不开（架构不符 / 依赖缺失 / 系统路径没有）：试下一个。
      }
      final FushiAdblockLibrary? loaded = _bind(lib, candidate);
      if (loaded != null) return loaded;
    }
    return null;
  }

  static FushiAdblockLibrary? _bind(DynamicLibrary lib, String? path) {
    try {
      return FushiAdblockLibrary._(FushiAdblockBindings(lib), path);
    } on ArgumentError {
      return null; // 缺符号：不是这个库 / 版本太老。
    }
  }

  /// 原生库版本串（= native/fushi_adblock 的 crate 版本；序列化缓存键的一部分）。
  String version() => bindings.fadb_version().cast<Utf8>().toDartString();
}
