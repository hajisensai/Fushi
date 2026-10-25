import 'dart:ffi';
import 'dart:io';

/// 环境变量：显式指定原生库绝对路径（测试 / harness / 手工部署）。
const String kFushiMusicLibEnv = 'FUSHI_MUSIC_LIB';

/// Dart 绑定期望的 C ABI 版本，与 native/fushi_music/src/lib.rs 的 `ABI_VERSION` 一致。
const int kFushiMusicAbiVersion = 1;

/// FFI 状态码，与 lib.rs 的 `status` 模块一致。
abstract final class FfmStatus {
  static const int ok = 0;
  static const int nullArgument = -1;
  static const int invalidArgument = -2;
  static const int badInput = -3;
  static const int notFound = -5;

  /// 写文件失败（只读 / 被占用 / 格式不支持写标签，tag_write.rs）。
  static const int writeFailed = -6;

  /// 设备读失败（光驱打不开 / 没有盘 / 不是音频 CD，cd.rs）。
  static const int ioFailed = -7;

  /// 本平台不支持（移动端读物理光驱）。
  static const int unsupported = -8;
  static const int panic = -100;
}

/// fushi_music 原生库加载失败（或缺符号）。
///
/// fushi_music 是**硬依赖**：没有 Dart 回退实现。走到这里说明部署坏了（构建漏了库 /
/// 架构不符 / 库比绑定旧），所以抛带原因的异常，而不是返回 null 让曲库扫描悄悄变空。
/// 是 [Error] 而不是 [Exception]：这是部署缺陷，调用方不该把它当业务失败吞掉重试。
final class FushiMusicUnavailableError extends Error {
  FushiMusicUnavailableError(this.message, [this.attempts = const <String>[]]);

  final String message;

  /// 逐个候选路径的失败原因。
  final List<String> attempts;

  @override
  String toString() {
    final StringBuffer out = StringBuffer(
      'FushiMusicUnavailableError: $message',
    );
    for (final String attempt in attempts) {
      out.write('\n  - $attempt');
    }
    out.write(
      '\n  (build it with native/fushi_music/build_*.{ps1,sh} or '
      'tool/native_libs.ps1, or set $kFushiMusicLibEnv to its absolute path)',
    );
    return out.toString();
  }
}

typedef _AbiVersionC = Int32 Function();
typedef _AbiVersionDart = int Function();
typedef _FreeBytesC = Void Function(Pointer<Uint8>, Size);
typedef _FreeBytesDart = void Function(Pointer<Uint8>, int);

/// 已加载的 fushi_music 原生库。定位规则与 `FushiCompute` 一致（显式路径 → 环境变量 →
/// 可执行文件同级 → `bin/../lib` → 测试宿主下本仓 `native/fushi_music/prebuilt/<平台>/` →
/// 裸名），iOS 走进程内静态链接。
class FushiMusic {
  FushiMusic._(this.library, this.libraryPath, this._freeBytes);

  /// 底层动态库（绑定用它 lookup 自己的符号）。
  final DynamicLibrary library;

  /// 实际加载的路径；按系统搜索路径裸名加载时为裸名，iOS 进程内静态链接时为 null。
  final String? libraryPath;

  final _FreeBytesDart _freeBytes;

  /// 释放原生库分配并交给调用方的缓冲区（`ffm_free_bytes`）。
  void freeBytes(Pointer<Uint8> ptr, int len) => _freeBytes(ptr, len);

  /// 某组绑定 lookup 失败时抛的统一异常。
  FushiMusicUnavailableError missingSymbols(String domain, Object error) =>
      FushiMusicUnavailableError(
        'fushi_music at ${libraryPath ?? '<process>'} lacks the $domain '
        'symbols (library older than the Dart bindings?): $error',
      );

  static FushiMusic? _default;
  static FushiMusicUnavailableError? _defaultError;

  /// 按默认规则加载一次并缓存（每个 isolate 各一份）；失败抛
  /// [FushiMusicUnavailableError]（之后每次访问都抛同一个）。
  static FushiMusic get instance {
    final FushiMusic? loaded = _default;
    if (loaded != null) return loaded;
    final FushiMusicUnavailableError? error = _defaultError;
    if (error != null) throw error;
    try {
      return _default = load();
    } on FushiMusicUnavailableError catch (e) {
      _defaultError = e;
      rethrow;
    }
  }

  /// 当前平台的裸库名。
  static String defaultLibraryName() {
    if (Platform.isWindows) return 'fushi_music.dll';
    if (Platform.isMacOS || Platform.isIOS) return 'libfushi_music.dylib';
    return 'libfushi_music.so';
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

  /// 候选路径（见类文档）。iOS 不走候选：静态库链进主二进制，见 [load]。
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
    final String? fromEnv = env[kFushiMusicLibEnv];
    final String? prebuilt = isTestHost(exe)
        ? _findRepoPrebuilt(currentDirectory ?? Directory.current.path, name)
        : null;
    return <String>[
      if (libraryPath != null && libraryPath.isNotEmpty) libraryPath,
      if (fromEnv != null && fromEnv.isNotEmpty) fromEnv,
      '$binDir$sep$name',
      File('$binDir$sep..${sep}lib$sep$name').absolute.path,
      ?prebuilt,
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
        '${dir.path}${sep}native${sep}fushi_music${sep}prebuilt'
        '$sep$platformDir$sep$name',
      );
      if (candidate.existsSync()) return candidate.path;
      // 找到仓库根（worktree 的 `.git` 是文件）为止：worktree 嵌在主 checkout 里，再往上
      // 找会悄悄加载别的分支编出的库，掩盖「本 worktree 缺库」。
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

  /// 按 [libraryCandidates] 顺序加载；全部失败抛 [FushiMusicUnavailableError]。显式给了
  /// [libraryPath] 时只试这一个。
  static FushiMusic load({
    String? libraryPath,
    Map<String, String>? environment,
    String? executablePath,
    String? currentDirectory,
  }) {
    if (Platform.isIOS && (libraryPath == null || libraryPath.isEmpty)) {
      final DynamicLibrary process = DynamicLibrary.process();
      final String? error = _bindError(process);
      if (error != null) {
        throw FushiMusicUnavailableError(
          'fushi_music is not linked into this iOS binary '
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
    throw FushiMusicUnavailableError(
      'cannot load ${defaultLibraryName()}',
      attempts,
    );
  }

  static String? _bindError(DynamicLibrary lib) {
    try {
      final _AbiVersionDart abi = lib
          .lookupFunction<_AbiVersionC, _AbiVersionDart>('ffm_abi_version');
      final int version = abi();
      if (version != kFushiMusicAbiVersion) {
        return 'ABI version $version, bindings expect $kFushiMusicAbiVersion';
      }
      lib.lookupFunction<_FreeBytesC, _FreeBytesDart>('ffm_free_bytes');
      return null;
    } on ArgumentError catch (e) {
      return 'missing common symbols (${e.message})';
    }
  }

  static FushiMusic _bind(DynamicLibrary lib, String? path) => FushiMusic._(
    lib,
    path,
    lib.lookupFunction<_FreeBytesC, _FreeBytesDart>('ffm_free_bytes'),
  );
}
