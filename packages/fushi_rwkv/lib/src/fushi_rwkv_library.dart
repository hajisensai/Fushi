import 'dart:ffi';
import 'dart:io';

/// 环境变量：显式指定原生库绝对路径（测试 / harness / 手工部署）。
const String kFushiRwkvLibEnv = 'FUSHI_RWKV_LIB';

/// Dart 绑定期望的 C ABI 版本，与 native/fushi_rwkv/src/lib.rs 的 `ABI_VERSION` 一致。
const int kFushiRwkvAbiVersion = 5;

/// `sizeof(FrwkvReview)`，与 lib.rs 一致（启动时核对）。
const int kFrwkvReviewSize = 80;

/// fushi_rwkv 原生库加载失败（或缺符号 / ABI 不符）。
///
/// fushi_rwkv 是**硬依赖**：五个平台 app 都随包，没有 Dart 回退实现。走到这里说明部署坏了
/// （构建漏了库 / 架构不符 / 库比绑定旧），所以抛带原因的异常，而不是让 RWKV 悄悄失效。
/// 是 [Error] 而不是 [Exception]：调用方不该把部署缺陷当业务失败吞掉重试。
final class FushiRwkvUnavailableError extends Error {
  FushiRwkvUnavailableError(this.message, [this.attempts = const <String>[]]);

  final String message;

  /// 逐个候选路径的失败原因。
  final List<String> attempts;

  @override
  String toString() {
    final StringBuffer out = StringBuffer(
      'FushiRwkvUnavailableError: $message',
    );
    for (final String attempt in attempts) {
      out.write('\n  - $attempt');
    }
    out.write(
      '\n  (build it with native/fushi_rwkv/build_*.{ps1,sh}, '
      'or set $kFushiRwkvLibEnv to its absolute path)',
    );
    return out.toString();
  }
}

typedef _AbiVersionC = Int32 Function();
typedef _AbiVersionDart = int Function();
typedef _StructSizeC = Size Function();
typedef _StructSizeDart = int Function();

/// 已加载的 fushi_rwkv 原生库。定位规则与 `FushiCompute` 一致：显式路径 → 环境变量
/// `FUSHI_RWKV_LIB` → 可执行文件同级 → `bin/../lib/<name>`（无头服务端）→ 测试宿主下向上找本仓
/// `native/fushi_rwkv/prebuilt/<平台>/` → 裸名（Android APK、macOS Frameworks、Linux bundle/lib）；
/// iOS 静态链进主二进制（native/fushi_ios_umbrella）。
class FushiRwkv {
  FushiRwkv._(this.library, this.libraryPath);

  final DynamicLibrary library;

  /// 实际加载的路径；裸名加载时为裸名，iOS 进程内静态链接时为 null。
  final String? libraryPath;

  static FushiRwkv? _default;
  static FushiRwkvUnavailableError? _defaultError;

  /// 按默认规则加载一次并缓存；失败抛 [FushiRwkvUnavailableError]（之后每次都抛同一个）。
  static FushiRwkv get instance {
    final FushiRwkv? loaded = _default;
    if (loaded != null) return loaded;
    final FushiRwkvUnavailableError? error = _defaultError;
    if (error != null) throw error;
    try {
      return _default = load();
    } on FushiRwkvUnavailableError catch (e) {
      _defaultError = e;
      rethrow;
    }
  }

  static String defaultLibraryName() {
    if (Platform.isWindows) return 'fushi_rwkv.dll';
    if (Platform.isMacOS || Platform.isIOS) return 'libfushi_rwkv.dylib';
    return 'libfushi_rwkv.so';
  }

  static String? _prebuiltPlatformDir() {
    if (Platform.isWindows) return 'windows-x64';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isLinux) return 'linux-x64';
    return null;
  }

  /// 进程是不是测试宿主（`dart test` / `flutter test`）。只有它才去仓库里找 prebuilt：
  /// 正式 app 不能从当前目录的上级加载库（DLL 投毒面）。
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
    final String? fromEnv = env[kFushiRwkvLibEnv];
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
        '${dir.path}${sep}native${sep}fushi_rwkv${sep}prebuilt$sep$platformDir$sep$name',
      );
      if (candidate.existsSync()) return candidate.path;
      final Directory parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
    return null;
  }

  /// 按 [libraryCandidates] 顺序加载；全部失败抛 [FushiRwkvUnavailableError]。
  /// 显式给了 [libraryPath] 时只试这一个（worker isolate 用它加载主 isolate 已验证的同一个文件）。
  static FushiRwkv load({
    String? libraryPath,
    Map<String, String>? environment,
    String? executablePath,
    String? currentDirectory,
  }) {
    if (Platform.isIOS && (libraryPath == null || libraryPath.isEmpty)) {
      final DynamicLibrary process = DynamicLibrary.process();
      final String? error = _bindError(process);
      if (error != null) {
        throw FushiRwkvUnavailableError(
          'fushi_rwkv is not linked into this iOS binary (native/fushi_ios_umbrella): $error',
        );
      }
      return FushiRwkv._(process, null);
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
      return FushiRwkv._(lib, candidate);
    }
    throw FushiRwkvUnavailableError(
      'cannot load ${defaultLibraryName()}',
      attempts,
    );
  }

  static String? _bindError(DynamicLibrary lib) {
    try {
      final int version = lib.lookupFunction<_AbiVersionC, _AbiVersionDart>(
        'frwkv_abi_version',
      )();
      if (version != kFushiRwkvAbiVersion) {
        return 'ABI version $version, bindings expect $kFushiRwkvAbiVersion';
      }
      final int size = lib.lookupFunction<_StructSizeC, _StructSizeDart>(
        'frwkv_review_struct_size',
      )();
      if (size != kFrwkvReviewSize) {
        return 'FrwkvReview is $size bytes, bindings expect $kFrwkvReviewSize';
      }
      return null;
    } on ArgumentError catch (e) {
      return 'missing symbols (${e.message})';
    }
  }
}
