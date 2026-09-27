import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'ffi/fushi_p2p_bindings.dart';

/// 环境变量：显式指定原生库绝对路径（测试 / harness / 手工部署）。
const String kFushiP2pLibEnv = 'FUSHI_P2P_LIB';

/// 已加载的 fushi_p2p 原生库。
///
/// 库缺失是**正常部署形态**（某平台没随包、CI 测试机没编），所以加载失败不抛，
/// 而是 [tryLoad] 返回 null / [isAvailable] 为 false —— P2P 能力判不可用，
/// 其余互联照旧。
class FushiP2p {
  FushiP2p._(this.bindings, this.libraryPath);

  /// 底层 FFI 绑定（高级封装之外的逃生口）。
  final FushiP2pBindings bindings;

  /// 实际加载的路径；按系统搜索路径裸名加载 / iOS 进程内静态链接时为裸名或 null。
  final String? libraryPath;

  static bool _defaultResolved = false;
  static FushiP2p? _default;

  /// 按默认规则加载一次并缓存（见 [libraryCandidates]）。
  static FushiP2p? get instance {
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
    if (Platform.isWindows) return 'fushi_p2p.dll';
    if (Platform.isMacOS || Platform.isIOS) return 'libfushi_p2p.dylib';
    return 'libfushi_p2p.so';
  }

  /// 候选路径，按优先级：
  /// 1. 显式 [libraryPath]；
  /// 2. 环境变量 `FUSHI_P2P_LIB`；
  /// 3. 可执行文件同级（Windows / Linux 桌面包）；
  /// 4. `bin/../lib/<name>`（无头服务端 `dart build cli` bundle）；
  /// 5. 裸名（系统搜索路径；Android 从 APK 的 native lib 目录加载即走这条）。
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
    final String? fromEnv = env[kFushiP2pLibEnv];
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
  static FushiP2p? tryLoad({
    String? libraryPath,
    Map<String, String>? environment,
    String? executablePath,
  }) {
    if (Platform.isIOS) {
      // iOS 以静态库链进主二进制。
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
      final FushiP2p? loaded = _bind(lib, candidate);
      if (loaded != null) return loaded;
    }
    return null;
  }

  static FushiP2p? _bind(DynamicLibrary lib, String? path) {
    try {
      return FushiP2p._(FushiP2pBindings(lib), path);
    } on ArgumentError {
      return null; // 缺符号：不是这个库 / 版本太老。
    }
  }

  /// 原生库版本串。
  String version() => bindings.fp2p_version().cast<Utf8>().toDartString();
}
