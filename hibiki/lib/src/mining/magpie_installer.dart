import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

// 与 galgame helper 安装器共用的**纯工具**（sha256 侧车解析/比对、换入式安装与
// .stale 清扫）。这些函数与 helper 语义无关，只是先在那里落地；此处 show 精确复用，
// 避免第二份实现漂移。
import 'package:hibiki/src/mining/galgame_helper_installer.dart'
    show
        galgameHelperSwapInstall,
        galgameHelperSweepStaleFiles,
        parseSha256Sidecar,
        sha256Matches;

/// 统一日志出口。安装器全程无 UI、无网络；失败若只剩一个 enum，用户报「装不上」时
/// 根本无从判断卡在随包归档、校验还是解压 —— 关键路径必须留痕。
/// 与同目录 `galgame_cover_download.dart` 同范式（带模块前缀的 debugPrint）。
void _log(String message) => debugPrint('[magpie] $message');

/// fork 的上游基线版本（仅用于展示与问题定位，不参与任何判定；是否需要更新一律以 sha256
/// 侧车与当前 Hibiki 随包归档为准）。
const String kMagpieUpstreamVersion = 'v0.12.1';

/// 本客户端**已验证过**的 Magpie 配置 schema 版本（上游 `src/Magpie/AppSettings.cpp` 的
/// `CONFIG_VERSION`，v0.12.1 时为 4）。见 [magpieCanWritePortableConfig] 说明。
const int kMagpieKnownConfigVersion = 4;

/// 安装包内我们自己塞的元数据文件名（由 fork 的 release workflow 生成）。它是我们与 Magpie
/// 私有实现之间唯一的契约面：带 upstreamVersion / forkCommit / configVersion。
const String kMagpieMetadataName = 'hibiki-magpie.json';

/// 便携模式标记文件的位置（相对安装目录）。Magpie 在 `AppSettings::Initialize()` 里
/// **只判断 exe 同级 `config\config.json` 是否存在**来决定便携模式，不看内容。
const String kMagpieConfigDirName = 'config';
const String kMagpieConfigFileName = 'config.json';

/// 安装目录名（落在 `Hibiki.exe` 同级）。
const String kMagpieInstallDirName = 'magpie';

/// Windows 主包内随附的 **精简版** Magpie 归档目录名（落在 `Hibiki.exe` 同级）。
///
/// 与安装落点 [kMagpieInstallDirName] 刻意不同名：一个是「发行介质」，一个是「装好的
/// 东西」，同名会让「装到一半」和「归档本身」在同一个目录里纠缠不清。范式同 galgame
/// helper 的 `galgame_helper/`（归档） vs `voice_hook/`（落点）。
const String kMagpieBundledDirectoryName = 'magpie_bundle';

/// 随包精简归档的文件名。**带 `slim` 是契约的一部分**：它与构建输入的完整包内容不同
/// （裁掉了 145 个用不到的 effect 文件，10.79 MB → 4.72 MB）。
String magpieBundledZipName(String arch) => 'Magpie-hibiki-slim-$arch.zip';

/// 校验安装完整性用的根文件清单。**只列缩放真正必需的三个**：主程序、WinUI 运行时、资源
/// 索引。上游包里另有 `TouchHelper.exe`（只服务触摸）与 `Updater.exe`（Magpie 自己的自更新
/// 器，与 Hibiki 随包交付的版本边界冲突，fork 里随时可能剔除）—— 把它们列进必需清单只会在
/// 我们精简产物时把客户端打红，故不列。
const List<String> kMagpieRequiredRootFiles = <String>[
  'Magpie.exe',
  'Microsoft.UI.Xaml.dll',
  'resources.pri',
];

/// 校验安装完整性用的必需子目录：缺 `effects` 就没有任何缩放算法可用，装了等于没装。
const List<String> kMagpieRequiredDirs = <String>['effects'];

/// 已装版本标记文件名：装成功后写入随包 zip 的 sha256，供诊断与损坏排查。
String magpieMarkerName() => 'installed.sha256';

/// Windows 主包只携带 x64 精简包，安装路径**恒取它**。ARM64 Windows 通过系统的 x64
/// 模拟运行同一份产物，不再有第二个切片，所以也不再需要探测机器架构：BUG-1292 之前
/// 的 `magpieArchForProcessorArchitecture` / `magpieCurrentArch` 只服务于「按架构选下载
/// URL」，下载链路删掉后它们就是死代码，一并删除（想恢复架构分发得先恢复第二个随包
/// 切片，那是构建侧的事）。
const String kMagpieBundledArch = 'x64';

/// 返回缺少的必需根文件名；按 Windows 规则忽略大小写。
List<String> magpieMissingFiles(Iterable<String> presentFiles) {
  final Set<String> present =
      presentFiles.map((String name) => name.toLowerCase()).toSet();
  return kMagpieRequiredRootFiles
      .where((String name) => !present.contains(name.toLowerCase()))
      .toList(growable: false);
}

/// 便携模式标记文件的内容：**空字符串，故意的**。
///
/// Magpie 只用「exe 同级 `config\config.json` 是否存在」判定便携模式，不看内容；而读到
/// 空文件时会走 `configText.empty()` 分支，自己灌入全套默认配置（含 7 个默认 scalingModes）
/// 再回存。
///
/// 反过来，写一个看似无害的 `{}` 会被 Magpie 当成「有效但没有 scalingModes 的配置」——
/// 于是 scalingModes 数组为空，所有 profile 的 `scalingMode` 索引被钳到 -1，缩放直接报
/// `InvalidScalingMode`。**空文件才是对的**：它同时实现了「隔离」和「零 schema 猜测」，
/// 我们一个 Magpie 私有字段都不用写。
String magpiePortableConfigContent() => '';

/// 安装包元数据（fork 的 release workflow 写进 zip 根的 [kMagpieMetadataName]）。
@immutable
class MagpiePackageMetadata {
  const MagpiePackageMetadata({
    required this.upstreamVersion,
    required this.forkCommit,
    required this.configVersion,
  });

  /// fork 基于的上游版本（如 `v0.12.1`）；缺失为空串。
  final String upstreamVersion;

  /// 构建所用 fork commit SHA；缺失为空串。
  final String forkCommit;

  /// 该产物源码里的 `CONFIG_VERSION`；解析不出为 null。
  final int? configVersion;

  /// 从元数据 JSON 文本解析；**任何异常都吞掉返回 null**（元数据是锦上添花，缺失或损坏
  /// 只降级为「只装不配」，绝不让安装失败）。
  static MagpiePackageMetadata? parse(String? content) {
    if (content == null) return null;
    // 剥掉可能的 UTF-8 BOM：Dart 的 utf8 解码不会吃掉 U+FEFF，而 jsonDecode 见到它就抛
    // FormatException —— 那会被下面的 catch 静默吞成 null，表现为「明明发了元数据却永远
    // 只装不配」。当前 workflow 用 pwsh 7 写出的是无 BOM UTF-8（已实测），但写入端一旦
    // 换成 Windows PowerShell 5.1 就会带 BOM，这里挡住这类静默降级。
    final String text =
        content.startsWith('﻿') ? content.substring(1) : content;
    if (text.trim().isEmpty) return null;
    try {
      final Object? decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) return null;
      final Object? version = decoded['configVersion'];
      final Object? upstream = decoded['upstreamVersion'];
      final Object? commit = decoded['forkCommit'];
      return MagpiePackageMetadata(
        upstreamVersion: upstream is String ? upstream : '',
        forkCommit: commit is String ? commit : '',
        configVersion: version is int
            ? version
            : (version is String ? int.tryParse(version) : null),
      );
    } catch (e) {
      _log('metadata parse failed: $e');
      return null;
    }
  }
}

/// 是否可以安全地写便携标记：**只有**包内元数据明确声明的 configVersion 与本客户端已验证
/// 的 [kMagpieKnownConfigVersion] 一致时才写。
///
/// 我们写的是空文件、不含任何 Magpie 私有字段，所以这个门守的**不是内容**，而是「便携模式
/// 的判定机制本身」：万一上游哪天把便携标记挪到 `config\v5\config.json` 之类，configVersion
/// 的变化就是最早能观察到的信号，此时退回「只装不配」（Magpie 仍能装、能跑，只是配置落
/// `%LOCALAPPDATA%`，与用户自己的 Magpie 共用）总比装一个假的隔离要诚实。
bool magpieCanWritePortableConfig(MagpiePackageMetadata? metadata) =>
    metadata?.configVersion == kMagpieKnownConfigVersion;

/// 一次 [MagpieInstaller.ensureInstalled] 的结果。
enum MagpieInstallResult {
  /// 非 Windows：Magpie 是 Windows 独占（D3D11 + WinUI）。
  unsupportedPlatform,

  /// 本来就装好了（零网络、零 UI）。
  alreadyInstalled,

  /// 本轮从主包随附归档安装成功。
  installed,

  /// 当前 Hibiki 构建缺少随包归档。用户应更新/重装 Hibiki，不允许联网补取。
  bundleMissing,

  /// **完整性校验失败**：随包 zip/侧车缺一，或 zip 与侧车摘要不符。
  verificationFailed,

  /// 校验通过之后的步骤失败（解压 / staging 清单不全 / 换入 / 复检）。调用方降级即可，绝不崩。
  failed,
}

/// 安装失败的分类载体：把「哪一步炸的」从 [MagpieInstaller] 内部一路带到
/// [MagpieInstaller.ensureInstalled] 的返回值，免得调用方只看得到一个笼统的 failed。
@immutable
class MagpieInstallException implements Exception {
  const MagpieInstallException(this.result, this.message);

  /// 该失败对应的对外结果枚举。
  final MagpieInstallResult result;

  /// 人类可读的失败原因（已写进日志，这里再带一份便于上层拼提示）。
  final String message;

  @override
  String toString() => 'MagpieInstallException(${result.name}): $message';
}

/// 校验前置门：拿不到随包归档的可信 sha256 就**放弃安装**。
///
/// 抽成顶层函数是为了在任何平台都能被测（真实安装路径只在 Windows 跑）。
String magpieRequireVerifiedSha(String? sha, String arch) {
  final String? parsed = sha == null ? null : parseSha256Sidecar(sha);
  if (parsed == null) {
    throw MagpieInstallException(
      MagpieInstallResult.verificationFailed,
      '$arch: bundled sha256 sidecar missing or invalid; '
      'refusing to install an unverified package',
    );
  }
  return parsed;
}

/// Magpie（窗口超分）的随包安装器。
///
/// 与 galgame helper 安装器同范式：只认主包随附 zip + sha256 侧车，经过 staging 校验和
/// 换入式安装（旧文件 rename 让位）。缺包、损坏或旧构建一律提示更新 Hibiki，绝不联网。
/// 落点是 `Hibiki.exe` 同级的 `magpie\`（安装器 `PrivilegesRequired=lowest`，此目录用户
/// 可写、免提权）。
class MagpieInstaller {
  MagpieInstaller({Directory? bundledDirectory, bool? isWindowsOverride})
      : _bundledDirectoryOverride = bundledDirectory,
        _isWindows = isWindowsOverride ?? Platform.isWindows;

  /// 仅测试注入：主包随附归档目录（生产恒为 `Hibiki.exe` 同级的 `magpie_bundle/`）。
  final Directory? _bundledDirectoryOverride;

  /// 平台判定的**唯一**入口，仅测试注入（生产恒为 [Platform.isWindows]）。
  ///
  /// 与 [MagpieUpscalingService] 的同名开关成对：服务侧声明「按 Windows 跑」时，
  /// 安装器必须跟着走同一条路径。否则服务以为在演 Windows、安装器却按真实宿主
  /// 直接返回 [MagpieInstallResult.unsupportedPlatform]，测试在 Windows 上绿、
  /// 在 Linux CI 上红——平台泄漏，不是功能差异。
  final bool _isWindows;

  /// 换入是唯一与「读取安装目录」竞态的写窗口（亚秒级本地文件操作），全部串到这条门上；
  /// 校验/解压只碰临时目录，无需互斥。
  static Future<void> _installGate = Future<void>.value();

  static Future<T> _serializeInstall<T>(Future<T> Function() job) {
    final Future<T> run = _installGate.then((_) => job());
    _installGate = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  /// `Hibiki.exe` 同级的 `magpie\` 安装目录。
  static Directory installDirectory() {
    final String exeDir = File(Platform.resolvedExecutable).parent.path;
    return Directory(p.join(exeDir, kMagpieInstallDirName));
  }

  /// 已安装的 `Magpie.exe` 绝对路径（不保证存在；调用方自己判 existsSync）。
  static String executablePath() =>
      p.join(installDirectory().path, 'Magpie.exe');

  /// 便携标记文件路径 `<install>\config\config.json`。
  static String portableConfigPath() => p.join(
        installDirectory().path,
        kMagpieConfigDirName,
        kMagpieConfigFileName,
      );

  static File _markerFile() =>
      File(p.join(installDirectory().path, magpieMarkerName()));

  /// 主包内随附归档所在目录（`Hibiki.exe` 同级的 `magpie_bundle/`）。
  Directory _bundledDirectory() {
    final Directory? override = _bundledDirectoryOverride;
    if (override != null) return override;
    return Directory(
      p.join(
        File(Platform.resolvedExecutable).parent.path,
        kMagpieBundledDirectoryName,
      ),
    );
  }

  /// 安装目录当前缺什么（必需根文件 + 必需子目录）。返回空表示安装完整。
  static List<String> missingInstalledEntries() {
    final Directory dir = installDirectory();
    if (!dir.existsSync()) {
      return <String>[...kMagpieRequiredRootFiles, ...kMagpieRequiredDirs];
    }
    final Iterable<String> rootFiles = dir
        .listSync(followLinks: false)
        .whereType<File>()
        .map((File file) => p.basename(file.path));
    final List<String> missing = <String>[...magpieMissingFiles(rootFiles)];
    for (final String required in kMagpieRequiredDirs) {
      final Directory sub = Directory(p.join(dir.path, required));
      final bool ok = sub.existsSync() &&
          sub.listSync(followLinks: false).whereType<File>().isNotEmpty;
      if (!ok) missing.add(required);
    }
    return missing;
  }

  /// 是否已完整安装（零网络、零副作用；调用方可随手问）。
  static bool isInstalled() => missingInstalledEntries().isEmpty;

  /// 确保 Magpie 就位。
  ///
  /// - 非 Windows → [MagpieInstallResult.unsupportedPlatform]；
  /// - 已完整安装 → [MagpieInstallResult.alreadyInstalled]；
  /// - 未安装或残缺 → 只从主包随附归档安装/修复；
  /// - 缺归档 → [MagpieInstallResult.bundleMissing]，绝不联网补取。
  Future<MagpieInstallResult> ensureInstalled({String? arch}) async {
    if (!_isWindows) return MagpieInstallResult.unsupportedPlatform;
    final String targetArch = arch ?? kMagpieBundledArch;
    // 等在途换入落定再检查文件，绝不读到半换入状态；平时门是已完成 future，零开销。
    await _installGate;
    galgameHelperSweepStaleFiles(installDirectory());

    if (missingInstalledEntries().isEmpty) {
      return MagpieInstallResult.alreadyInstalled;
    }

    try {
      if (!await _installBundledMagpie(targetArch)) {
        _log('bundled archive missing ($targetArch)');
        return MagpieInstallResult.bundleMissing;
      }
    } on MagpieInstallException catch (e) {
      _log('bundled install rejected ($targetArch): $e');
      return e.result;
    } catch (e) {
      _log('bundled install failed ($targetArch): $e');
      return MagpieInstallResult.failed;
    }
    final List<String> missingAfter = missingInstalledEntries();
    if (missingAfter.isNotEmpty) {
      _log('install finished but incomplete ($targetArch): '
          'missing ${missingAfter.join(', ')}');
      return MagpieInstallResult.failed;
    }
    return MagpieInstallResult.installed;
  }

  /// 从主包随附的精简归档安装（零网络）。
  ///
  /// 返回 false 只表示当前构建没有随附该归档（开发构建、旧包）；只要 zip 或侧车任一
  /// 存在，就必须完整校验。调用方只报告缺包/损坏，不允许回退网络。
  Future<bool> _installBundledMagpie(String arch) async {
    final Directory bundle = _bundledDirectory();
    final File zip = File(p.join(bundle.path, magpieBundledZipName(arch)));
    final File sidecar = File('${zip.path}.sha256');
    final bool hasZip = zip.existsSync();
    final bool hasSidecar = sidecar.existsSync();
    if (!hasZip && !hasSidecar) return false;
    if (!hasZip || !hasSidecar) {
      throw MagpieInstallException(
        MagpieInstallResult.verificationFailed,
        'bundled magpie incomplete ($arch): zip=$hasZip sidecar=$hasSidecar',
      );
    }

    final String sha =
        magpieRequireVerifiedSha(await sidecar.readAsString(), arch);
    final String actual = sha256.convert(await zip.readAsBytes()).toString();
    if (!sha256Matches(sha, actual)) {
      throw MagpieInstallException(
        MagpieInstallResult.verificationFailed,
        'bundled magpie sha256 mismatch ($arch): expected $sha, actual $actual',
      );
    }

    await _installVerifiedZip(
      arch: arch,
      zip: zip,
      sha: sha,
    );
    return true;
  }

  /// 测试入口：跑通随包校验 → 清单 → 换入 → 标记全链路，不经网络也不经 UI。
  @visibleForTesting
  Future<bool> installBundledMagpieForTesting(String arch) =>
      _installBundledMagpie(arch);

  /// 已通过 SHA-256 的随包 zip 安装尾段：解压 staging → 清单验证 → 原子换入 →
  /// 写标记 → 便携配置。
  Future<void> _installVerifiedZip({
    required String arch,
    required File zip,
    required String sha,
  }) async {
    final Directory staging =
        await Directory.systemTemp.createTemp('hibiki_magpie_staging_');
    try {
      final Set<String> rootFiles = await _extractZip(zip, staging);
      final List<String> missingFromPackage = magpieMissingFiles(rootFiles);
      if (missingFromPackage.isNotEmpty) {
        throw StateError(
          'magpie package incomplete ($arch): '
          'missing ${missingFromPackage.join(', ')}',
        );
      }

      // 元数据必须在换入**之前**从 staging 读——换入会把 staging 里的文件搬空。
      final MagpiePackageMetadata? metadata = await readStagedMetadata(staging);

      await _serializeInstall(() => galgameHelperSwapInstall(
            staging: staging,
            target: installDirectory(),
          ));

      final List<String> missingAfter = missingInstalledEntries();
      if (missingAfter.isNotEmpty) {
        throw StateError(
          'magpie install incomplete ($arch): '
          'missing ${missingAfter.join(', ')}',
        );
      }

      try {
        await _markerFile().writeAsString(sha, flush: true);
      } catch (e) {
        // 标记写不成只影响诊断，不影响这次安装可用性。
        _log('marker write failed ($arch): $e');
      }

      await ensurePortableConfig(metadata: metadata);
      _log('installed $arch from bundled archive (sha256 $sha)');
    } finally {
      try {
        if (staging.existsSync()) staging.deleteSync(recursive: true);
      } catch (e) {
        _log('staging cleanup failed ($arch): $e');
      }
    }
  }

  /// 从 staging 读安装包元数据；缺失/损坏返回 null。
  @visibleForTesting
  Future<MagpiePackageMetadata?> readStagedMetadata(Directory staging) async {
    final File file = File(p.join(staging.path, kMagpieMetadataName));
    if (!file.existsSync()) return null;
    try {
      return MagpiePackageMetadata.parse(await file.readAsString());
    } catch (e) {
      _log('metadata read failed: $e');
      return null;
    }
  }

  /// **best-effort** 写便携模式标记（空的 `config\config.json`，见
  /// [magpiePortableConfigContent]）：
  /// - 已存在 config.json → 一律不动（Magpie 跑过之后会把真实配置写进去，覆盖等于毁配置）；
  /// - 元数据缺失 / configVersion 与 [kMagpieKnownConfigVersion] 不一致 → 「只装不配」，
  ///   返回 false；
  /// - 写失败 → 吞掉返回 false。安装本身不因为标记写不成而失败。
  ///
  /// 返回是否真的写了标记。[installDir] 仅测试注入用。
  Future<bool> ensurePortableConfig({
    required MagpiePackageMetadata? metadata,
    Directory? installDir,
  }) async {
    if (!magpieCanWritePortableConfig(metadata)) return false;
    try {
      final Directory root = installDir ?? installDirectory();
      final File config = File(
        p.join(root.path, kMagpieConfigDirName, kMagpieConfigFileName),
      );
      if (config.existsSync()) return false;
      await config.parent.create(recursive: true);
      await config.writeAsString(magpiePortableConfigContent(), flush: true);
      return true;
    } catch (e) {
      _log('portable config write failed: $e');
      return false;
    }
  }

  /// 解压 zip 到 [targetDir]（staging 临时目录，**不**直接写安装目录），返回 zip 根层的
  /// 文件名集合。用 archive 包 ZipDecoder；写字节取 `entry.content`（archive 3.6.1 下
  /// `ArchiveFile.decompress(out)` 会写 0 字节）。只写常规文件、保留相对目录结构，并拒绝
  /// 绝对路径或逃出目标目录的条目以防 zip-slip。
  @visibleForTesting
  Future<Set<String>> extractZip(File zip, Directory targetDir) =>
      _extractZip(zip, targetDir);

  Future<Set<String>> _extractZip(File zip, Directory targetDir) async {
    await targetDir.create(recursive: true);
    final Uint8List bytes = await zip.readAsBytes();
    final Archive archive = ZipDecoder().decodeBytes(bytes);
    final String targetRoot = p.normalize(targetDir.absolute.path);
    final Set<String> rootFiles = <String>{};
    for (final ArchiveFile entry in archive) {
      if (!entry.isFile) continue;
      final String relativePath =
          entry.name.replaceAll('/', p.separator).replaceAll('\\', p.separator);
      if (relativePath.isEmpty || p.isAbsolute(relativePath)) {
        _log('extract: skipped absolute/empty entry "${entry.name}"');
        continue;
      }
      final String outputPath = p.normalize(p.join(targetRoot, relativePath));
      if (!p.isWithin(targetRoot, outputPath)) {
        _log('extract: skipped zip-slip entry "${entry.name}"');
        continue;
      }
      final Object? content = entry.content;
      if (content is! List<int>) {
        _log('extract: skipped unreadable entry "${entry.name}"');
        continue;
      }
      final File out = File(outputPath);
      await out.parent.create(recursive: true);
      await out.writeAsBytes(content, flush: true);
      if (p.dirname(relativePath) == '.') {
        rootFiles.add(p.basename(relativePath));
      }
    }
    return rootFiles;
  }
}
