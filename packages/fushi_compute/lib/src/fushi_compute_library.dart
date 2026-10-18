import 'dart:ffi';
import 'dart:io';

/// 环境变量：显式指定原生库绝对路径（测试 / harness / 手工部署）。
const String kFushiComputeLibEnv = 'FUSHI_COMPUTE_LIB';

/// Dart 绑定期望的 C ABI 版本，与 native/fushi_compute/src/lib.rs 的 `ABI_VERSION` 一致。
/// 不一致视为库不可用（不崩、不猜着调）。
const int kFushiComputeAbiVersion = 1;

/// FFI 状态码，与 lib.rs 的 `status` 模块一致。
abstract final class FfcStatus {
  static const int ok = 0;
  static const int nullArgument = -1;
  static const int invalidArgument = -2;
  static const int badInput = -3;
  static const int bufferTooSmall = -4;
  static const int panic = -100;
}

/// 原生库（或某个域的符号）不可用。原生库是硬依赖，各域 API 遇到它直接抛，不退回 Dart。
class FushiComputeUnavailableError extends StateError {
  FushiComputeUnavailableError(super.message);
}

typedef _AbiVersionC = Int32 Function();
typedef _AbiVersionDart = int Function();
typedef _FreeBytesC = Void Function(Pointer<Uint8>, Size);
typedef _FreeBytesDart = void Function(Pointer<Uint8>, int);

/// 已加载的 fushi_compute 原生库。
///
/// 库缺失是**正常部署形态**（某平台没随包、CI 测试机没编），所以加载失败不抛，
/// [instance] 为 null。与 `FushiFsrs` / `FushiP2p` 同一套定位规则。
///
/// 只在加载时核对 ABI 版本与公共符号；各域的符号由该域的绑定在首次使用时自己 lookup
/// （[lookupOrNull]），缺符号（旧库）只让那一个域不可用。
class FushiCompute {
  FushiCompute._(this.library, this.libraryPath, this._freeBytes);

  /// 底层动态库（各域绑定用它 lookup 自己的符号）。
  final DynamicLibrary library;

  /// 实际加载的路径；按系统搜索路径裸名加载时为裸名，iOS 进程内静态链接时为 null。
  final String? libraryPath;

  final _FreeBytesDart _freeBytes;

  /// 释放原生库分配并交给调用方的缓冲区（`ffc_free_bytes`）。
  void freeBytes(Pointer<Uint8> ptr, int len) => _freeBytes(ptr, len);

  /// 库里是否导出了 [symbol]。各域绑定先用它判断，再用具体类型
  /// `library.lookupFunction<C, D>(symbol)`（类型参数必须是编译期常量，没法包成泛型 helper）。
  bool providesSymbol(String symbol) => library.providesSymbol(symbol);

  static bool _defaultResolved = false;
  static FushiCompute? _default;

  /// 按默认规则加载一次并缓存（见 [libraryCandidates]）。
  static FushiCompute? get instance {
    if (!_defaultResolved) {
      _default = tryLoad();
      _defaultResolved = true;
    }
    return _default;
  }

  /// 当前平台的裸库名。
  static String defaultLibraryName() {
    if (Platform.isWindows) return 'fushi_compute.dll';
    if (Platform.isMacOS || Platform.isIOS) return 'libfushi_compute.dylib';
    return 'libfushi_compute.so';
  }

  /// 候选路径，按优先级：显式 [libraryPath] → 环境变量 `FUSHI_COMPUTE_LIB` →
  /// 可执行文件同级 → `bin/../lib/<name>`（无头服务端 bundle）→ 裸名（Android APK
  /// native lib 目录、macOS `Contents/Frameworks`、Linux `bundle/lib/`）。
  /// iOS 不走候选：静态库链进主二进制，见 [tryLoad]。
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
    final String? fromEnv = env[kFushiComputeLibEnv];
    return <String>[
      if (libraryPath != null && libraryPath.isNotEmpty) libraryPath,
      if (fromEnv != null && fromEnv.isNotEmpty) fromEnv,
      '$binDir$sep$name',
      File('$binDir$sep..${sep}lib$sep$name').absolute.path,
      name,
    ];
  }

  /// 按 [libraryCandidates] 顺序加载原生库；全部失败返回 null（不抛）。
  ///
  /// 显式给了 [libraryPath] 时**只试这一个**：调用方点名要某个文件，那个文件不能用就该报
  /// 不可用，而不是悄悄换成系统里别的副本。[environment] / [executablePath] 仅供测试覆盖。
  static FushiCompute? tryLoad({
    String? libraryPath,
    Map<String, String>? environment,
    String? executablePath,
  }) {
    try {
      if (Platform.isIOS) {
        // iOS 以静态库（native/fushi_ios_umbrella）链进主二进制。
        return _bind(DynamicLibrary.process(), null);
      }
      final List<String> candidates =
          libraryPath != null && libraryPath.isNotEmpty
          ? <String>[libraryPath]
          : libraryCandidates(
              environment: environment,
              executablePath: executablePath,
            );
      for (final String candidate in candidates) {
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
        final FushiCompute? loaded = _bind(lib, candidate);
        if (loaded != null) return loaded;
      }
      return null;
    } on Object {
      // 任何意外都只意味着「不可用」，绝不抛给调用方。
      return null;
    }
  }

  static FushiCompute? _bind(DynamicLibrary lib, String? path) {
    try {
      final _AbiVersionDart abi = lib
          .lookupFunction<_AbiVersionC, _AbiVersionDart>('ffc_abi_version');
      if (abi() != kFushiComputeAbiVersion) return null;
      final _FreeBytesDart free = lib
          .lookupFunction<_FreeBytesC, _FreeBytesDart>('ffc_free_bytes');
      return FushiCompute._(lib, path, free);
    } on ArgumentError {
      return null; // 缺公共符号：不是这个库 / 版本太老。
    }
  }
}
