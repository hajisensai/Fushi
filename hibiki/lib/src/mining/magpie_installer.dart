import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

// 与 galgame helper 安装器共用的**纯工具**（镜像候选 URL、sha256 侧车解析/比对、换入式
// 安装与 .stale 清扫）。这些函数与 helper 语义无关，只是先在那里落地；此处 show 精确复用，
// 避免第二份实现漂移。（后续若出现第三个按需下载组件，再抽到独立的下载安装模块。）
import 'package:hibiki/src/mining/galgame_helper_installer.dart'
    show
        galgameHelperCandidateUrls,
        galgameHelperSwapInstall,
        galgameHelperSweepStaleFiles,
        parseSha256Sidecar,
        sha256Matches;
import 'package:hibiki/src/utils/misc/resumable_downloader.dart';
import 'package:hibiki/src/utils/misc/update_checker.dart'
    show applyUpdateProxy;

/// 我们自建的 Magpie fork 仓库 slug。上游是 `Blinue/Magpie`（GPL-3.0）；fork 出来自己编译，
/// 为的是后续能改源码。fork 保持 public 且带完整源码与原 LICENSE —— 分发 GPL 二进制的
/// 硬性合规条件。
const String kMagpieRepo = 'hajisensai/Magpie';

/// fork 上反复 upsert 的固定发布 tag。**不用 Release API 查最新**：固定 tag 直链稳定、
/// 无 API 限流、离线可预测（与 galgame helper 的 `voice-hook-helper` 同范式）。
const String kMagpieReleaseTag = 'magpie-hibiki';

/// fork 的上游基线版本（仅用于展示与问题定位，不参与任何判定；是否需要更新一律以 sha256
/// 侧车与本地装机标记比对为准）。
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

/// 校验安装完整性用的根文件清单。**只列缩放真正必需的三个**：主程序、WinUI 运行时、资源
/// 索引。上游包里另有 `TouchHelper.exe`（只服务触摸）与 `Updater.exe`（Magpie 自己的自更新
/// 器，与我们的按需下载自更新职责冲突，fork 里随时可能剔除）—— 把它们列进必需清单只会在
/// 我们精简产物时把客户端打红，故不列。
const List<String> kMagpieRequiredRootFiles = <String>[
  'Magpie.exe',
  'Microsoft.UI.Xaml.dll',
  'resources.pri',
];

/// 校验安装完整性用的必需子目录：缺 `effects` 就没有任何缩放算法可用，装了等于没装。
const List<String> kMagpieRequiredDirs = <String>['effects'];

/// 后台静默更新取 sha256 侧车的总预算。与 galgame helper 同理（BUG-1076）：更新只发生在
/// app 启动后的后台，不抢任何交互路径，所以给「直连 + 5 镜像」逐个轮询留充分时间。
const Duration kMagpieBackgroundShaTimeout = Duration(seconds: 90);

/// 已装版本标记文件名：装成功后写入该 zip 的 sha256，下次启动与 release 侧车比对判断新版。
String magpieMarkerName() => 'installed.sha256';

/// 支持的产物架构。x64 是 Hibiki 桌面版自身的架构；ARM64 由 fork 的 CI 交叉编译产出，供
/// ARM64 Windows 原生运行（Magpie 重度依赖 D3D11 捕获与着色器，原生切片才有意义）。
const List<String> kMagpieArchs = <String>['x64', 'ARM64'];

/// **纯函数**：由 Windows 的 `PROCESSOR_ARCHITECTURE` / `PROCESSOR_ARCHITEW6432` 环境变量
/// 判定应下载哪个架构的包。ARM64 Windows 上以 x64 模拟运行的进程，其 `PROCESSOR_ARCHITECTURE`
/// 报 AMD64，真实机器架构落在 `PROCESSOR_ARCHITEW6432` —— 两者任一为 ARM64 即取 ARM64。
/// 判定不出来一律回落 x64（ARM64 上可模拟运行，属可用降级，绝不因认不出机器就装不上）。
String magpieArchForProcessorArchitecture(
  String? procArch,
  String? procArchW6432,
) {
  bool isArm64(String? value) =>
      value != null && value.trim().toUpperCase() == 'ARM64';
  if (isArm64(procArchW6432) || isArm64(procArch)) return 'ARM64';
  return 'x64';
}

/// 当前进程环境下应下载的架构。
String magpieCurrentArch({Map<String, String>? environment}) {
  final Map<String, String> env = environment ?? Platform.environment;
  return magpieArchForProcessorArchitecture(
    env['PROCESSOR_ARCHITECTURE'],
    env['PROCESSOR_ARCHITEW6432'],
  );
}

/// 某架构的分发 zip 文件名。**故意不含版本号**：固定 tag + 固定文件名才能给出稳定直链，
/// 版本信息走 release body 与包内 [kMagpieMetadataName]。
String magpieZipName(String arch) {
  if (!kMagpieArchs.contains(arch)) {
    throw ArgumentError.value(arch, 'arch', 'unsupported magpie arch');
  }
  return 'Magpie-hibiki-$arch.zip';
}

/// 某架构 zip 的稳定下载 URL（按固定 tag，不查 Release API）。
String magpieDownloadUrl(
  String arch, {
  String repo = kMagpieRepo,
  String tag = kMagpieReleaseTag,
}) =>
    'https://github.com/$repo/releases/download/$tag/${magpieZipName(arch)}';

/// 某架构 zip 的 sha256 侧车 URL（下载后校验完整性 + 自更新比对基线）。
///
/// 注意：上游 Magpie 的官方发布只提供 **MD5**（写在仓库 `version.json` 里，给它自己的
/// 更新器用），没有 sha256 侧车。这个侧车是我们 fork 的 release workflow 额外产出的。
String magpieSha256Url(
  String arch, {
  String repo = kMagpieRepo,
  String tag = kMagpieReleaseTag,
}) =>
    '${magpieDownloadUrl(arch, repo: repo, tag: tag)}.sha256';

/// 返回缺少的必需根文件名；按 Windows 规则忽略大小写。
List<String> magpieMissingFiles(Iterable<String> presentFiles) {
  final Set<String> present =
      presentFiles.map((String name) => name.toLowerCase()).toSet();
  return kMagpieRequiredRootFiles
      .where((String name) => !present.contains(name.toLowerCase()))
      .toList(growable: false);
}

/// 是否需要自动更新：**仅当**本地有装机标记、远端侧车可取、且两者不等时才更新。任一为
/// null（无标记 = 手动放置/旧装，或离线取不到远端）都返回 false —— 保守沿用现有。
bool magpieNeedsUpdate(String? localSha, String? remoteSha) {
  if (localSha == null || remoteSha == null) return false;
  return !sha256Matches(localSha, remoteSha);
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
    if (content == null || content.trim().isEmpty) return null;
    try {
      final Object? decoded = jsonDecode(content);
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
    } catch (_) {
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

  /// 本轮下载安装成功。
  installed,

  /// 用户在确认回调里拒绝了下载。
  declined,

  /// 下载/校验/解压/换入任一步失败。调用方降级即可，绝不崩。
  failed,
}

/// 传给确认回调的下载提示信息。
///
/// [sizeProbe] 是**已经发起、尚未等待**的大小探测 Future。`ensureInstalled` 在调用确认回调
/// 之前不 await 它 —— 这是 BUG-1076 的教训固化进类型：确认 UI 必须立即出现，「约 N MB」由
/// 回调自己在后台填。回调若选择直接 await 它，那是回调自己的决定。
@immutable
class MagpieDownloadPrompt {
  const MagpieDownloadPrompt({required this.arch, required this.sizeProbe});

  /// 将要下载的架构（`x64` / `ARM64`）。
  final String arch;

  /// 下载体积探测（字节）；探测失败或超时为 null。
  final Future<int?> sizeProbe;
}

/// Magpie（窗口超分）的按需下载安装器。
///
/// 与 galgame helper 安装器同范式：固定 tag 稳定直链 + 镜像回退 + sha256 侧车校验 + Range
/// 续传 + staging 校验 + 换入式安装（旧文件 rename 让位）+ 装机标记驱动的后台静默自更新。
/// 落点是 `Hibiki.exe` 同级的 `magpie\`（安装器 `PrivilegesRequired=lowest`，此目录用户
/// 可写、免提权）。
///
/// 本类**不含任何 UI**：是否下载由调用方通过 [ensureInstalled] 的 `confirm` 回调决定。这样
/// 安装器不持有 i18n / BuildContext，消费侧（阶段二的会话联动与设置项）可以自由决定用对话框、
/// 开关还是静默策略。
class MagpieInstaller {
  MagpieInstaller();

  bool _canceled = false;
  HttpClient? _client;

  /// 换入是唯一与「读取安装目录」竞态的写窗口（亚秒级本地文件操作），全部串到这条门上；
  /// 下载/解压只碰临时目录，无需互斥。
  static Future<void> _installGate = Future<void>.value();

  static Future<T> _serializeInstall<T>(Future<T> Function() job) {
    final Future<T> run = _installGate.then((_) => job());
    _installGate = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  /// 用户主动取消下载：置位并强制关闭在途 client 中断请求。
  void cancel() {
    _canceled = true;
    _client?.close(force: true);
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
  /// - 已完整安装 → [MagpieInstallResult.alreadyInstalled]（**零网络探测**，自更新一律在
  ///   app 启动后台，见 [updateInstalledMagpieInBackground]，BUG-1076 的教训）；
  /// - 残缺安装 → 直接用当前发布包修复，不再打扰用户（用户此前已同意过下载）；
  /// - 未安装 → 立即调 [confirm]（不等大小探测），同意后下载+校验+换入+复检。
  Future<MagpieInstallResult> ensureInstalled({
    required Future<bool> Function(MagpieDownloadPrompt prompt) confirm,
    ResumableDownloadProgress? onProgress,
    String? arch,
  }) async {
    if (!Platform.isWindows) return MagpieInstallResult.unsupportedPlatform;
    final String targetArch = arch ?? magpieCurrentArch();
    // 等在途换入落定再检查文件，绝不读到半换入状态；平时门是已完成 future，零开销。
    await _installGate;

    final bool hadInstall = installDirectory().existsSync();
    if (missingInstalledEntries().isEmpty) {
      return MagpieInstallResult.alreadyInstalled;
    }

    if (!hadInstall) {
      // 确认回调**立即**调用，绝不为 best-effort 的大小探测阻塞（旧 helper 实现先 await
      // HEAD 探测再弹框，弱网下点了没反应，是 BUG-1076 的表征之一）。
      final Future<int?> sizeProbe = _probeSize(targetArch);
      // 回调若不 await 它，也不能让它变成未处理异常。
      unawaited(sizeProbe.catchError((Object _) => null));
      final bool ok = await confirm(
        MagpieDownloadPrompt(arch: targetArch, sizeProbe: sizeProbe),
      );
      if (!ok) return MagpieInstallResult.declined;
    }

    try {
      await _runInstall(arch: targetArch, onProgress: onProgress);
    } catch (_) {
      return MagpieInstallResult.failed;
    }
    return missingInstalledEntries().isEmpty
        ? MagpieInstallResult.installed
        : MagpieInstallResult.failed;
  }

  /// app 启动后的后台静默自更新（无 UI、无 toast）。只做「已装 → 最新」：未安装/无标记/
  /// 残缺一律不动（首装与修复属于交互路径）。任一步失败静默放弃，下次启动再试。
  static Future<void> updateInstalledMagpieInBackground() async {
    if (!Platform.isWindows) return;
    try {
      await MagpieInstaller()._updateSilently();
    } catch (_) {
      // 后台更新是锦上添花：绝不影响 app 启动。
    }
  }

  Future<void> _updateSilently() async {
    galgameHelperSweepStaleFiles(installDirectory());
    final File marker = _markerFile();
    if (!marker.existsSync()) return; // 手动放置/旧装：保守沿用现有
    if (missingInstalledEntries().isNotEmpty) return; // 残缺留给交互修复路径
    final String localSha = (await marker.readAsString()).trim();
    final String arch = magpieCurrentArch();

    final HttpClient client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 30);
    client.idleTimeout = const Duration(seconds: 60);
    await applyUpdateProxy(client);
    _client = client;
    try {
      final String? remoteSha = await _fetchSha256(client, arch).timeout(
        kMagpieBackgroundShaTimeout,
        onTimeout: () => null,
      );
      if (!magpieNeedsUpdate(localSha, remoteSha)) return;
      await _installCore(client: client, arch: arch, expectedSha: remoteSha);
    } finally {
      client.close(force: true);
      _client = null;
    }
  }

  /// 交互路径的一次完整安装（自带 client 生命周期）。
  Future<void> _runInstall({
    required String arch,
    ResumableDownloadProgress? onProgress,
  }) async {
    final HttpClient client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 15);
    client.idleTimeout = const Duration(seconds: 60);
    await applyUpdateProxy(client); // 中国大陆直连 GitHub 常失败
    _client = client;
    try {
      await _installCore(client: client, arch: arch, onProgress: onProgress);
    } finally {
      client.close(force: true);
      _client = null;
    }
  }

  /// UI 无关的安装核心（交互路径与后台静默路径共用）：取 sha256 侧车 → 下载 zip（镜像回退
  /// + Range 续传 + sha256 校验）→ 解压到 staging 并校验清单 → 换入 → 复检 → 写装机标记
  /// → best-effort 写便携标记。任一步失败抛异常，由调用方决定提示或静默。
  Future<void> _installCore({
    required HttpClient client,
    required String arch,
    String? expectedSha,
    ResumableDownloadProgress? onProgress,
  }) async {
    expectedSha ??= await _fetchSha256(client, arch);

    final File dest = File(
        p.join(Directory.systemTemp.path, 'hibiki_${magpieZipName(arch)}'));
    final File part = File('${dest.path}.part');
    final File zip = await _downloadZip(
      client: client,
      arch: arch,
      dest: dest,
      part: part,
      expectedSha256: expectedSha,
      onProgress: onProgress ?? (int _, int? __) {},
    );

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

      if (expectedSha != null) {
        try {
          await _markerFile().writeAsString(expectedSha, flush: true);
        } catch (_) {}
      }

      await ensurePortableConfig(metadata: metadata);

      try {
        if (await zip.exists()) await zip.delete();
        if (await part.exists()) await part.delete();
      } catch (_) {}
    } finally {
      try {
        if (staging.existsSync()) staging.deleteSync(recursive: true);
      } catch (_) {}
    }
  }

  /// 从 staging 读安装包元数据；缺失/损坏返回 null。
  @visibleForTesting
  Future<MagpiePackageMetadata?> readStagedMetadata(Directory staging) async {
    final File file = File(p.join(staging.path, kMagpieMetadataName));
    if (!file.existsSync()) return null;
    try {
      return MagpiePackageMetadata.parse(await file.readAsString());
    } catch (_) {
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
    } catch (_) {
      return false;
    }
  }

  /// 逐镜像候选下载 zip；全部失败则抛最后一个异常。
  Future<File> _downloadZip({
    required HttpClient client,
    required String arch,
    required File dest,
    required File part,
    required String? expectedSha256,
    required ResumableDownloadProgress onProgress,
  }) async {
    final List<String> candidates =
        galgameHelperCandidateUrls(magpieDownloadUrl(arch));
    Object? lastError;
    for (final String url in candidates) {
      if (_canceled) throw StateError('canceled');
      try {
        return await ResumableDownloader(
          url: url,
          destination: dest,
          partFile: part,
          open: _open(client),
          expectedSha256: expectedSha256,
          onProgress: onProgress,
          firstByteTimeout: const Duration(seconds: 20),
        ).download();
      } catch (e) {
        lastError = e;
        if (_canceled) rethrow;
        // 换镜像前清掉可能不一致的 part（不同镜像 body 不可续）。
        try {
          if (await part.exists()) await part.delete();
        } catch (_) {}
      }
    }
    throw Exception(lastError?.toString() ?? 'no download candidate');
  }

  /// 取 sha256 侧车文本并解析出摘要；任何失败返回 null（降级为不校验 sha256）。
  Future<String?> _fetchSha256(HttpClient client, String arch) async {
    final List<String> candidates =
        galgameHelperCandidateUrls(magpieSha256Url(arch));
    for (final String url in candidates) {
      if (_canceled) return null;
      try {
        final HttpClientRequest req = await client.getUrl(Uri.parse(url));
        final HttpClientResponse resp = await req.close();
        if (resp.statusCode != 200) {
          await resp.drain<void>();
          continue;
        }
        final String body =
            await resp.transform(const SystemEncoding().decoder).join();
        final String? sha = parseSha256Sidecar(body);
        if (sha != null) return sha;
      } catch (_) {
        // 试下一个镜像
      }
    }
    return null;
  }

  /// 探测 zip 大小（Content-Length）：逐镜像发 HEAD。全失败返回 null。
  Future<int?> _probeSize(String arch) async {
    final HttpClient client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 10);
    await applyUpdateProxy(client);
    try {
      for (final String url
          in galgameHelperCandidateUrls(magpieDownloadUrl(arch))) {
        if (_canceled) return null;
        try {
          final HttpClientRequest req =
              await client.openUrl('HEAD', Uri.parse(url));
          req.followRedirects = true;
          final HttpClientResponse resp = await req.close();
          await resp.drain<void>();
          if (resp.statusCode == 200 && resp.contentLength > 0) {
            return resp.contentLength;
          }
        } catch (_) {
          // 试下一个镜像
        }
      }
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// ResumableDownloader 的 open 回调：带代理的 GET（自动跟随 GitHub→S3 重定向）。
  ResumableDownloadOpen _open(HttpClient client) {
    return (Uri uri, Map<String, String> headers) async {
      final HttpClientRequest req = await client.getUrl(uri);
      req.followRedirects = true;
      headers.forEach(req.headers.set);
      final HttpClientResponse resp = await req.close();
      final Map<String, String> respHeaders = <String, String>{};
      resp.headers.forEach((String name, List<String> values) {
        respHeaders[name] = values.join(',');
      });
      return ResumableDownloadResponse(
        statusCode: resp.statusCode,
        headers: respHeaders,
        stream: resp,
      );
    };
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
      if (relativePath.isEmpty || p.isAbsolute(relativePath)) continue;
      final String outputPath = p.normalize(p.join(targetRoot, relativePath));
      if (!p.isWithin(targetRoot, outputPath)) continue;
      final Object? content = entry.content;
      if (content is! List<int>) continue;
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
