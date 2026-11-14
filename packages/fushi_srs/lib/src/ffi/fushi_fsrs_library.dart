import 'dart:ffi';
import 'dart:io';

import 'fushi_fsrs_bindings.dart';

/// 环境变量：显式指定原生库绝对路径（测试 / harness / 手工部署）。
const String kFushiFsrsLibEnv = 'FUSHI_FSRS_LIB';

/// 环境变量：设成 `0` 时调试构建 / 测试宿主不去找带 ID 审计的库（见 [kFushiFsrsIdAuditDir]），用随包 / 普通
/// prebuilt 那份——对着大库测性能、或要对照发布行为时用。CI 设 `1` 是另一回事：那里的库本身就是带审计编的，
/// 金丝雀测试据此断言审计开着。
const String kFushiFsrsIdAuditEnv = 'FUSHI_FSRS_ID_AUDIT';

/// 带 ID 审计（cargo feature `id_audit`，native/fushi_fsrs/src/store/ids.rs `audit`）的本机库所在的子目录：
/// `native/fushi_fsrs/prebuilt/<平台>/id_audit/<库名>`，由本机的备库脚本编出（tool/native_libs.ps1——Windows
/// 测试 worker 也走它——与 tool/bootstrap.sh；Mac / Linux 测试 worker 不编）。Dart 原生 SQL 漏写 `srs_id(?)` 在
/// 普通构建里只是静默查不到行，在这份库里那条语句直接报 `id audit: …`。它**不随包**：各平台的打包（CMake /
/// Xcode / Gradle）只认上一级目录里的普通库，发布流水线也不编它。
const String kFushiFsrsIdAuditDir = 'id_audit';

/// Dart 绑定期望的 C ABI 版本，与 native/fushi_fsrs/src/lib.rs 的 `ABI_VERSION` 一致。
/// 不一致视为库不可用（不崩、不猜着调）。
const int kFushiFsrsAbiVersion = 6;

/// 已加载的 fushi_fsrs 原生库（fsrs-rs 的 C ABI）。
///
/// 库缺失是**正常部署形态**（某平台没随包、CI 测试机没编），所以加载失败不抛，
/// 而是 [tryLoad] 返回 null / [isAvailable] 为 false。与 packages/fushi_p2p 的
/// `FushiP2p` 同一套定位规则。
class FushiFsrs {
  FushiFsrs._(this.bindings, this.libraryPath);

  /// 底层 FFI 绑定（高级封装之外的逃生口）。
  final FushiFsrsBindings bindings;

  /// 实际加载的路径；按系统搜索路径裸名加载时为裸名，iOS 进程内静态链接时为 null。
  final String? libraryPath;

  /// 加载的是不是 [kFushiFsrsIdAuditDir] 下那份带 ID 审计的库（按路径判；`FUSHI_FSRS_LIB` 显式指到别处的
  /// 审计构建不算，那种情况由调用方自己知道）。
  bool get isIdAuditVariant => isIdAuditVariantPath(libraryPath);

  /// [path] 是不是落在 [kFushiFsrsIdAuditDir] 目录里的库文件。
  static bool isIdAuditVariantPath(String? path) {
    if (path == null) return false;
    final List<String> parts = path.split(RegExp(r'[\\/]'));
    return parts.length >= 2 && parts[parts.length - 2] == kFushiFsrsIdAuditDir;
  }

  /// 本进程是不是调试构建（断言开着：`flutter run` 的 debug 模式、`dart test` / `flutter test`）。profile /
  /// release 的 AOT 产物里断言被编译掉，恒为 false。
  static bool get isDebugBuild {
    bool on = false;
    assert(() {
      on = true;
      return true;
    }());
    return on;
  }

  static bool _defaultResolved = false;
  static FushiFsrs? _default;

  /// 按默认规则加载一次并缓存（见 [libraryCandidates]）。
  static FushiFsrs? get instance {
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
    if (Platform.isWindows) return 'fushi_fsrs.dll';
    if (Platform.isMacOS || Platform.isIOS) return 'libfushi_fsrs.dylib';
    return 'libfushi_fsrs.so';
  }

  /// 候选路径，按优先级：
  /// 1. 显式 [libraryPath]；
  /// 2. 环境变量 `FUSHI_FSRS_LIB`；
  /// 3. 仅调试构建（[debugBuild]，缺省 [isDebugBuild]）且 `FUSHI_FSRS_ID_AUDIT` 不是 `0`：本仓
  ///    `native/fushi_fsrs/prebuilt/<平台>/id_audit/<name>`（带 ID 审计的库，[kFushiFsrsIdAuditDir]）。测试宿主从
  ///    [currentDirectory] 向上找，调试 app 从可执行文件所在目录向上找（`flutter run` 的产物在
  ///    `<仓库>/fushi/build/…` 里）；找不到就没有这一项，照旧用下面的普通库。发布 / profile 构建不找；
  /// 4. 可执行文件同级（Windows / Linux 桌面包）；
  /// 5. `bin/../lib/<name>`（无头服务端 `dart build cli` bundle）；
  /// 6. 仅测试宿主（`dart` / `flutter_tester`，见 [isTestHost]）：从 [currentDirectory]
  ///    向上找到的本仓 `native/fushi_fsrs/prebuilt/<平台>/<name>`（`tool/bootstrap.ps1`
  ///    编出或复用的产物），worktree 里跑测试不必再设环境变量；
  /// 7. 裸名（系统搜索路径）。Android 从 APK 的 native lib 目录、macOS 从
  ///    `Contents/Frameworks`（Runner 的 `@executable_path/../Frameworks` rpath）、
  ///    Linux 桌面从 `bundle/lib/`（`$ORIGIN/lib`）加载都走这条。
  ///
  /// iOS 不走候选：静态库链进主二进制，见 [tryLoad]。
  static List<String> libraryCandidates({
    String? libraryPath,
    Map<String, String>? environment,
    String? executablePath,
    String? currentDirectory,
    bool? debugBuild,
  }) {
    final String name = defaultLibraryName();
    final Map<String, String> env = environment ?? Platform.environment;
    final String exe = executablePath ?? Platform.resolvedExecutable;
    final String binDir = File(exe).parent.path;
    final String sep = Platform.pathSeparator;
    final String? fromEnv = env[kFushiFsrsLibEnv];
    final bool testHost = isTestHost(exe);
    final String? prebuilt = testHost
        ? _findRepoPrebuilt(currentDirectory ?? Directory.current.path, name)
        : null;
    final String? audited =
        (debugBuild ?? isDebugBuild) && env[kFushiFsrsIdAuditEnv] != '0'
        ? _findRepoPrebuilt(
            testHost ? currentDirectory ?? Directory.current.path : binDir,
            name,
            variant: kFushiFsrsIdAuditDir,
          )
        : null;
    return <String>[
      if (libraryPath != null && libraryPath.isNotEmpty) libraryPath,
      if (fromEnv != null && fromEnv.isNotEmpty) fromEnv,
      if (audited != null) audited,
      '$binDir$sep$name',
      File('$binDir$sep..${sep}lib$sep$name').absolute.path,
      if (prebuilt != null) prebuilt,
      name,
    ];
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

  /// 从 [start] 向上找本仓的 `native/fushi_fsrs/prebuilt/<平台>/[<variant>/]<name>`。层数上限按最深的调试
  /// 产物算：macOS 的 `fushi/build/macos/Build/Products/Debug/Fushi.app/Contents/MacOS` 离仓库根 9 层。
  static String? _findRepoPrebuilt(
    String start,
    String name, {
    String? variant,
  }) {
    final String? platformDir = Platform.isWindows
        ? 'windows-x64'
        : Platform.isMacOS
        ? 'macos'
        : Platform.isLinux
        ? 'linux-x64'
        : null;
    if (platformDir == null) return null;
    final String sep = Platform.pathSeparator;
    final String leaf = variant == null ? name : '$variant$sep$name';
    Directory dir = Directory(start).absolute;
    for (int depth = 0; depth < 12; depth++) {
      final File candidate = File(
        '${dir.path}${sep}native${sep}fushi_fsrs${sep}prebuilt'
        '$sep$platformDir$sep$leaf',
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

  /// 按 [libraryCandidates] 顺序加载原生库；全部失败返回 null（不抛）。
  ///
  /// 显式给了 [libraryPath] 时**只试这一个**：调用方点名要某个文件（测试、harness），
  /// 那个文件不能用就该报不可用，而不是悄悄换成系统里别的副本。
  /// [environment] / [executablePath] / [currentDirectory] / [debugBuild] 仅供测试覆盖定位输入。
  static FushiFsrs? tryLoad({
    String? libraryPath,
    Map<String, String>? environment,
    String? executablePath,
    String? currentDirectory,
    bool? debugBuild,
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
              currentDirectory: currentDirectory,
              debugBuild: debugBuild,
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
        final FushiFsrs? loaded = _bind(lib, candidate);
        if (loaded != null) return loaded;
      }
      return null;
    } on Object {
      // 任何意外（文件系统异常等）都只意味着「不可用」，绝不抛给调用方。
      return null;
    }
  }

  static FushiFsrs? _bind(DynamicLibrary lib, String? path) {
    final FushiFsrsBindings bindings;
    try {
      bindings = FushiFsrsBindings(lib);
    } on ArgumentError {
      return null; // 缺符号：不是这个库 / 版本太老。
    }
    if (bindings.ffsrs_abi_version() != kFushiFsrsAbiVersion) {
      return null; // ABI 不符：请求 / 响应形状可能已变，宁可不可用。
    }
    return FushiFsrs._(bindings, path);
  }
}
