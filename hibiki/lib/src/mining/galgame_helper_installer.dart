import 'dart:async';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'package:hibiki/utils.dart';

/// 统一日志出口（与同目录 `magpie_installer.dart` 的 `[magpie]` 同范式）。安装路径对用户
/// 只有一句笼统 toast；报「装不上」时若这里零留痕，根本无从判断卡在校验、清单还是换入 ——
/// 供应链每一步都必须能事后定位。
void _log(String message) => debugPrint('[gal-helper] $message');

/// Windows 主包内随附的 helper 归档目录名。发布 workflow 把两架构 zip 与各自 `.sha256`
/// 侧车复制到 `hibiki.exe` 同级的这个目录，Inno Setup 递归纳入安装包。helper 仍是独立
/// 子进程/DLL，不链接进 `Hibiki.exe`；这里只改变交付介质，让首装不依赖网络。
const String kGalgameHelperBundledDirectoryName = 'galgame_helper';

/// 按目标游戏位数选注入器架构目录名：32 位游戏→x86，否则→x64（注入 DLL 位数必须匹配目标进程）。
String galgameHelperArch({required bool is32Bit}) => is32Bit ? 'x86' : 'x64';

/// helper 发布包根目录清单。必须与
/// `.github/workflows/voice-hook-helper.yml` 保持一致。
List<String> galgameHelperRequiredFiles(String arch) {
  switch (arch) {
    case 'x86':
      return const <String>[
        'hibiki_voice_injector.exe',
        'hibiki_voice_hook.dll',
        'LunaHook32.dll',
        'LunaHost32.dll',
        'LoaderDll.dll',
        'LocaleEmulator.dll',
        'LocaleEmulator-LGPL-3.0.txt',
      ];
    case 'x64':
      return const <String>[
        'hibiki_voice_injector.exe',
        'hibiki_voice_hook.dll',
        'LunaHook64.dll',
        'LunaHost64.dll',
        'unity_audio_runtime/hibiki_unity_audio_extract.exe',
        'unity_audio_runtime/classdata.tpk',
        'unity_audio_runtime/vgmstream-cli.exe',
        'unity_audio_runtime/avcodec-vgmstream-59.dll',
        'unity_audio_runtime/avformat-vgmstream-59.dll',
        'unity_audio_runtime/avutil-vgmstream-57.dll',
        'unity_audio_runtime/swresample-vgmstream-4.dll',
        'unity_audio_runtime/libatrac9.dll',
        'unity_audio_runtime/libcelt-0061.dll',
        'unity_audio_runtime/libcelt-0110.dll',
        'unity_audio_runtime/libg719_decode.dll',
        'unity_audio_runtime/libmpg123-0.dll',
        'unity_audio_runtime/libspeex-1.dll',
        'unity_audio_runtime/libvorbis.dll',
        'unity_audio_runtime/COPYING',
      ];
    default:
      throw ArgumentError.value(arch, 'arch', 'unsupported helper arch');
  }
}

/// 返回缺少的 helper 必需文件名；按 Windows 规则忽略文件名大小写。
List<String> galgameHelperMissingFiles(
  String arch,
  Iterable<String> presentFiles,
) {
  final Set<String> present =
      presentFiles
          .map((String name) => name.replaceAll('\\', '/').toLowerCase())
          .toSet();
  return galgameHelperRequiredFiles(arch)
      .where((String name) =>
          !present.contains(name.replaceAll('\\', '/').toLowerCase()))
      .toList(growable: false);
}

/// 某架构的分发 zip 文件名（与 CI workflow 打包命名一一对应）。
String galgameHelperZipName(String arch) => 'voice_hook_$arch.zip';

/// 从 .sha256 侧车文本里解析出 64 位十六进制摘要（小写）。侧车可能是纯摘要、也可能是
/// `<hash>  <filename>` 形式，故取第一个 64-hex token，容错空白/换行。无合法摘要返回 null。
String? parseSha256Sidecar(String content) {
  final RegExp re = RegExp(r'\b[0-9a-fA-F]{64}\b');
  final RegExpMatch? m = re.firstMatch(content);
  return m?.group(0)?.toLowerCase();
}

/// 两个 sha256 摘要是否相等（去空白、大小写无关）。
bool sha256Matches(String expected, String actual) =>
    expected.trim().toLowerCase() == actual.trim().toLowerCase();

/// 一次 helper 安装尝试的失败分类。
///
/// BUG-1196 删掉网络下载后只剩两档，但仍必须分开：**无法证明可信**（绝不能装，重装无用，
/// 得修发布产物）与「校验过了但后续步骤炸了」（换入被占用等，重试可能有用）。
enum GalgameHelperInstallFailure {
  /// **完整性校验失败**：随包侧车缺失/内容非法，或随包 zip 与侧车摘要不符。语义是
  /// 「东西不可信」或「无法证明可信」，此时一律**不安装** —— 这个包里是要注入用户
  /// 游戏进程的原生代码。
  verificationFailed,

  /// 校验通过之后的步骤失败（解压 / staging 清单不全 / 换入 / 复检）。
  installFailed,
}

/// 安装失败的分类载体：把「哪一步炸的」从安装核心一路带到 UI 层，免得三条调用路径只看得到
/// 一个笼统的 false。
@immutable
class GalgameHelperInstallException implements Exception {
  const GalgameHelperInstallException(this.failure, this.message);

  /// 该失败对应的分类。
  final GalgameHelperInstallFailure failure;

  /// 人类可读的失败原因（已写进日志，这里再带一份便于上层拼提示）。
  final String message;

  @override
  String toString() =>
      'GalgameHelperInstallException(${failure.name}): $message';
}

/// 校验前置门：拿不到可信 sha256 就**放弃安装**（抛 [GalgameHelperInstallException]）。
///
/// 这是本安装器的安全底线。产物如今只来自随主包发布的归档，但校验一步都不能省：装进去的
/// 是 injector.exe + 会被注入用户游戏进程的 hook DLL，被换掉一次就是任意代码执行。侧车缺
/// 失或摘要对不上一律拒装，绝不降级成「只看文件在不在」。
///
/// 抽成顶层函数是为了在任何平台都能被测（真实安装路径只在 Windows 跑）。
String galgameHelperRequireVerifiedSha(String? sha, String arch) {
  final String? parsed = sha == null ? null : parseSha256Sidecar(sha);
  if (parsed == null) {
    throw GalgameHelperInstallException(
      GalgameHelperInstallFailure.verificationFailed,
      '$arch: no trusted sha256 sidecar (direct GitHub only); '
      'refusing to install an unverified injector/hook package',
    );
  }
  return parsed;
}

/// 已装 helper 的版本标记文件名：装成功后在 `voice_hook/<arch>/` 写入该 zip 的 sha256。
/// 自更新已删（BUG-1196），它现在纯粹是「这份 helper 是哪个包装的」的可诊断痕迹；随包
/// 摘要变化时 `ensureInjector` 走的是清单缺失判据，不读它。放在 arch 目录内随 helper 一起清理。
String galgameHelperMarkerName() => 'installed.sha256';

/// 换入时旧文件的改名后缀：`<name>.stale`（占用时递增 `.stale1`…）。被进程映射的 DLL
/// 在 Windows 下**可改名不可覆盖**，改名让位是被占用文件的唯一安全换法。
const String kGalgameHelperStaleSuffix = '.stale';

/// 匹配换入残骸文件名（`x.dll.stale` / `x.dll.stale2`）。
final RegExp kGalgameHelperStalePattern = RegExp(r'\.stale\d*$');

/// 清扫 [dir] 里上轮换入留下的 `*.stale*` 残骸（当时被进程占用删不掉的旧文件）。
/// best-effort：仍被占用的留给下轮。
void galgameHelperSweepStaleFiles(Directory dir) {
  if (!dir.existsSync()) return;
  for (final FileSystemEntity entity
      in dir.listSync(recursive: true, followLinks: false)) {
    if (entity is File &&
        kGalgameHelperStalePattern.hasMatch(p.basename(entity.path))) {
      try {
        entity.deleteSync();
      } catch (_) {}
    }
  }
}

/// 一次换入操作的账目：换入的新文件路径 + 旧文件让位后的路径（原位无旧文件则 null）。
class _GalgameHelperSwapOp {
  const _GalgameHelperSwapOp({required this.newPath, required this.asidePath});
  final String newPath;
  final String? asidePath;
}

/// staging → target 的**换入式安装**（首装/修复/后台更新三条路径共用）：逐文件先把 target
/// 里的旧文件 rename 成 `.stale` 让位（被映射的 DLL 可改名不可覆盖——旧实现就地覆盖写，
/// 撞上被占用的 `hibiki_voice_hook.dll` 会半途失败留下混版本残局，是 BUG-1076 的次生根因），
/// 再把 staging 的新文件 rename 进来（跨卷退化为 copy+delete）。任何一步失败即逆序回滚：
/// 删掉已换入的新文件、把 `.stale` 改回原名——target 要么完整旧版要么完整新版，绝无混版本。
/// 成功后 best-effort 清 `.stale`（被占用的留给下轮 [galgameHelperSweepStaleFiles]）。
/// [onBeforeReplace] 仅测试注入失败用。
Future<void> galgameHelperSwapInstall({
  required Directory staging,
  required Directory target,
  void Function(String relativePath)? onBeforeReplace,
}) async {
  await target.create(recursive: true);
  final String stagingRoot = p.normalize(staging.absolute.path);
  final String targetRoot = p.normalize(target.absolute.path);
  final List<File> newFiles = staging
      .listSync(recursive: true, followLinks: false)
      .whereType<File>()
      .toList();
  final List<_GalgameHelperSwapOp> done = <_GalgameHelperSwapOp>[];
  try {
    for (final File src in newFiles) {
      final String rel = p.relative(src.path, from: stagingRoot);
      onBeforeReplace?.call(rel);
      final File dst = File(p.join(targetRoot, rel));
      await dst.parent.create(recursive: true);
      String? asidePath;
      if (dst.existsSync()) {
        File aside = File('${dst.path}$kGalgameHelperStaleSuffix');
        try {
          if (aside.existsSync()) aside.deleteSync();
        } catch (_) {}
        int n = 0;
        while (aside.existsSync()) {
          n++;
          aside = File('${dst.path}$kGalgameHelperStaleSuffix$n');
        }
        dst.renameSync(aside.path);
        asidePath = aside.path;
      }
      try {
        src.renameSync(dst.path);
      } on FileSystemException {
        // systemTemp 与安装目录不同卷时 rename 会失败：退化为 copy+delete。
        src.copySync(dst.path);
        try {
          src.deleteSync();
        } catch (_) {}
      }
      done.add(_GalgameHelperSwapOp(newPath: dst.path, asidePath: asidePath));
    }
  } catch (_) {
    for (final _GalgameHelperSwapOp op in done.reversed) {
      try {
        File(op.newPath).deleteSync();
      } catch (_) {}
      final String? aside = op.asidePath;
      if (aside != null) {
        try {
          File(aside).renameSync(op.newPath);
        } catch (_) {}
      }
    }
    rethrow;
  }
  for (final _GalgameHelperSwapOp op in done) {
    final String? aside = op.asidePath;
    if (aside != null) {
      try {
        File(aside).deleteSync();
      } catch (_) {}
    }
  }
}

/// 缺失注入器时的安装器：**唯一来源**是 Windows 主包内 `galgame_helper/` 的已校验归档，
/// 零网络、零确认框（BUG-1196）。落点是 exe 同级 `voice_hook/<arch>/`。仅 Windows；
/// 随包归档缺失或校验不过一律返回 false（调用方中止启动、已给提示，Never break）。
///
/// 🔴 **本安装器不联网，也不要再给它加联网路径**。helper 是会被注入用户游戏进程的
/// injector exe + hook DLL，换掉一次即任意代码执行（BUG-1103）。既然两架构 zip 已随
/// Windows 主包发布，就不该再保留一条「后台静默从网上取原生代码并注入」的通道 ——
/// 那条通道的攻击面远大于它换来的便利。helper 版本从此与 app 版本强绑定：要新 helper
/// 就更新 app，不再有独立于 app 的 helper 自更新，也就不再有版本漂移。
class GalgameHelperInstaller {
  GalgameHelperInstaller({
    Directory? bundledDirectory,
    Directory Function(String arch)? installDirectory,
  })  : _bundledDirectoryOverride = bundledDirectory,
        _installDirectoryOverride = installDirectory;

  final Directory? _bundledDirectoryOverride;
  final Directory Function(String arch)? _installDirectoryOverride;

  /// 游戏启动路径唯一的共享写窗口是「换入」（亚秒级本地文件操作）。所有换入都串到这条
  /// 门上、启动路径检查文件前也先过门，二者绝不与半换入状态竞态；解压只碰临时目录，
  /// 无需互斥。
  static Future<void> _extractionGate = Future<void>.value();

  /// 把 [job]（换入操作）串行挂到 [_extractionGate] 上执行。
  static Future<T> _serializeExtraction<T>(Future<T> Function() job) {
    final Future<T> run = _extractionGate.then((_) => job());
    _extractionGate = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  /// exe 同级的 `voice_hook/<arch>` 目录（安装器写入落点，与 defaultInjectorResolver /
  /// GalHookSessionController 注入器解析的读取落点一致）。安装包 Inno Setup
  /// 默认装到 {localappdata}\Hibiki（PrivilegesRequired=lowest），此目录用户可写、无需提权。
  Directory _archDir(String arch) {
    final Directory Function(String arch)? override = _installDirectoryOverride;
    if (override != null) return override(arch);
    final String exeDir = File(Platform.resolvedExecutable).parent.path;
    return Directory(p.join(exeDir, 'voice_hook', arch));
  }

  Directory _bundledDirectory() {
    final Directory? override = _bundledDirectoryOverride;
    if (override != null) return override;
    final String exeDir = File(Platform.resolvedExecutable).parent.path;
    return Directory(p.join(exeDir, kGalgameHelperBundledDirectoryName));
  }

  /// 目标架构已装版本标记文件（内容 = 已装 zip 的 sha256）。
  File _markerFile(String arch) =>
      File(p.join(_archDir(arch).path, galgameHelperMarkerName()));

  List<String> _missingInstalledFiles(String arch) {
    final Directory dir = _archDir(arch);
    if (!dir.existsSync()) {
      return galgameHelperRequiredFiles(arch);
    }
    final Iterable<String> present = dir
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()
        .map((File file) =>
            p.relative(file.path, from: dir.path).replaceAll('\\', '/'));
    return galgameHelperMissingFiles(arch, present);
  }

  /// 确保对应架构注入器就位。**全程零网络、零确认框**（BUG-1196）：
  /// - 完整安装 → true；
  /// - 缺失或残缺（旧装只有 injector、缺 Luna 或 Locale Emulator）→ 用随主包发布的
  ///   已校验归档安装/修复 → 复检通过 true；
  /// - 随包归档缺失（开发构建 / 早于随包发布的旧包）或校验、换入失败 → false
  ///   （调用方中止启动，已给提示）。
  ///
  /// 为什么残缺也走同一条路而不是「补齐差的那几个文件」：归档是整包按 SHA-256 钉死的，
  /// 逐文件补齐等于放弃整包校验。x86 缺转区组件时尤其不得放行 —— 那会让非 Unicode
  /// 游戏在普通区域下启动（乱码 / 读不到资源，正是 BUG-1059 的症状）。
  Future<bool> ensureInjector({
    required bool is32Bit,
    required BuildContext context,
  }) async {
    if (!Platform.isWindows) return false;
    final String arch = galgameHelperArch(is32Bit: is32Bit);
    // 等在途换入（若有）落定再检查文件，绝不读到半换入状态；平时门是已完成 future，零开销。
    await _extractionGate;
    if (!context.mounted) return false;
    if (_missingInstalledFiles(arch).isEmpty) return true;

    // Windows 主包随附两架构 zip + 各自 SHA-256 侧车，首装与修复都在本地完成。
    bool bundled = false;
    try {
      bundled = await _installBundledHelper(arch);
    } catch (e) {
      // 归档在但坏了（摘要不符 / 清单不全 / 换入失败）：绝不安装，也绝不静默。
      _log('bundled install rejected ($arch): $e');
    }
    if (!context.mounted) return false;

    final List<String> missingAfter = _missingInstalledFiles(arch);
    if (bundled && missingAfter.isEmpty) return true;
    if (bundled) {
      _log('bundled install incomplete ($arch): ${missingAfter.join(', ')}');
    }
    HibikiToast.show(
      msg: bundled
          ? t.game_helper_install_incomplete
          : t.game_helper_bundle_missing,
    );
    return false;
  }

  /// 从主包内的归档安装。返回 false 只表示当前构建没有随附该架构归档（开发/旧包），调用方
  /// 可回退网络；只要 zip 或侧车任一存在，就必须完整校验，残缺/摘要不符会抛校验失败。
  Future<bool> _installBundledHelper(String arch) async {
    final Directory bundle = _bundledDirectory();
    final File zip = File(p.join(bundle.path, galgameHelperZipName(arch)));
    final File sidecar = File('${zip.path}.sha256');
    final bool hasZip = zip.existsSync();
    final bool hasSidecar = sidecar.existsSync();
    if (!hasZip && !hasSidecar) return false;
    if (!hasZip || !hasSidecar) {
      throw GalgameHelperInstallException(
        GalgameHelperInstallFailure.verificationFailed,
        'bundled helper incomplete ($arch): zip=$hasZip sidecar=$hasSidecar',
      );
    }

    final String sha = galgameHelperRequireVerifiedSha(
      await sidecar.readAsString(),
      arch,
    );
    final String actualSha = sha256.convert(await zip.readAsBytes()).toString();
    if (!sha256Matches(sha, actualSha)) {
      throw GalgameHelperInstallException(
        GalgameHelperInstallFailure.verificationFailed,
        'bundled helper sha256 mismatch ($arch): '
        'expected $sha, actual $actualSha',
      );
    }

    await _installVerifiedZip(
      arch: arch,
      zip: zip,
      sha: sha,
      deleteArchiveOnSuccess: false,
      sourceLabel: 'bundle',
    );
    return true;
  }

  /// 测试入口：验证随包归档的校验、清单、换入与标记全链路，不经过 UI/网络。
  @visibleForTesting
  Future<bool> installBundledHelperForTesting(String arch) =>
      _installBundledHelper(arch);

  /// 已通过 SHA-256 的 zip 共用安装尾段：解压到 staging → 清单验证 → 原子换入 → 标记。
  /// 网络临时归档成功后清理；主包内归档必须保留，供另一架构或后续修复继续使用。
  Future<void> _installVerifiedZip({
    required String arch,
    required File zip,
    required String sha,
    required bool deleteArchiveOnSuccess,
    required String sourceLabel,
    File? part,
  }) async {
    // 解压到 staging 临时目录（保留 x64 unity_audio_runtime/ 子目录结构），先在
    //    staging 里验完清单再换入——坏包/缺文件在触碰安装目录之前就被拒。
    final Directory staging =
        await Directory.systemTemp.createTemp('hibiki_voice_hook_staging_');
    try {
      final Set<String> extractedFiles = await _extractZip(zip, staging);
      final List<String> missingFromPackage =
          galgameHelperMissingFiles(arch, extractedFiles);
      if (missingFromPackage.isNotEmpty) {
        // 摘要对得上但清单不全 = 发布包本身有问题（不是投毒）。仍然不换入。
        throw GalgameHelperInstallException(
          GalgameHelperInstallFailure.installFailed,
          'helper package incomplete ($arch): '
          'missing ${missingFromPackage.join(', ')}',
        );
      }

      // 4) 换入（失败自回滚，安装目录要么完整旧版要么完整新版）。
      await _serializeExtraction(() =>
          galgameHelperSwapInstall(staging: staging, target: _archDir(arch)));

      final List<String> missingAfterExtract = _missingInstalledFiles(arch);
      if (missingAfterExtract.isNotEmpty) {
        throw GalgameHelperInstallException(
          GalgameHelperInstallFailure.installFailed,
          'helper install incomplete ($arch): '
          'missing ${missingAfterExtract.join(', ')}',
        );
      }

      // 记录本次已装 zip 的 sha256 作自动更新比对基线（校验已是硬门，sha 必然非空）。
      // 写标记失败不影响安装成功（best-effort），但要留痕：写不成 = 下次不会自动更新。
      try {
        await _markerFile(arch).writeAsString(sha, flush: true);
      } catch (e) {
        _log('marker write failed ($arch): $e');
      }

      _log('installed $arch from $sourceLabel (sha256 $sha)');

      if (deleteArchiveOnSuccess) {
        // 清理网络临时 zip（best-effort；失败路径不清，保留续传现场）。
        try {
          if (await zip.exists()) await zip.delete();
          if (part != null && await part.exists()) await part.delete();
        } catch (e) {
          _log('temp cleanup failed ($arch): $e');
        }
      }
    } finally {
      try {
        if (staging.existsSync()) staging.deleteSync(recursive: true);
      } catch (e) {
        _log('staging cleanup failed ($arch): $e');
      }
    }
  }

  /// 解压 zip 到 [targetDir]（staging 临时目录——**不**直接写安装目录，换入走
  /// [galgameHelperSwapInstall]）。用 archive 包 ZipDecoder；写字节用 file.content
  /// getter（archive 3.6.1 下 ArchiveFile.decompress(out) 会写 0 字节，见
  /// sync_asset_package_service.dart 注释，故取 content 字节直接写）。只写常规文件、保留
  /// 相对目录结构，并拒绝绝对路径或逃出目标目录的条目以防 zip-slip。
  Future<Set<String>> _extractZip(File zip, Directory targetDir) async {
    await targetDir.create(recursive: true);
    final Uint8List bytes = await zip.readAsBytes();
    final Archive archive = ZipDecoder().decodeBytes(bytes);
    final String targetRoot = p.normalize(targetDir.absolute.path);
    final Set<String> extractedFiles = <String>{};
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
      extractedFiles.add(relativePath.replaceAll('\\', '/'));
    }
    return extractedFiles;
  }
}
