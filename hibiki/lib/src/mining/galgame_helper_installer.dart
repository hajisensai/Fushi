import 'dart:async';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'package:hibiki/src/utils/misc/resumable_downloader.dart';
// applyUpdateProxy（走系统代理）经 utils.dart 复用自更新子系统。helper 仓库 slug 用本地
// [kGalgameHelperRepo]（独立仓库，非主 app 仓库）。镜像回退候选 URL 用本地纯函数
// galgameHelperCandidateUrls（updateCheckUrls 是 @visibleForTesting 不可生产用；raw release
// 资产的镜像前缀照 video_shader_downloader 先例本地列）。
import 'package:hibiki/utils.dart';

/// galgame 引擎-hook 注入器 helper 的固定发布 tag（CI workflow `voice-hook-helper.yml`
/// 反复 upsert 同一 prerelease，asset 名 voice_hook_<arch>.zip + 同名 .sha256 侧车）。
const String kGalgameHelperReleaseTag = 'voice-hook-helper';

/// helper 所在的**独立仓库** slug（不是主 app 仓库 [kGitHubRepo]）。injector + hook DLL 含
/// 进程注入代码会被杀软报毒，故物理隔离到独立仓库单独构建/分发（见该仓库 README）；且独立仓库
/// 默认分支上的 `voice-hook-helper.yml` 可正常 workflow_dispatch 刷新 release（主仓库那份因不在
/// 默认分支无法 dispatch，是迁出独立仓库的根因）。
const String kGalgameHelperRepo = 'hajisensai/hibiki-hook';

/// gh 加速代理前缀（GFW 兜底；raw release 资产可走镜像，与 update_checker 的
/// updateCheckProxyPrefixes / video_shader_downloader 的 _kGhProxyPrefixes 同范式、同名单）。
const List<String> kGalgameHelperProxyPrefixes = <String>[
  'https://ghfast.top/',
  'https://gh-proxy.com/',
  'https://ghproxy.net/',
  'https://ghproxy.cc/',
  'https://gh.llkk.cc/',
];

/// **纯函数**：为一个 GitHub 直链 [url] 生成按优先级排序的候选下载 URL：① 直连本身（有
/// 代理/VPN 时最快最权威）→ ② 每个镜像前缀套在直连前（GFW 兜底）。逐个尝试任一成功即成功。
List<String> galgameHelperCandidateUrls(String url) => <String>[
      url,
      for (final String prefix in kGalgameHelperProxyPrefixes) '$prefix$url',
    ];

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
      presentFiles.map((String name) => name.toLowerCase()).toSet();
  return galgameHelperRequiredFiles(arch)
      .where((String name) => !present.contains(name.toLowerCase()))
      .toList(growable: false);
}

/// 某架构的分发 zip 文件名（与 CI workflow 打包命名一一对应）。
String galgameHelperZipName(String arch) => 'voice_hook_$arch.zip';

/// 某架构 zip 的稳定下载 URL（按固定 tag 而非某次 run 号；下载阶段再由 [updateCheckUrls]
/// 套镜像前缀做回退）。
String galgameHelperDownloadUrl(
  String arch, {
  String repo = kGalgameHelperRepo,
  String tag = kGalgameHelperReleaseTag,
}) =>
    'https://github.com/$repo/releases/download/$tag/${galgameHelperZipName(arch)}';

/// 某架构 zip 的 sha256 侧车 URL（下载后校验完整性用）。
String galgameHelperSha256Url(
  String arch, {
  String repo = kGalgameHelperRepo,
  String tag = kGalgameHelperReleaseTag,
}) =>
    '${galgameHelperDownloadUrl(arch, repo: repo, tag: tag)}.sha256';

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

/// 已装 helper 的版本标记文件名：装成功后在 `voice_hook/<arch>/` 写入该 zip 的 sha256，供下次
/// app 启动比对 release 侧车判断是否有新版（后台自动更新）。放在 arch 目录内，随 helper 一起
/// 被覆盖/清理。
String galgameHelperMarkerName() => 'installed.sha256';

/// 后台静默更新取 sha256 侧车的总预算（BUG-1076）。更新时机在 app 启动后台、不抢任何
/// 交互路径，所以给「直连 + 5 镜像」逐个轮询留充分时间；对照旧实现把更新绑在游戏启动
/// 关键路径上被迫设的 6s 自残上限（弱网必然超时 → 永远静默放弃、helper 停在旧版）。
const Duration kGalgameHelperBackgroundShaTimeout = Duration(seconds: 90);

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

/// 是否需要自动更新 helper：**仅当**本地有装机标记 [localSha]、远端侧车可取 [remoteSha]、且两者
/// 不等时才更新。任一为 null（无标记=手动放置/旧装、或离线取不到远端）都返回 false —— 保守沿用
/// 现有，绝不因无法判定就重下或阻塞启动（Never break）。
bool galgameHelperNeedsUpdate(String? localSha, String? remoteSha) {
  if (localSha == null || remoteSha == null) {
    return false;
  }
  return !sha256Matches(localSha, remoteSha);
}

/// 把字节数格式化成人类可读大小（用于确认对话框「约 N MB」）。
String formatDownloadSize(int bytes) {
  if (bytes <= 0) return '';
  const double mb = 1024 * 1024;
  if (bytes >= mb) {
    return '${(bytes / mb).toStringAsFixed(1)} MB';
  }
  return '${(bytes / 1024).toStringAsFixed(0)} KB';
}

/// 缺失注入器时的「按需下载」安装器（方案 B）：弹确认对话框（标大小）→ 用户确认 →
/// 下载对应架构 zip（走系统代理 + 镜像回退 + sha256 校验）→ staging 解压校验 → 换入
/// exe 同级 voice_hook/<arch>/ → 复检。仅 Windows；用户取消或任一步失败均返回 false
/// （调用方中止启动、已给提示，Never break）。已装 helper 的自动更新不在这里——见
/// [updateInstalledHelpersInBackground]（app 启动后台静默更新，BUG-1076）。
class GalgameHelperInstaller {
  GalgameHelperInstaller();

  /// 取消令牌：用户在进度对话框点「取消」时置位，并强制关闭下载 client 中断在途请求。
  bool _canceled = false;
  HttpClient? _client;

  /// 后台静默更新与游戏启动路径唯一的共享写窗口是「换入」（亚秒级本地文件操作）。所有换入
  /// 都串到这条门上、启动路径检查文件前也先过门，二者绝不与半换入状态竞态；下载/解压只碰
  /// 临时目录，无需互斥。
  static Future<void> _extractionGate = Future<void>.value();

  /// 把 [job]（换入操作）串行挂到 [_extractionGate] 上执行。
  static Future<T> _serializeExtraction<T>(Future<T> Function() job) {
    final Future<T> run = _extractionGate.then((_) => job());
    _extractionGate = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  /// app 启动后的**后台静默自更新**（BUG-1076 根因修复；`main.dart` 启动块挂载）。
  /// 对每个已装（有装机标记且清单完整）的架构：清扫上轮 `.stale` 残骸 → 取 release
  /// sha256 侧车（宽松预算 [kGalgameHelperBackgroundShaTimeout]，后台不抢交互路径所以
  /// 不需要旧实现那种 6s 上限）→ 与本地标记比对 → 有新版则静默下载+校验+换入。全程无
  /// UI；任一步失败静默放弃、下次 app 启动再试（Never break：绝不影响 app 与游戏启动）。
  static Future<void> updateInstalledHelpersInBackground() async {
    if (!Platform.isWindows) return;
    final GalgameHelperInstaller installer = GalgameHelperInstaller();
    for (final String arch in const <String>['x86', 'x64']) {
      try {
        await installer._updateArchSilently(arch);
      } catch (_) {
        // 后台更新是锦上添花：静默放弃本架构，继续下一个。
      }
    }
  }

  /// 单架构的静默更新（无 UI、无 toast）。未安装/无标记/残缺一律不动——首装与修复属于
  /// 用户交互路径（[ensureInjector] 的确认框/进度框），后台只做「已装 → 最新」。
  Future<void> _updateArchSilently(String arch) async {
    galgameHelperSweepStaleFiles(_archDir(arch));
    final File marker = _markerFile(arch);
    if (!marker.existsSync()) return; // 手动放置/旧装：保守沿用现有
    if (_missingInstalledFiles(arch).isNotEmpty) return; // 残缺留给交互修复路径
    final String localSha = (await marker.readAsString()).trim();

    final HttpClient client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 30);
    client.idleTimeout = const Duration(seconds: 60);
    await applyUpdateProxy(client);
    try {
      final String? remoteSha = await _fetchSha256(client, arch).timeout(
        kGalgameHelperBackgroundShaTimeout,
        onTimeout: () => null,
      );
      if (!galgameHelperNeedsUpdate(localSha, remoteSha)) {
        return; // 已最新 / 取不到远端：沿用现有
      }
      await _installCore(
        client: client,
        arch: arch,
        expectedSize: null,
        expectedSha: remoteSha,
      );
    } finally {
      client.close(force: true);
    }
  }

  /// exe 同级的 `voice_hook/<arch>` 目录（安装器写入落点，与 defaultInjectorResolver /
  /// GalHookSessionController 注入器解析的读取落点一致）。安装包 Inno Setup
  /// 默认装到 {localappdata}\Hibiki（PrivilegesRequired=lowest），此目录用户可写、无需提权。
  Directory _archDir(String arch) {
    final String exeDir = File(Platform.resolvedExecutable).parent.path;
    return Directory(p.join(exeDir, 'voice_hook', arch));
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
        .listSync(followLinks: false)
        .whereType<File>()
        .map((File file) => p.basename(file.path));
    return galgameHelperMissingFiles(arch, present);
  }

  bool _hasExistingInstall(String arch) {
    final Directory dir = _archDir(arch);
    return dir.existsSync() && dir.listSync(followLinks: false).isNotEmpty;
  }

  /// 确保对应架构注入器就位：
  /// - 完整安装 → true（零网络零 UI；自动更新在 app 启动后台，见
  ///   [updateInstalledHelpersInBackground]）；
  /// - 已有残缺安装 → 自动下载当前包修复，失败则阻止错误启动；
  /// - 从未安装 → 弹确认对话框（标大小）→ 确认后下载+校验+换入→复检；
  /// - 用户取消 / 下载失败 / 校验失败 / 换入后仍缺 → false（调用方中止启动）。
  Future<bool> ensureInjector({
    required bool is32Bit,
    required BuildContext context,
  }) async {
    if (!Platform.isWindows) return false;
    final String arch = galgameHelperArch(is32Bit: is32Bit);
    // 等在途换入（若有）落定再检查文件，绝不读到半换入状态；平时门是已完成 future，零开销。
    await _extractionGate;
    if (!context.mounted) return false;
    final List<String> missingBefore = _missingInstalledFiles(arch);
    if (missingBefore.isEmpty) {
      // 安装完整：直接放行。自动更新已挪到 app 启动后台
      // （[updateInstalledHelpersInBackground]，BUG-1076）——游戏启动路径不再做任何
      // 网络探测，也就不存在旧实现在这里抢 6s 的自残上限。
      return true;
    }

    // 旧安装可能只有 injector，缺 Luna 或 Locale Emulator。直接用当前发布包修复；
    // x86 缺转区组件时不得回退到普通区域启动非 Unicode 游戏。
    if (_hasExistingInstall(arch)) {
      final bool repaired = await _downloadAndExtract(
        context: context,
        arch: arch,
        expectedSize: null,
      );
      if (!repaired || _missingInstalledFiles(arch).isNotEmpty) {
        if (context.mounted) {
          HibikiToast.show(msg: t.galgame_helper_install_incomplete);
        }
        return false;
      }
      return true;
    }

    // 确认对话框**立即**弹出，绝不为 best-effort 的大小探测阻塞 UI（旧实现先 await
    // _probeSize——一个 10s 连接超时、逐镜像回退的 HTTP HEAD——再弹框，弱网/GFW 下点击后
    // 要等好几秒对话框才出现，是「点了没反应」的根因）。大小仅作展示，先填「大小未知」，探测
    // 在后台并发进行，返回后就地更新对话框里的「约 N MB」。
    final ValueNotifier<String> sizeText =
        ValueNotifier<String>(t.galgame_helper_size_unknown);
    // sizeText.dispose() 后不得再写其 value（debug 下会 assert）。用本地守卫记录对话框是否已关闭；
    // Dart 单线程事件循环下 then 回调与 dispose 后的代码不会真并发，简单 bool 守卫即安全。
    bool dialogClosed = false;
    int? probedSize;
    final Future<int?> sizeProbe = _probeSize(arch);
    unawaited(sizeProbe.then((int? bytes) {
      probedSize = bytes;
      if (!dialogClosed && bytes != null && bytes > 0) {
        sizeText.value = formatDownloadSize(bytes);
      }
    }).catchError((Object _) {
      // 探测失败：保持「大小未知」，不打扰用户。
    }));

    final bool confirmed = await _confirmDownload(context, sizeText: sizeText);
    dialogClosed = true;
    sizeText.dispose();
    if (!confirmed || !context.mounted) return false;

    // 复用后台探测结果作 expectedSize（用户看完对话框再确认，多半已就绪；未就绪则为 null，
    // 下载阶段仍靠 Content-Length / sha256 兜底校验）。
    final int? sizeBytes = probedSize;

    // 下载 + 校验 + 解压（带进度对话框）。
    final bool ok = await _downloadAndExtract(
      context: context,
      arch: arch,
      expectedSize: sizeBytes,
    );
    if (!ok) return false;

    if (_missingInstalledFiles(arch).isNotEmpty) {
      HibikiToast.show(msg: t.galgame_helper_install_incomplete);
      return false;
    }
    return true;
  }

  /// 弹确认对话框（复用 app 统一对话框外框），返回用户是否确认下载。[sizeText] 是可监听的
  /// 大小文案：对话框先以「大小未知」立即出现，后台探测返回后就地刷新为「约 N MB」。
  Future<bool> _confirmDownload(
    BuildContext context, {
    required ValueListenable<String> sizeText,
  }) async {
    final bool? confirmed = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext ctx) {
        final HibikiDesignTokens tokens = HibikiDesignTokens.of(ctx);
        return HibikiDialogFrame(
          maxWidth: 440,
          maxHeightFactor: 0.86,
          insetPadding: EdgeInsets.symmetric(
            horizontal: tokens.spacing.card,
            vertical: tokens.spacing.card,
          ),
          scrollable: false,
          child: HibikiModalSheetFrame(
            title: t.galgame_helper_needed_title,
            scrollable: true,
            bodyPadding: EdgeInsets.fromLTRB(
              tokens.spacing.card,
              0,
              tokens.spacing.card,
              tokens.spacing.gap,
            ),
            footerPadding: EdgeInsets.fromLTRB(
              tokens.spacing.card,
              tokens.spacing.gap,
              tokens.spacing.card,
              tokens.spacing.card,
            ),
            body: ValueListenableBuilder<String>(
              valueListenable: sizeText,
              builder: (BuildContext _, String size, Widget? __) => Text(
                t.galgame_helper_needed_body(size: size),
                style: tokens.type.listSubtitle,
              ),
            ),
            footer: Wrap(
              alignment: WrapAlignment.end,
              spacing: tokens.spacing.gap,
              runSpacing: tokens.spacing.gap,
              children: <Widget>[
                adaptiveDialogAction(
                  context: ctx,
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(t.dialog_cancel),
                ),
                adaptiveDialogAction(
                  context: ctx,
                  isDefaultAction: true,
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(t.galgame_helper_download),
                ),
              ],
            ),
          ),
        );
      },
    );
    return confirmed == true;
  }

  /// 下载 zip → sha256 校验 → 解压到 archDir。全程弹进度对话框（可取消）。任一步失败/取消
  /// 返回 false（并给清晰错误 toast，取消则静默）。
  Future<bool> _downloadAndExtract({
    required BuildContext context,
    required String arch,
    required int? expectedSize,
  }) async {
    final ValueNotifier<double?> progress = ValueNotifier<double?>(null);
    BuildContext? dialogCtx;
    // 非阻塞地弹进度对话框（barrier 不可点掉，取消只能按按钮）。
    unawaited(
      showAppDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (BuildContext ctx) {
          dialogCtx = ctx;
          return _HelperDownloadDialog(
            progress: progress,
            onCancel: () {
              _canceled = true;
              _client?.close(force: true); // 中断在途请求 → download() 抛错
              if (ctx.mounted) Navigator.pop(ctx);
            },
          );
        },
      ),
    );

    void closeDialog() {
      final BuildContext? d = dialogCtx;
      if (d != null && d.mounted) Navigator.pop(d);
    }

    final HttpClient client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 15);
    client.idleTimeout = const Duration(seconds: 60);
    await applyUpdateProxy(client); // 走用户/系统代理，中国大陆直连 GitHub 常失败
    _client = client;

    try {
      await _installCore(
        client: client,
        arch: arch,
        expectedSize: expectedSize,
        onProgress: (int received, int? total) {
          final int? denom = total ?? expectedSize;
          progress.value = (denom != null && denom > 0)
              ? (received / denom).clamp(0.0, 1.0)
              : null;
        },
      );
      closeDialog();
      return true;
    } catch (e) {
      closeDialog();
      if (_canceled) {
        // 用户主动取消：静默（不当作错误）。
        return false;
      }
      HibikiToast.show(msg: t.galgame_helper_download_failed(error: '$e'));
      return false;
    } finally {
      client.close(force: true);
      _client = null;
      progress.dispose();
    }
  }

  /// UI 无关的安装核心（交互路径与后台静默路径共用）：取 sha256 侧车（[expectedSha] 已取到
  /// 则复用，不重复请求）→ 下载 zip（镜像回退 + Range 续传 + size/sha256 校验）→ 解压到
  /// staging 临时目录并校验清单 → [galgameHelperSwapInstall] 换入（经 [_extractionGate]
  /// 与启动路径串行）→ 复检安装 → 写装机标记。任一步失败抛异常，由调用方决定提示或静默；
  /// 失败时保留 zip/part 供下次续传，staging 一律清理。
  Future<void> _installCore({
    required HttpClient client,
    required String arch,
    required int? expectedSize,
    String? expectedSha,
    ResumableDownloadProgress? onProgress,
  }) async {
    // 1) 取 sha256 侧车（校验完整性用；取不到则跳过 sha256，仍靠 size 兜底）。
    expectedSha ??= await _fetchSha256(client, arch);

    // 2) 下载 zip（ResumableDownloader 自带 Range 续传 + size/sha256 校验 + 原子 promote）。
    final Directory tmp = Directory.systemTemp;
    final File dest =
        File(p.join(tmp.path, 'hibiki_${galgameHelperZipName(arch)}'));
    final File part = File('${dest.path}.part');
    final File zip = await _downloadZip(
      client: client,
      arch: arch,
      dest: dest,
      part: part,
      expectedSize: expectedSize,
      expectedSha256: expectedSha,
      onProgress: onProgress ?? (int _, int? __) {},
    );

    // 3) 解压到 staging 临时目录（保留 x64 unity_audio_runtime/ 子目录结构），先在
    //    staging 里验完清单再换入——坏包/缺文件在触碰安装目录之前就被拒。
    final Directory staging =
        await Directory.systemTemp.createTemp('hibiki_voice_hook_staging_');
    try {
      final Set<String> extractedRootFiles = await _extractZip(zip, staging);
      final List<String> missingFromPackage =
          galgameHelperMissingFiles(arch, extractedRootFiles);
      if (missingFromPackage.isNotEmpty) {
        throw StateError(
          'helper package incomplete ($arch): '
          'missing ${missingFromPackage.join(', ')}',
        );
      }

      // 4) 换入（失败自回滚，安装目录要么完整旧版要么完整新版）。
      await _serializeExtraction(() =>
          galgameHelperSwapInstall(staging: staging, target: _archDir(arch)));

      final List<String> missingAfterExtract = _missingInstalledFiles(arch);
      if (missingAfterExtract.isNotEmpty) {
        throw StateError(
          'helper install incomplete ($arch): '
          'missing ${missingAfterExtract.join(', ')}',
        );
      }

      // 记录本次已装 zip 的 sha256 作自动更新比对基线；无 sha 侧车时不写标记（下次不自动更新，
      // 保守）。写标记失败不影响安装成功（best-effort）。
      if (expectedSha != null) {
        try {
          await _markerFile(arch).writeAsString(expectedSha, flush: true);
        } catch (_) {}
      }

      // 清理临时 zip（best-effort；失败路径不清，保留续传现场）。
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

  /// 逐镜像候选下载 zip；全部失败则抛最后一个异常。
  Future<File> _downloadZip({
    required HttpClient client,
    required String arch,
    required File dest,
    required File part,
    required int? expectedSize,
    required String? expectedSha256,
    required ResumableDownloadProgress onProgress,
  }) async {
    final List<String> candidates =
        galgameHelperCandidateUrls(galgameHelperDownloadUrl(arch));
    Object? lastError;
    for (final String url in candidates) {
      if (_canceled) throw StateError('canceled');
      try {
        final ResumableDownloader downloader = ResumableDownloader(
          url: url,
          destination: dest,
          partFile: part,
          open: _open(client),
          expectedSize: expectedSize,
          expectedSha256: expectedSha256,
          onProgress: onProgress,
          firstByteTimeout: const Duration(seconds: 20),
        );
        return await downloader.download();
      } catch (e) {
        lastError = e;
        if (_canceled) rethrow;
        // 换下一个镜像前清掉可能不一致的 part（不同镜像 body 不可续）。
        try {
          if (await part.exists()) await part.delete();
        } catch (_) {}
      }
    }
    throw Exception(lastError?.toString() ?? 'no download candidate');
  }

  /// 取 sha256 侧车文本并解析出摘要；任何失败返回 null（降级为只做 size 校验）。
  Future<String?> _fetchSha256(HttpClient client, String arch) async {
    final List<String> candidates =
        galgameHelperCandidateUrls(galgameHelperSha256Url(arch));
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

  /// 探测 zip 大小（Content-Length）：逐镜像发 HEAD（跟随重定向），取第一个成功。全失败返回 null。
  Future<int?> _probeSize(String arch) async {
    final HttpClient client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 10);
    await applyUpdateProxy(client);
    try {
      final List<String> candidates =
          galgameHelperCandidateUrls(galgameHelperDownloadUrl(arch));
      for (final String url in candidates) {
        try {
          final HttpClientRequest req =
              await client.openUrl('HEAD', Uri.parse(url));
          req.followRedirects = true;
          final HttpClientResponse resp = await req.close();
          await resp.drain<void>();
          final int len = resp.contentLength;
          if (resp.statusCode == 200 && len > 0) return len;
        } catch (_) {
          // 试下一个镜像
        }
      }
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// ResumableDownloader 的 open 回调：用带代理的 HttpClient 发 GET（自动跟随 GitHub→S3 重定向），
  /// 把响应适配成 ResumableDownloadResponse（下游据 status/headers 做续传/校验）。
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
    final Set<String> extractedRootFiles = <String>{};
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
        extractedRootFiles.add(p.basename(relativePath));
      }
    }
    return extractedRootFiles;
  }
}

/// 下载进度对话框：不确定态（progress==null）显示循环条，确定态显示百分比进度条；底部
/// 「取消」按钮触发 onCancel（中断下载 + 关框）。
class _HelperDownloadDialog extends StatelessWidget {
  const _HelperDownloadDialog({
    required this.progress,
    required this.onCancel,
  });

  final ValueListenable<double?> progress;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return HibikiDialogFrame(
      maxWidth: 420,
      maxHeightFactor: 0.86,
      insetPadding: EdgeInsets.symmetric(
        horizontal: tokens.spacing.card,
        vertical: tokens.spacing.card,
      ),
      scrollable: false,
      child: HibikiModalSheetFrame(
        title: t.galgame_helper_downloading,
        scrollable: false,
        bodyPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          0,
          tokens.spacing.card,
          tokens.spacing.gap,
        ),
        footerPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          tokens.spacing.gap,
          tokens.spacing.card,
          tokens.spacing.card,
        ),
        body: ValueListenableBuilder<double?>(
          valueListenable: progress,
          builder: (BuildContext ctx, double? value, _) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                LinearProgressIndicator(value: value),
                if (value != null) ...<Widget>[
                  SizedBox(height: tokens.spacing.gap),
                  Text(
                    '${(value * 100).toStringAsFixed(0)}%',
                    style: tokens.type.listSubtitle,
                  ),
                ],
              ],
            );
          },
        ),
        footer: Wrap(
          alignment: WrapAlignment.end,
          children: <Widget>[
            adaptiveDialogAction(
              context: context,
              onPressed: onCancel,
              child: Text(t.dialog_cancel),
            ),
          ],
        ),
      ),
    );
  }
}
