import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

// 与 galgame helper 安装器共用的**纯工具**（镜像候选 URL、sha256 侧车解析/比对、换入式
// 安装与 .stale 清扫）。这些函数与 helper 语义无关，只是先在那里落地；此处 show 精确复用，
// 避免第二份实现漂移。（后续若出现第三个按需下载组件，再抽到独立的下载安装模块。）
import 'package:hibiki/src/mining/galgame_helper_installer.dart'
    show
        galgameHelperSwapInstall,
        galgameHelperSweepStaleFiles,
        parseSha256Sidecar,
        sha256Matches;
import 'package:hibiki/src/utils/misc/resumable_downloader.dart';
import 'package:hibiki/src/utils/misc/update_checker.dart'
    show applyUpdateProxy;

/// 统一日志出口。安装器全程无 UI（后台静默更新 + 交互确认回调），失败若只剩一个 enum，
/// 用户报「装不上」时根本无从判断卡在网络、侧车、校验还是解压 —— 关键路径必须留痕。
/// 与同目录 `galgame_cover_download.dart` 同范式（带模块前缀的 debugPrint）。
void _log(String message) => debugPrint('[magpie] $message');

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

/// Windows 主包内随附的 **精简版** Magpie 归档目录名（落在 `Hibiki.exe` 同级）。
///
/// 与安装落点 [kMagpieInstallDirName] 刻意不同名：一个是「发行介质」，一个是「装好的
/// 东西」，同名会让「装到一半」和「归档本身」在同一个目录里纠缠不清。范式同 galgame
/// helper 的 `galgame_helper/`（归档） vs `voice_hook/`（落点）。
const String kMagpieBundledDirectoryName = 'magpie_bundle';

/// 随包精简归档的文件名。**带 `slim` 是契约的一部分**：它与 fork release 上的完整包
/// （[magpieZipName]）内容不同（裁掉了 145 个用不到的 effect 文件，10.79 MB → 4.72 MB），
/// 摘要自然也不同，混淆两者会让自更新把完整包当「新版」覆盖掉精简包。
String magpieBundledZipName(String arch) => 'Magpie-hibiki-slim-$arch.zip';

/// 安装来源标记文件名（与 [magpieMarkerName] 的 sha 标记并列）。
///
/// 内容是 [kMagpieBundleSource] 或不存在（= 网络装的）。存在的唯一理由见
/// [kMagpieBundleSource]。
String magpieSourceMarkerName() => 'installed.source';

/// 「这份 Magpie 是从主包随附归档装的」。
///
/// 🔴 **它是自更新的熔断器，不是诊断信息**：随包装的是精简版，其 sha256 必然不等于
/// fork release 上完整包的 sha256。若不做区分，`magpieNeedsUpdate` 每次都会判定「有新版」
/// → 后台静默下载 10.79 MB 完整包覆盖掉 4.72 MB 的精简包 —— 内置的意义当场归零，而且
/// 用户每次开 app 都白下一次。见 [_updateSilently] 的早退。
const String kMagpieBundleSource = 'bundle';

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

/// 后台静默更新取 sha256 侧车的总预算。更新只发生在 app 启动后的后台，不抢任何交互路径，
/// 所以给直连留充分时间（BUG-1076 的教训：预算太紧等于把弱网用户永久钉在旧版）。
const Duration kMagpieBackgroundShaTimeout = Duration(seconds: 90);

/// 交互安装路径取 sha256 侧车的总预算。**必须有上限**：没有它，直连被 GFW 静默丢包时这里
/// 会一直悬着，用户点了「下载」既等不到成功也等不到失败。取与后台同量级但更短——交互路径
/// 背后有人在等，而侧车只走直连（无镜像轮询，见 [magpieSidecarUrls]），45s 足够覆盖一次
/// 带重定向的慢连接。
const Duration kMagpieInteractiveShaTimeout = Duration(seconds: 45);

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

/// sha256 侧车**唯一**可信来源的主机白名单（GitHub 自己的域）。
///
/// 为什么侧车不能和 zip 走同一批第三方 GFW 镜像：镜像是他人控制的完整中间人，一旦它同时
/// 供应 zip 和 `.sha256`，就能给出「篡改过的 zip + 与之匹配的摘要」，校验退化成走过场——
/// 等于没有校验。所以摘要必须来自我们信任的源（直连 GitHub），而 zip 本体可以随便走镜像：
/// 它的内容已被直连拿到的摘要独立锁死，镜像改一个字节都会在校验时炸掉。
///
/// `objects.` / `release-assets.` 是 GitHub release 资产 302 的落点，属重定向链的合法一环。
///
/// 这里曾是 galgame helper 安装器同一份清单的别名。BUG-1196 把 helper 的网络下载整条
/// 删掉之后（helper 随主包发布，不再联网），Magpie 成了**唯一**的按需下载组件，白名单
/// 就落回它自己身上 —— 不是复制出第二份，是原来那份的家没了。
const List<String> kMagpieTrustedSidecarHosts = <String>[
  'github.com',
  'api.github.com',
  'objects.githubusercontent.com',
  'release-assets.githubusercontent.com',
  'raw.githubusercontent.com',
];

/// gh 加速代理前缀（GFW 兜底）。**只给 zip 本体用，绝不给侧车用**——理由见
/// [kMagpieTrustedSidecarHosts]。
const List<String> kMagpieProxyPrefixes = <String>[
  'https://ghfast.top/',
  'https://gh-proxy.com/',
  'https://ghproxy.net/',
  'https://ghproxy.cc/',
  'https://gh.llkk.cc/',
];

/// **纯函数**：为一个 GitHub 直链 [url] 生成按优先级排序的候选下载 URL：① 直连本身（有
/// 代理/VPN 时最快最权威）→ ② 每个镜像前缀套在直连前（GFW 兜底）。逐个尝试任一成功即成功。
List<String> magpieDownloadCandidateUrls(String url) => <String>[
      url,
      for (final String prefix in kMagpieProxyPrefixes) '$prefix$url',
    ];

/// **纯函数**：该 URL 是否是可信侧车来源（https + 主机在 [kMagpieTrustedSidecarHosts] 内）。
/// 任何镜像前缀套出来的 URL（`https://ghfast.top/https://github.com/...`）主机都是镜像自己，
/// 一律判否。
bool magpieIsTrustedSidecarUrl(String url) {
  final Uri? uri = Uri.tryParse(url);
  if (uri == null || uri.scheme.toLowerCase() != 'https') return false;
  return kMagpieTrustedSidecarHosts.contains(uri.host.toLowerCase());
}

/// **纯函数**：取 sha256 侧车的候选 URL —— **只有直连，绝不含镜像**（与
/// [magpieDownloadCandidateUrls] 的 zip 候选刻意不同，理由见 [kMagpieTrustedSidecarHosts]）。
/// 直连不可用时列表为空，安装路径据此硬失败（宁可不装，也不装未校验产物）。
List<String> magpieSidecarUrls(
  String arch, {
  String repo = kMagpieRepo,
  String tag = kMagpieReleaseTag,
}) {
  final String url = magpieSha256Url(arch, repo: repo, tag: tag);
  return magpieIsTrustedSidecarUrl(url) ? <String>[url] : const <String>[];
}

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

  /// 本轮下载安装成功。
  installed,

  /// 用户在确认回调里拒绝了下载。
  declined,

  /// 下载失败：直连与所有镜像都拿不到 zip（离线、全被墙、404）。可重试。
  downloadFailed,

  /// **完整性校验失败**：拿不到直连 GitHub 的 sha256 侧车，或下到的 zip 与侧车摘要不符。
  /// 与 [downloadFailed] 分开是因为语义完全不同——这条意味着「东西下下来了但不可信」或
  /// 「无法证明可信」，此时一律**不安装**。
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

/// 校验前置门：拿不到可信 sha256 就**放弃安装**（抛 [MagpieInstallException]）。
///
/// 这是本安装器的安全底线。产物走的是可被完整中间人替换的第三方镜像，摘要是唯一能把内容
/// 钉死的东西；旧实现在这里降级成「取不到就不校验」，等于任何一个镜像都能把任意 exe 装进
/// 用户 `Hibiki.exe` 同级目录 —— 供应链后门。宁可装不上，也不装未校验产物。
///
/// 抽成顶层函数是为了在任何平台都能被测（真实安装路径只在 Windows 跑）。
String magpieRequireVerifiedSha(String? sha, String arch) {
  final String? parsed = sha == null ? null : parseSha256Sidecar(sha);
  if (parsed == null) {
    throw MagpieInstallException(
      MagpieInstallResult.verificationFailed,
      '$arch: no trusted sha256 sidecar (direct GitHub only); '
      'refusing to install an unverified package',
    );
  }
  return parsed;
}

/// **纯函数**：镜像轮询全灭时的失败分类。中途只要出现过 sha256 不符（内容与直连摘要对不
/// 上），就报 [MagpieInstallResult.verificationFailed]——那是投毒/损坏，不是网络不通。
MagpieInstallResult magpieClassifyDownloadFailure({
  required bool sawIntegrityFailure,
}) =>
    sawIntegrityFailure
        ? MagpieInstallResult.verificationFailed
        : MagpieInstallResult.downloadFailed;

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
  MagpieInstaller({Directory? bundledDirectory})
      : _bundledDirectoryOverride = bundledDirectory;

  /// 仅测试注入：主包随附归档目录（生产恒为 `Hibiki.exe` 同级的 `magpie_bundle/`）。
  final Directory? _bundledDirectoryOverride;

  bool _canceled = false;

  /// 所有**在途**的 HttpClient。
  ///
  /// 原来是单个 `_client?`，但大小探测的 client 与安装的 client 在时间上是重叠的（探测在
  /// confirm 之前发起、confirm 期间还活着，安装随后又要装一个），单字段必然互相覆盖：要么
  /// 探测 client 漏掉 cancel（探测那个根本没登记过），要么探测结束时把安装 client 置空。
  /// 换成集合就没有这个特殊情况了 —— 谁在途谁在里面，[cancel] 一次全关。
  final Set<HttpClient> _liveClients = <HttpClient>{};

  /// 换入是唯一与「读取安装目录」竞态的写窗口（亚秒级本地文件操作），全部串到这条门上；
  /// 下载/解压只碰临时目录，无需互斥。
  static Future<void> _installGate = Future<void>.value();

  static Future<T> _serializeInstall<T>(Future<T> Function() job) {
    final Future<T> run = _installGate.then((_) => job());
    _installGate = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  /// 用户主动取消下载：置位并强制关闭**所有**在途 client 中断请求。
  void cancel() {
    _canceled = true;
    for (final HttpClient client in _liveClients.toList(growable: false)) {
      try {
        client.close(force: true);
      } catch (e) {
        _log('cancel: close client failed: $e');
      }
    }
  }

  /// 登记在途 client（[cancel] 能关到它）。
  HttpClient _track(HttpClient client) {
    _liveClients.add(client);
    return client;
  }

  /// 注销并关闭一个在途 client。
  void _release(HttpClient client) {
    _liveClients.remove(client);
    try {
      client.close(force: true);
    } catch (e) {
      _log('release: close client failed: $e');
    }
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

  /// 安装来源标记（见 [kMagpieBundleSource]）。
  static File _sourceMarkerFile() =>
      File(p.join(installDirectory().path, magpieSourceMarkerName()));

  /// 当前安装是否来自主包随附的精简归档。
  ///
  /// 读不出来时按「不是随包」处理并**留痕**：这条判据一旦误判成 false，自更新就会拿
  /// 完整包覆盖精简包（见 [kMagpieBundleSource]）。用户报「装了内置版怎么还在下载」
  /// 时，这行日志是唯一能区分「标记没写成」和「判据读失败」的东西。
  static bool installedFromBundle() {
    try {
      final File marker = _sourceMarkerFile();
      if (!marker.existsSync()) return false;
      return marker.readAsStringSync().trim() == kMagpieBundleSource;
    } catch (e) {
      _log('source marker read failed (treated as non-bundle): $e');
      return false;
    }
  }

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

    // 主包随附的精简归档：零网络、零确认框（BUG-1217）。x64 走这条路时用户根本
    // 看不到「要下载 10MB」的框——东西已经在硬盘上了。ARM64 没有随包归档（为它多
    // 背一份 4.7MB 不值），继续走下面的网络路径。
    try {
      if (await _installBundledMagpie(targetArch)) {
        if (missingInstalledEntries().isEmpty) {
          return MagpieInstallResult.installed;
        }
        _log('bundled install incomplete ($targetArch): '
            'missing ${missingInstalledEntries().join(', ')}');
      }
    } catch (e) {
      // 归档在但坏了（摘要不符/清单不全/换入失败）：不装，落到网络路径。
      _log('bundled install rejected ($targetArch): $e');
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
    } on MagpieInstallException catch (e) {
      // 分类失败（校验缺失/不符 vs 下载不通）原样透传给调用方，别糊成一个 failed。
      _log('install aborted ($targetArch): $e');
      return e.result;
    } catch (e) {
      _log('install failed ($targetArch): $e');
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

  /// app 启动后的后台静默自更新（无 UI、无 toast）。只做「已装 → 最新」：未安装/无标记/
  /// 残缺一律不动（首装与修复属于交互路径）。任一步失败静默放弃，下次启动再试。
  static Future<void> updateInstalledMagpieInBackground() async {
    if (!Platform.isWindows) return;
    try {
      await MagpieInstaller()._updateSilently();
    } catch (e) {
      // 后台更新是锦上添花：绝不影响 app 启动。但必须留痕，否则「一直不更新」无从查。
      _log('background update skipped: $e');
    }
  }

  Future<void> _updateSilently() async {
    galgameHelperSweepStaleFiles(installDirectory());
    // 🔴 随包精简版**绝不自更新**（BUG-1217）。它的 sha256 必然不等于 fork release 上
    // 完整包的 sha256，`magpieNeedsUpdate` 会永远判「有新版」→ 每次开 app 都静默下载
    // 10.79 MB 完整包覆盖掉 4.72 MB 的精简包，内置的意义当场归零。随包版本跟着 app 走：
    // 要新 Magpie 就更新 Hibiki，与 galgame helper 同一套交付纪律。
    if (installedFromBundle()) return;
    final File marker = _markerFile();
    if (!marker.existsSync()) return; // 手动放置/旧装：保守沿用现有
    if (missingInstalledEntries().isNotEmpty) return; // 残缺留给交互修复路径
    final String localSha = (await marker.readAsString()).trim();
    final String arch = magpieCurrentArch();

    final HttpClient client = _track(HttpClient());
    client.connectionTimeout = const Duration(seconds: 30);
    client.idleTimeout = const Duration(seconds: 60);
    await applyUpdateProxy(client);
    try {
      final String? remoteSha = await fetchSha256Sidecar(
        client,
        urls: magpieSidecarUrls(arch),
        timeout: kMagpieBackgroundShaTimeout,
      );
      if (!magpieNeedsUpdate(localSha, remoteSha)) return;
      _log('background update: $arch $localSha -> $remoteSha');
      await _installCore(client: client, arch: arch, expectedSha: remoteSha);
    } finally {
      _release(client);
    }
  }

  /// 交互路径的一次完整安装（自带 client 生命周期）。
  Future<void> _runInstall({
    required String arch,
    ResumableDownloadProgress? onProgress,
  }) async {
    final HttpClient client = _track(HttpClient());
    client.connectionTimeout = const Duration(seconds: 15);
    client.idleTimeout = const Duration(seconds: 60);
    await applyUpdateProxy(client); // 中国大陆直连 GitHub 常失败
    try {
      await _installCore(client: client, arch: arch, onProgress: onProgress);
    } finally {
      _release(client);
    }
  }

  /// UI 无关的安装核心（交互路径与后台静默路径共用）：**先**从直连 GitHub 取 sha256 侧车
  /// （取不到即硬失败）→ 下载 zip（镜像回退 + Range 续传 + sha256 校验）→ 解压到 staging 并
  /// 校验清单 → 换入 → 复检 → 写装机标记 → best-effort 写便携标记。任一步失败抛异常，由
  /// 调用方决定提示或静默。
  /// 从主包随附的精简归档安装（零网络）。
  ///
  /// 返回 false 只表示**当前构建没有随附该架构的归档**（ARM64、开发构建、旧包），调用方
  /// 可回退网络；只要 zip 或侧车任一存在，就必须完整校验 —— 残缺或摘要不符一律抛，绝不
  /// 装一个证明不了来源的包。校验强度与网络路径完全一致（同一个 [magpieRequireVerifiedSha]）：
  /// 随包不等于可信，主包本身可能被改。
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
      // 随包归档必须留着：另一次修复、另一个架构都还要用它。
      deleteArchiveOnSuccess: false,
      source: kMagpieBundleSource,
    );
    return true;
  }

  /// 测试入口：跑通随包校验 → 清单 → 换入 → 双标记全链路，不经网络也不经 UI。
  @visibleForTesting
  Future<bool> installBundledMagpieForTesting(String arch) =>
      _installBundledMagpie(arch);

  Future<void> _installCore({
    required HttpClient client,
    required String arch,
    String? expectedSha,
    ResumableDownloadProgress? onProgress,
  }) async {
    // 摘要必须**先于**任何下载拿到：没有它就没有判断产物真伪的依据，那就干脆别下。
    final String sha = magpieRequireVerifiedSha(
      expectedSha ??
          await fetchSha256Sidecar(
            client,
            urls: magpieSidecarUrls(arch),
            timeout: kMagpieInteractiveShaTimeout,
          ),
      arch,
    );

    final File dest = File(
        p.join(Directory.systemTemp.path, 'hibiki_${magpieZipName(arch)}'));
    final File part = File('${dest.path}.part');
    final File zip = await _downloadZip(
      client: client,
      candidates: magpieDownloadCandidateUrls(magpieDownloadUrl(arch)),
      dest: dest,
      part: part,
      expectedSha256: sha,
      onProgress: onProgress ?? (int _, int? __) {},
    );

    await _installVerifiedZip(
      arch: arch,
      zip: zip,
      sha: sha,
      part: part,
      deleteArchiveOnSuccess: true,
      source: null,
    );
  }

  /// 已通过 SHA-256 的 zip 共用的安装尾段：解压 staging → 清单验证 → 原子换入 →
  /// 写标记 → 便携配置。网络与随包两条来源在这里合流，**校验强度必须一致**。
  ///
  /// [source] 非空时额外写来源标记（见 [kMagpieBundleSource]）；为 null 时**主动删掉**
  /// 旧的来源标记 —— 网络装的东西覆盖了随包版本，标记若留着，自更新会永远以为自己
  /// 还是随包版而不再更新。
  Future<void> _installVerifiedZip({
    required String arch,
    required File zip,
    required String sha,
    required bool deleteArchiveOnSuccess,
    required String? source,
    File? part,
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
        final File sourceMarker = _sourceMarkerFile();
        if (source != null) {
          await sourceMarker.writeAsString(source, flush: true);
        } else if (sourceMarker.existsSync()) {
          await sourceMarker.delete();
        }
      } catch (e) {
        // 标记写不成只影响下次自更新判据，不影响这次安装可用性。
        _log('marker write failed ($arch): $e');
      }

      await ensurePortableConfig(metadata: metadata);
      _log('installed $arch from ${source ?? 'network'} (sha256 $sha)');

      if (deleteArchiveOnSuccess) {
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

  /// 逐镜像候选下载 zip。zip **本体**可以随便走镜像：内容已被 [expectedSha256]（来自直连
  /// GitHub 的侧车）钉死，镜像改一个字节都会在校验时炸掉。全部候选失败则抛分类过的
  /// [MagpieInstallException] —— 中途出现过 sha256 不符就是 verificationFailed。
  /// [candidates] 可注入仅为测试用（生产调用点传 [magpieDownloadCandidateUrls] 的结果）。
  @visibleForTesting
  Future<File> downloadZip({
    required HttpClient client,
    required List<String> candidates,
    required File dest,
    required File part,
    required String expectedSha256,
    required ResumableDownloadProgress onProgress,
  }) =>
      _downloadZip(
        client: client,
        candidates: candidates,
        dest: dest,
        part: part,
        expectedSha256: expectedSha256,
        onProgress: onProgress,
      );

  Future<File> _downloadZip({
    required HttpClient client,
    required List<String> candidates,
    required File dest,
    required File part,
    required String expectedSha256,
    required ResumableDownloadProgress onProgress,
  }) async {
    Object? lastError;
    bool sawIntegrityFailure = false;
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
        if (e is ResumableDownloadIntegrityException) {
          // 这条镜像给的内容与直连摘要对不上：损坏或投毒。换下一个，但记住见过。
          sawIntegrityFailure = true;
          _log('download integrity FAILED from $url: $e');
        } else {
          _log('download failed from $url: $e');
        }
        if (_canceled) rethrow;
        // 换镜像前清掉可能不一致的 part（不同镜像 body 不可续）。
        try {
          if (await part.exists()) await part.delete();
        } catch (e) {
          _log('part cleanup failed: $e');
        }
      }
    }
    final MagpieInstallResult result = magpieClassifyDownloadFailure(
      sawIntegrityFailure: sawIntegrityFailure,
    );
    final String reason = lastError?.toString() ?? 'no download candidate';
    _log('all ${candidates.length} download candidates exhausted '
        '(${result.name}): $reason');
    throw MagpieInstallException(result, reason);
  }

  /// 取 sha256 侧车文本并解析出摘要。
  ///
  /// **只走 [magpieSidecarUrls] 给的直连 URL**（生产调用点如此），并逐跳校验重定向没有离开
  /// 可信主机 —— 侧车一旦允许从第三方镜像取，镜像就能同时供应「篡改的 zip + 匹配的摘要」，
  /// 校验退化成走过场。取不到一律返回 null，由 [magpieRequireVerifiedSha] 把 null 变成硬
  /// 失败（绝不降级成「不校验」）。[timeout] 是**总**预算：没有它，直连被静默丢包时这里会
  /// 一直悬着。[isTrusted] 仅测试注入（生产用默认值，有源码守卫）。
  @visibleForTesting
  Future<String?> fetchSha256Sidecar(
    HttpClient client, {
    required List<String> urls,
    Duration? timeout,
    bool Function(String url) isTrusted = magpieIsTrustedSidecarUrl,
  }) {
    final Future<String?> job = _fetchSha256(client, urls, isTrusted);
    if (timeout == null) return job;
    return job.timeout(timeout, onTimeout: () {
      _log('sidecar fetch timed out after $timeout');
      return null;
    });
  }

  Future<String?> _fetchSha256(
    HttpClient client,
    List<String> urls,
    bool Function(String url) isTrusted,
  ) async {
    if (urls.isEmpty) {
      _log('no trusted sidecar source available (direct GitHub only)');
      return null;
    }
    for (final String url in urls) {
      if (_canceled) return null;
      if (!isTrusted(url)) {
        _log('sidecar source rejected (untrusted host): $url');
        continue;
      }
      try {
        final Uri base = Uri.parse(url);
        final HttpClientRequest req = await client.getUrl(base);
        final HttpClientResponse resp = await req.close();
        // 重定向链也必须留在可信主机内，否则一次 302 就能把摘要来源换成任何人。
        final Uri? untrustedHop = resp.redirects
            .map((RedirectInfo hop) => base.resolveUri(hop.location))
            .cast<Uri?>()
            .firstWhere((Uri? hop) => !isTrusted(hop.toString()),
                orElse: () => null);
        if (untrustedHop != null) {
          await resp.drain<void>();
          _log('sidecar redirect left trusted hosts: ${untrustedHop.host}');
          continue;
        }
        if (resp.statusCode != 200) {
          await resp.drain<void>();
          _log('sidecar HTTP ${resp.statusCode}: $url');
          continue;
        }
        final String body =
            await resp.transform(const SystemEncoding().decoder).join();
        final String? sha = parseSha256Sidecar(body);
        if (sha != null) return sha;
        _log('sidecar body has no valid sha256 digest: $url');
      } catch (e) {
        _log('sidecar fetch failed from $url: $e');
      }
    }
    return null;
  }

  /// 探测 zip 大小（Content-Length）：逐镜像发 HEAD。全失败返回 null。
  Future<int?> _probeSize(String arch) async {
    // 登记进在途集合，否则 cancel() 关不到它：用户取消后这条 HEAD 还会一直挂着。
    final HttpClient client = _track(HttpClient());
    client.connectionTimeout = const Duration(seconds: 10);
    await applyUpdateProxy(client);
    try {
      for (final String url
          in magpieDownloadCandidateUrls(magpieDownloadUrl(arch))) {
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
        } catch (e) {
          _log('size probe failed from $url: $e'); // 试下一个镜像
        }
      }
      return null;
    } finally {
      _release(client);
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
