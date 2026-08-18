import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:fushi/src/mining/galgame_helper_installer.dart';

/// 注入运行时的**暂存副本**：把会被外部进程长期持有的 hook 组件从安装目录搬出去。
///
/// 根因（BUG-1708）：`fushi_voice_hook.dll` 由 injector 注入进宿主进程后，**由宿主
/// 持有到宿主退出**，我们既不卸载它、也不可能卸载它（还原 detour 失败会让用户正在玩的
/// 游戏当场崩溃，代价不可接受）。LunaHost 注入的 `LunaHook<arch>.dll` 同理。只要宿主
/// 是常驻进程（实测现场：`fushi_voice_hook.dll` 被注进微信，微信连开三天），安装目录下
/// 那几个文件就**永久不可替换**，于是每一次应用内更新都在 Inno 的 `PrepareToInstall`
/// 撞死、整包回滚，而 app 早已为更新退出——用户看到的是「Fushi 自己关了再也没开」。
///
/// 修法不是「更新时检测占用再中止」（那是给症状加分支，而且每新增一个占用源就要加一条
/// 特例），而是**让安装目录里的文件从一开始就不被外部进程持有**：注入前把这一组组件复制
/// 到 app 数据目录下的按内容分版目录，从副本注入。宿主锁的是副本，安装目录始终自由。
///
/// 只搬「会被我们控制不了的进程长期持有」的那几个文件：
/// - `fushi_voice_hook.dll`：注入进宿主，宿主退出前不释放。
/// - `LunaHook<arch>.dll`：由 LunaHost 注入进宿主，同上。
/// - `LunaHost<arch>.dll`、`fushi_voice_injector.exe`：由 injector 进程持有。injector 是
///   我们自己的进程，本可被安装器杀掉，但它必须与上面两者同目录（injector 默认在自身目录
///   找 hook DLL，LunaHost 也在自身目录找 LunaHook），所以一并搬。
/// - x86 的 `LoaderDll.dll` / `LocaleEmulator.dll`：转区路径同目录依赖。
///
/// **不搬** `unity_audio_runtime/`（140 MB，且只被短命的提取子进程用；它的主模块在安装
/// 目录内，安装器的 `KillProcessesUnderDir` 能杀掉它）。injector 改由 `--unity-runtime`
/// 显式接收它在安装目录里的位置。
class GalgameHookRuntimeStage {
  GalgameHookRuntimeStage({
    Directory Function(String arch)? sourceDirectoryOverride,
    Future<Directory> Function()? stageRootOverride,
  })  : _sourceDirectoryOverride = sourceDirectoryOverride,
        _stageRootOverride = stageRootOverride;

  static final GalgameHookRuntimeStage instance = GalgameHookRuntimeStage();

  final Directory Function(String arch)? _sourceDirectoryOverride;
  final Future<Directory> Function()? _stageRootOverride;

  /// 暂存根目录名（app 数据目录下）。与安装目录的 `voice_hook/` 区分开：那是安装器写入
  /// 落点、必须可被安装器整体替换；这里是运行期副本、允许被宿主锁住。
  static const String stageRootName = 'voice_hook_runtime';

  /// 每架构要搬的文件清单（相对源目录）。顺序无关；缺文件即判定该架构不可用。
  static List<String> stagedFilesForArch(String arch) {
    switch (arch) {
      case 'x86':
        return const <String>[
          'fushi_voice_injector.exe',
          'fushi_voice_hook.dll',
          'LunaHook32.dll',
          'LunaHost32.dll',
          'LoaderDll.dll',
          'LocaleEmulator.dll',
        ];
      case 'x64':
        return const <String>[
          'fushi_voice_injector.exe',
          'fushi_voice_hook.dll',
          'LunaHook64.dll',
          'LunaHost64.dll',
        ];
      default:
        return const <String>[];
    }
  }

  /// 正在进行的 stage，按 arch 去重：两条会话路径同时开会话时只复制一次。
  final Map<String, Future<String?>> _inFlight = <String, Future<String?>>{};

  /// 确保该架构的注入运行时副本就绪，返回**副本里的 injector 绝对路径**。
  ///
  /// 失败（源缺文件 / 复制失败 / 非 Windows）返回 null；调用方按「helper 不可用」处理，
  /// 绝不回退到安装目录里的 injector——那正是本修复要消除的占用源，回退等于修了个寂寞。
  Future<String?> ensureStaged({required String arch}) {
    final Future<String?>? pending = _inFlight[arch];
    if (pending != null) return pending;
    final Future<String?> job = _ensureStaged(arch);
    _inFlight[arch] = job;
    return job.whenComplete(() {
      if (identical(_inFlight[arch], job)) _inFlight.remove(arch);
    });
  }

  Future<String?> _ensureStaged(String arch) async {
    if (!Platform.isWindows) return null;
    final List<String> files = stagedFilesForArch(arch);
    if (files.isEmpty) return null;
    try {
      final Directory source = _sourceDirectory(arch);
      if (!source.existsSync()) return null;

      final List<File> sourceFiles = <File>[
        for (final String name in files) File(p.join(source.path, name)),
      ];
      for (final File file in sourceFiles) {
        if (!file.existsSync()) return null;
      }

      final String version = await _contentVersion(sourceFiles);
      final Directory stageRoot = await _stageRoot();
      // 目录结构必须是 `<version>/<arch>/`，不是 `<arch>-<version>/`：
      // [galHookHelperArchTag] 从 injector 路径的**父目录名**认架构，父目录一旦不叫
      // x86/x64，架构标签就静默变成空串（诊断、日志与 helper 校验一起失真）。
      final Directory target = Directory(p.join(stageRoot.path, version, arch));
      final String injectorPath =
          p.join(target.path, 'fushi_voice_injector.exe');

      if (!_stagedCopyIsComplete(target, files, sourceFiles)) {
        await _copyInto(target, files, sourceFiles);
      }
      if (!File(injectorPath).existsSync()) return null;

      // 清理上一版副本。删不掉说明还有宿主进程持有它——那正是我们要容忍的状态，
      // 跳过即可，下次启动再清。
      unawaited(
          _pruneStaleStages(stageRoot, keep: p.join(stageRoot.path, version)));
      return injectorPath;
    } catch (_) {
      return null;
    }
  }

  /// 副本是否已完整落地：逐个文件比对存在性与字节长度。
  ///
  /// 不比对 mtime：复制会重写 mtime，而被宿主锁住的旧副本我们本来就不打算覆盖。长度相同
  /// 即视为同一份内容——目录名已按内容 sha 分版，长度只是防「上次复制到一半被打断」。
  bool _stagedCopyIsComplete(
    Directory target,
    List<String> files,
    List<File> sourceFiles,
  ) {
    if (!target.existsSync()) return false;
    for (int i = 0; i < files.length; i++) {
      final File staged = File(p.join(target.path, files[i]));
      if (!staged.existsSync()) return false;
      if (staged.lengthSync() != sourceFiles[i].lengthSync()) return false;
    }
    return true;
  }

  Future<void> _copyInto(
    Directory target,
    List<String> files,
    List<File> sourceFiles,
  ) async {
    await target.create(recursive: true);
    for (int i = 0; i < files.length; i++) {
      final File destination = File(p.join(target.path, files[i]));
      await destination.parent.create(recursive: true);
      await sourceFiles[i].copy(destination.path);
    }
  }

  /// 内容版本号：各文件 sha256 再哈希一次，取前 16 位十六进制。
  ///
  /// 用内容而不是 `installed.sha256` 标记文件：标记文件记的是分发 zip 的哈希，而应用内
  /// 更新是 Inno 直接覆盖文件、**不重写标记**，用它分版会让新旧两版共用一个副本目录，
  /// 于是被锁住的旧副本永远挡着新版落地。
  Future<String> _contentVersion(List<File> sourceFiles) async {
    final List<int> combined = <int>[];
    for (final File file in sourceFiles) {
      combined.addAll(sha256.convert(await file.readAsBytes()).bytes);
    }
    return sha256.convert(combined).toString().substring(0, 16);
  }

  Future<void> _pruneStaleStages(
    Directory stageRoot, {
    required String keep,
  }) async {
    try {
      if (!stageRoot.existsSync()) return;
      for (final FileSystemEntity entity in stageRoot.listSync()) {
        if (entity is! Directory) continue;
        if (p.equals(entity.path, keep)) continue;
        try {
          await entity.delete(recursive: true);
        } catch (_) {
          // 仍被宿主持有：正常状态，留到下次。
        }
      }
    } catch (_) {
      // 清理是尽力而为，永远不该影响会话启动。
    }
  }

  Directory _sourceDirectory(String arch) {
    final Directory Function(String arch)? override = _sourceDirectoryOverride;
    if (override != null) return override(arch);
    final String exeDir = File(Platform.resolvedExecutable).parent.path;
    return Directory(
      p.join(exeDir, kGalgameHelperInstallDirectoryName, arch),
    );
  }

  Future<Directory> _stageRoot() async {
    final Future<Directory> Function()? override = _stageRootOverride;
    if (override != null) return override();
    final Directory base = await getApplicationSupportDirectory();
    return Directory(p.join(base.path, stageRootName));
  }

  /// 安装目录里 `unity_audio_runtime/` 的绝对路径（140 MB，不进副本）。
  ///
  /// 返回 null = 该架构没有 unity 提取运行时（x86 分发包本就不含），此时不给 injector
  /// 传 `--unity-runtime`，它按无提取能力运行。
  String? unityRuntimeDirectory({required String arch}) {
    if (!Platform.isWindows) return null;
    try {
      final Directory directory = Directory(
        p.join(_sourceDirectory(arch).path, 'unity_audio_runtime'),
      );
      return directory.existsSync() ? directory.path : null;
    } catch (_) {
      return null;
    }
  }
}

/// 供测试断言复制清单与安装包清单一致：暂存清单必须是分发清单的子集，否则会搬出一个
/// 缺依赖的半套运行时（比如漏了 LunaHost，文本 hook 全哑）。
bool stagedFilesAreSubsetOfDistribution(String arch) {
  final Set<String> distribution =
      galgameHelperRequiredFiles(arch).map(p.normalize).toSet();
  return GalgameHookRuntimeStage.stagedFilesForArch(arch)
      .map(p.normalize)
      .every(distribution.contains);
}

/// 仅用于诊断输出/日志：把清单渲染成稳定字符串。
String describeStagedFiles(String arch) => const JsonEncoder()
    .convert(GalgameHookRuntimeStage.stagedFilesForArch(arch));
