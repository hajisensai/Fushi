import 'dart:ffi';
import 'dart:io';

/// 环境变量：显式指定原生库绝对路径（测试 / harness / 手工部署）。
const String kFushiComputeLibEnv = 'FUSHI_COMPUTE_LIB';

/// Dart 绑定期望的 C ABI 版本，与 native/fushi_compute/src/lib.rs 的 `ABI_VERSION` 一致。
const int kFushiComputeAbiVersion = 2;

/// FFI 状态码，与 lib.rs 的 `status` 模块一致。
abstract final class FfcStatus {
  static const int ok = 0;
  static const int nullArgument = -1;
  static const int invalidArgument = -2;
  static const int badInput = -3;
  static const int bufferTooSmall = -4;
  static const int panic = -100;
}

/// fushi_compute 原生库加载失败（或缺某个域的符号）。
///
/// fushi_compute 是**硬依赖**：五个平台 app 与无头服务端都随包，没有 Dart 回退实现。
/// 走到这里说明部署坏了（构建漏了库 / 架构不符 / 库比绑定旧），所以抛出带原因的异常，
/// 而不是返回 null 让功能悄悄失效。
///
/// 是 [Error] 而不是 [Exception]：这是部署缺陷，调用方不该把它当业务失败吞掉重试。
/// 各域（哈希 / 图像 / 文本 …）共用这一个类型。
final class FushiComputeUnavailableError extends Error {
  FushiComputeUnavailableError(
    this.message, [
    this.attempts = const <String>[],
  ]);

  final String message;

  /// 逐个候选路径的失败原因。
  final List<String> attempts;

  @override
  String toString() {
    final StringBuffer out = StringBuffer(
      'FushiComputeUnavailableError: $message',
    );
    for (final String attempt in attempts) {
      out.write('\n  - $attempt');
    }
    out.write(
      '\n  (build it with native/fushi_compute/build_*.{ps1,sh}, '
      'or set $kFushiComputeLibEnv to its absolute path)',
    );
    return out.toString();
  }
}

typedef _AbiVersionC = Int32 Function();
typedef _AbiVersionDart = int Function();
typedef _FreeBytesC = Void Function(Pointer<Uint8>, Size);
typedef _FreeBytesDart = void Function(Pointer<Uint8>, int);

/// 已加载的 fushi_compute 原生库。
///
/// 加载时核对 ABI 版本与公共符号；各域的符号由该域的绑定在首次使用时 lookup，缺符号
/// 同样抛 [FushiComputeUnavailableError]（见 [missingSymbols]）。定位规则与 `FushiFsrs` /
/// `FushiP2p` 一致，另在测试宿主（`dart` / `flutter_tester`）下向上查找本仓
/// `native/fushi_compute/prebuilt/<平台>/`。
class FushiCompute {
  FushiCompute._(this.library, this.libraryPath, this._freeBytes);

  /// 底层动态库（各域绑定用它 lookup 自己的符号）。
  final DynamicLibrary library;

  /// 实际加载的路径；按系统搜索路径裸名加载时为裸名，iOS 进程内静态链接时为 null。
  final String? libraryPath;

  final _FreeBytesDart _freeBytes;

  /// 释放原生库分配并交给调用方的缓冲区（`ffc_free_bytes`）。
  void freeBytes(Pointer<Uint8> ptr, int len) => _freeBytes(ptr, len);

  /// 库里是否导出了 [symbol]。
  bool providesSymbol(String symbol) => library.providesSymbol(symbol);

  /// 某个域的绑定 lookup 失败时抛的统一异常。
  FushiComputeUnavailableError missingSymbols(String domain, Object error) =>
      FushiComputeUnavailableError(
        'fushi_compute at ${libraryPath ?? '<process>'} lacks the $domain '
        'symbols (library older than the Dart bindings?): $error',
      );

  /// 返回已加载的默认库（同 [instance]）；不可用时抛 [FushiComputeUnavailableError]。
  /// 各域绑定一律经它取库。
  static FushiCompute require() => instance;

  static FushiCompute? _default;
  static FushiComputeUnavailableError? _defaultError;

  /// 按默认规则加载一次并缓存（见 [libraryCandidates]）；失败抛
  /// [FushiComputeUnavailableError]（之后每次访问都抛同一个）。
  static FushiCompute get instance {
    final FushiCompute? loaded = _default;
    if (loaded != null) return loaded;
    final FushiComputeUnavailableError? error = _defaultError;
    if (error != null) throw error;
    try {
      return _default = load();
    } on FushiComputeUnavailableError catch (e) {
      _defaultError = e;
      rethrow;
    }
  }

  /// 当前平台的裸库名。
  static String defaultLibraryName() {
    if (Platform.isWindows) return 'fushi_compute.dll';
    if (Platform.isMacOS || Platform.isIOS) return 'libfushi_compute.dylib';
    return 'libfushi_compute.so';
  }

  /// 本仓构建脚本的产物子目录（`native/fushi_compute/prebuilt/<它>/`）；无对应时 null。
  static String? _prebuiltPlatformDir() {
    if (Platform.isWindows) return 'windows-x64';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isLinux) return 'linux-x64';
    return null;
  }

  /// 进程是不是测试宿主（`dart test` / `flutter test`）。只有它才去仓库里找 prebuilt：
  /// 正式 app 与服务端不能从当前目录的上级加载库（DLL 投毒面）。
  static bool isTestHost(String executablePath) {
    final String base = executablePath
        .split(RegExp(r'[\\/]'))
        .last
        .toLowerCase();
    return base == 'dart' ||
        base == 'dart.exe' ||
        base == 'flutter_tester' ||
        base == 'flutter_tester.exe';
  }

  /// 候选路径，按优先级：显式 [libraryPath] → 环境变量 `FUSHI_COMPUTE_LIB` →
  /// 可执行文件同级 → `bin/../lib/<name>`（无头服务端 bundle）→ 测试宿主下从
  /// [currentDirectory] 向上找到的 `native/fushi_compute/prebuilt/<平台>/<name>` →
  /// 裸名（Android APK native lib 目录、macOS `Contents/Frameworks`、Linux `bundle/lib/`）。
  /// iOS 不走候选：静态库链进主二进制，见 [load]。
  static List<String> libraryCandidates({
    String? libraryPath,
    Map<String, String>? environment,
    String? executablePath,
    String? currentDirectory,
  }) {
    final String name = defaultLibraryName();
    final Map<String, String> env = environment ?? Platform.environment;
    final String exe = executablePath ?? Platform.resolvedExecutable;
    final String binDir = File(exe).parent.path;
    final String sep = Platform.pathSeparator;
    final String? fromEnv = env[kFushiComputeLibEnv];
    final String? prebuilt = isTestHost(exe)
        ? _findRepoPrebuilt(currentDirectory ?? Directory.current.path, name)
        : null;
    return <String>[
      if (libraryPath != null && libraryPath.isNotEmpty) libraryPath,
      if (fromEnv != null && fromEnv.isNotEmpty) fromEnv,
      '$binDir$sep$name',
      File('$binDir$sep..${sep}lib$sep$name').absolute.path,
      if (prebuilt != null) prebuilt,
      name,
    ];
  }

  static String? _findRepoPrebuilt(String start, String name) {
    final String? platformDir = _prebuiltPlatformDir();
    if (platformDir == null) return null;
    final String sep = Platform.pathSeparator;
    Directory dir = Directory(start).absolute;
    for (int depth = 0; depth < 8; depth++) {
      final File candidate = File(
        '${dir.path}${sep}native${sep}fushi_compute${sep}prebuilt'
        '$sep$platformDir$sep$name',
      );
      if (candidate.existsSync()) return candidate.path;
      // 找到仓库根（worktree 的 `.git` 是文件）为止：本仓 worktree 嵌在主 checkout 里，
      // 再往上找会悄悄加载主 checkout 用别的分支编出的库，掩盖「本 worktree 缺库」
      // （原生库是硬依赖，缺了要明确失败）。
      if (FileSystemEntity.typeSync('${dir.path}$sep.git') !=
          FileSystemEntityType.notFound) {
        break;
      }
      final Directory parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
    return null;
  }

  /// 按 [libraryCandidates] 顺序加载原生库；全部失败抛 [FushiComputeUnavailableError]，
  /// 带每个候选的失败原因。
  ///
  /// 显式给了 [libraryPath] 时**只试这一个**：调用方点名要某个文件，那个文件不能用就该报错，
  /// 而不是悄悄换成系统里别的副本。其余参数仅供测试覆盖。
  static FushiCompute load({
    String? libraryPath,
    Map<String, String>? environment,
    String? executablePath,
    String? currentDirectory,
  }) {
    if (Platform.isIOS && (libraryPath == null || libraryPath.isEmpty)) {
      // iOS 以静态库（native/fushi_ios_umbrella）链进主二进制。
      final DynamicLibrary process = DynamicLibrary.process();
      final String? error = _bindError(process);
      if (error != null) {
        throw FushiComputeUnavailableError(
          'fushi_compute is not linked into this iOS binary '
          '(native/fushi_ios_umbrella): $error',
        );
      }
      return _bind(process, null);
    }
    final List<String> candidates =
        libraryPath != null && libraryPath.isNotEmpty
        ? <String>[libraryPath]
        : libraryCandidates(
            environment: environment,
            executablePath: executablePath,
            currentDirectory: currentDirectory,
          );
    final List<String> attempts = <String>[];
    for (final String candidate in candidates) {
      final bool isBareName =
          !candidate.contains('/') &&
          !candidate.contains(Platform.pathSeparator);
      if (!isBareName && !File(candidate).existsSync()) {
        attempts.add('$candidate: not found');
        continue;
      }
      final DynamicLibrary lib;
      try {
        lib = DynamicLibrary.open(candidate);
      } on ArgumentError catch (e) {
        attempts.add('$candidate: cannot open (${e.message})');
        continue;
      }
      final String? error = _bindError(lib);
      if (error != null) {
        attempts.add('$candidate: $error');
        continue;
      }
      return _bind(lib, candidate);
    }
    throw FushiComputeUnavailableError(
      'cannot load ${defaultLibraryName()}',
      attempts,
    );
  }

  /// 库可用返回 null；否则返回原因（ABI 不符 / 缺公共符号）。
  static String? _bindError(DynamicLibrary lib) {
    try {
      final _AbiVersionDart abi = lib
          .lookupFunction<_AbiVersionC, _AbiVersionDart>('ffc_abi_version');
      final int version = abi();
      if (version != kFushiComputeAbiVersion) {
        return 'ABI version $version, bindings expect $kFushiComputeAbiVersion';
      }
      lib.lookupFunction<_FreeBytesC, _FreeBytesDart>('ffc_free_bytes');
      return null;
    } on ArgumentError catch (e) {
      return 'missing common symbols (${e.message})';
    }
  }

  static FushiCompute _bind(DynamicLibrary lib, String? path) => FushiCompute._(
    lib,
    path,
    lib.lookupFunction<_FreeBytesC, _FreeBytesDart>('ffc_free_bytes'),
  );
}
