import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:fushi_ffi_view/fushi_ffi_view.dart';

import 'ffi/fushi_web_core_bindings.dart';

/// 环境变量：显式指定原生库绝对路径（测试 / harness / 手工部署）。
const String kFushiWebCoreLibEnv = 'FUSHI_WEB_CORE_LIB';

/// 原生库加载失败。它是**硬依赖**：发布包里缺库是构建 / 打包错误，不是一种能力降级，
/// 所以没有「判不可用、照常运行」的分支——上层拿到这个异常就该如实报错。
class FushiWebCoreLibraryMissing extends StateError {
  FushiWebCoreLibraryMissing(this.tried)
    : super(
        'fushi_web_core native library not found (tried: ${tried.join(', ')}). '
        'Build native/fushi_web_core (cargo build --release, or the platform '
        'build_*.{sh,ps1}) or set $kFushiWebCoreLibEnv.',
      );

  final List<String> tried;
}

/// 已加载的 fushi_web_core 原生库（网页内容计算核心：广告拦截 + 漫画章末广告页识别）。
class FushiWebCoreLibrary {
  FushiWebCoreLibrary._(this.bindings, this.libraryPath);

  final FushiWebCoreBindings bindings;

  /// 实际加载的路径；iOS 进程内静态链接 / 系统搜索路径裸名时为 null 或裸名。
  /// 后台 isolate 用它重新加载同一份库。
  final String? libraryPath;

  /// 测试 / harness 覆盖：设了就作为第一候选（优先于环境变量）。
  static String? overridePath;

  static final Map<String?, FushiWebCoreLibrary> _loaded =
      <String?, FushiWebCoreLibrary>{};

  /// 按默认规则加载一次并缓存；找不到抛 [FushiWebCoreLibraryMissing]。
  static FushiWebCoreLibrary get instance => load();

  /// 加载（同一 [libraryPath] 在本 isolate 只加载一次）。找不到抛
  /// [FushiWebCoreLibraryMissing]。
  static FushiWebCoreLibrary load({String? libraryPath}) {
    final String? key = libraryPath ?? overridePath;
    final FushiWebCoreLibrary? cached = _loaded[key];
    if (cached != null) return cached;
    final FushiWebCoreLibrary lib = _open(key);
    _loaded[key] = lib;
    return lib;
  }

  static FushiWebCoreLibrary _open(String? explicit) {
    if (Platform.isIOS) {
      // iOS 以静态库（伞形库 native/fushi_ios_umbrella）链进主二进制。
      try {
        return FushiWebCoreLibrary._(
          FushiWebCoreBindings(ffi.DynamicLibrary.process()),
          null,
        );
      } on ArgumentError {
        throw FushiWebCoreLibraryMissing(const <String>['<process>']);
      }
    }
    final List<String> tried = <String>[];
    for (final String candidate in libraryCandidates(libraryPath: explicit)) {
      tried.add(candidate);
      final bool isBareName =
          !candidate.contains('/') &&
          !candidate.contains(Platform.pathSeparator);
      if (!isBareName && !File(candidate).existsSync()) continue;
      try {
        return FushiWebCoreLibrary._(
          FushiWebCoreBindings(ffi.DynamicLibrary.open(candidate)),
          candidate,
        );
      } on ArgumentError {
        continue; // 打不开 / 缺符号（架构不符、旧版本）：试下一个。
      }
    }
    throw FushiWebCoreLibraryMissing(tried);
  }

  /// 当前平台的裸库名。
  static String defaultLibraryName() {
    if (Platform.isWindows) return 'fushi_web_core.dll';
    if (Platform.isMacOS || Platform.isIOS) return 'libfushi_web_core.dylib';
    return 'libfushi_web_core.so';
  }

  /// 候选路径，按优先级：
  /// 1. 显式 [libraryPath]（或 [overridePath]）；
  /// 2. 环境变量 `FUSHI_WEB_CORE_LIB`；
  /// 3. 可执行文件同级（Windows 桌面包）；
  /// 4. `bin/../lib/<name>`（`dart build cli` 形态的 bundle）；
  /// 5. 仅测试宿主（`dart` / `flutter_tester`，见 [isTestHost]）：从 [currentDirectory]
  ///    向上找到的本仓 `native/fushi_web_core/prebuilt/<平台>/<name>`（`tool/bootstrap.ps1`
  ///    编出或复用的产物），没调 `useDevFushiWebCoreLibrary` 的测试也能加载；
  /// 6. 裸名（系统搜索路径）。Android 从 APK 的 native lib 目录、macOS 从
  ///    `Contents/Frameworks`、Linux 桌面从 `bundle/lib/`（`$ORIGIN/lib`）加载都走这条。
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
    final String? fromEnv = env[kFushiWebCoreLibEnv];
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

  static String? _findRepoPrebuilt(String start, String name) {
    final String? platformDir = Platform.isWindows
        ? 'windows-x64'
        : Platform.isMacOS
        ? 'macos'
        : Platform.isLinux
        ? 'linux-x64'
        : null;
    if (platformDir == null) return null;
    final String sep = Platform.pathSeparator;
    Directory dir = Directory(start).absolute;
    for (int depth = 0; depth < 8; depth++) {
      final File candidate = File(
        '${dir.path}${sep}native${sep}fushi_web_core${sep}prebuilt'
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

  /// 原生库版本串（= native/fushi_web_core 的 crate 版本）。
  String version() => bindings.fwc_version().cast<Utf8>().toDartString();

  /// 本线程最近一次失败的原因（取完即释放）。
  String? lastError() {
    final ffi.Pointer<ffi.Char> p = bindings.fwc_last_error();
    if (p == ffi.nullptr) return null;
    try {
      return p.cast<Utf8>().toDartString();
    } finally {
      bindings.fwc_string_free(p);
    }
  }

  /// 调一个「`(…, out_len) -> ptr`」形态的原生函数，把结果**拷一次**进 Dart 堆并立即释放
  /// 原生缓冲。长度 0 / NULL 返回 null。
  Uint8List? takeBytes(
    ffi.Pointer<ffi.Uint8> Function(ffi.Pointer<ffi.Size> outLen) call,
  ) {
    final ffi.Pointer<ffi.Size> outLen = calloc<ffi.Size>();
    try {
      final ffi.Pointer<ffi.Uint8> ptr = call(outLen);
      final int len = outLen.value;
      if (ptr == ffi.nullptr || len == 0) return null;
      try {
        return Uint8List.fromList(ptr.asTypedListOutOfLine(len));
      } finally {
        bindings.fwc_bytes_free(ptr, len);
      }
    } finally {
      calloc.free(outLen);
    }
  }

  /// [takeBytes] 后按 JSON 解码；NULL 时抛 [StateError]（带 `fwc_last_error` 原因）。
  Object? takeJson(
    ffi.Pointer<ffi.Uint8> Function(ffi.Pointer<ffi.Size> outLen) call,
  ) {
    final Uint8List? bytes = takeBytes(call);
    if (bytes == null) {
      throw StateError(lastError() ?? 'fushi_web_core returned no data');
    }
    return const Utf8Decoder().fuse(const JsonDecoder()).convert(bytes);
  }
}
