import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'anki_desktop_foreground.dart';

/// 下载插件包所用 [http.Client] 的进程级装配钩子（BUG-1498 同范式）。
///
/// 与 [AnkiConnectService] 那条**必须直连**的链路正相反：这里打的是公网
/// `ankiweb.net`，不走应用代理的话，同一台机器上浏览器能打开的地址在 app 里可能
/// 根本下不下来 —— Dart 的 `HttpClient` 默认连 `HTTPS_PROXY` 环境变量都不读。
///
/// 代理解析层住在 app 侧（要读偏好、跑 `reg query` / `scutil` / `gsettings`），本包
/// 反向 import 不了它，所以留这个钩子由 app 在初始化时接线。未接线（null）时回退裸
/// `http.Client()`，行为与接线前逐字等价。
http.Client Function()? ankiAddonDownloadHttpClientFactory;

/// 让 Fushi 代装 AnkiConnect —— 打通「Fushi 能连上 Anki」的第一道门槛。
///
/// 用户要用 Fushi 制卡就必须先有 AnkiConnect，而装它原本要手动走
/// 工具 → 插件 → 获取插件 → 输入编号 → 重启。没装之前 Fushi 连不上 Anki，
/// 用户正卡在设置页对着「连接失败」，这一步是纯粹的流失点。
///
/// ## 为什么是「交给 Anki 自己装」而不是自己铺 addons21/
///
/// Anki 桌面把 `.ankiaddon` 当作可打开的文件：把路径当命令行参数交给
/// `anki.exe`，运行中的实例经单实例消息走 `onAppMsg → installAddon`，冷启动
/// 走 `setupAddons(args) → installAddon(startup: true)`。两条路最终都进
/// `AddonManager.install()`，于是目录写入、`user_files` 备份、旧版本删除、
/// 冲突插件禁用、min/max 点版本兼容判定，以及那个「插件是能执行任意代码的
/// 程序」确认框，**全部由 Anki 自己负责**。我们只负责把一个合法的包放到它
/// 面前，不碰它的数据目录，也不维护 `meta.json` 的 schema。
///
/// 顺带一个反直觉的结论：**Anki 没在运行时装反而更干净**（冷启动路径在
/// `loadAddons()` 之前就装完了，不需要重启）。但那条路要求我们自己去猜
/// `anki.exe` 装在哪（注册表？默认路径？用户自定义？），而运行中的进程会把
/// 完整路径**直接告诉我们**。少一个猜测来源胜过省用户一次重启，所以这里
/// 统一要求 Anki 正在运行 —— 见 [AnkiConnectInstaller.install]。
///
/// ## 为什么必须自己补 manifest.json
///
/// AnkiWeb 的下载端点下发的是**裸包**：只有插件源码，没有 `manifest.json`
/// （实测 AnkiConnect 包内仅 `__init__.py`/`config.json`/`config.md`/`edit.py`/
/// `util.py`/`web.py`）。Anki 自己下载时并不依赖包内 manifest，而是把从下载
/// URL 的 query 里刨出来的元信息**旁路**传进 `install(manifest: ...)`。
/// 文件打开这条路（`processPackages`）没有这个旁路，`install()` 读不到包内
/// manifest 就直接返回 `InstallError("manifest")`。
///
/// 所以我们必须复刻 Anki 那份旁路元信息，把它写成包内的 `manifest.json`
/// 再交出去。字段语义与取值来源见 [AnkiWebAddonBranch]。
abstract final class AnkiConnectInstaller {
  /// AnkiConnect 在 AnkiWeb 上的插件编号，同时也是它的安装目录名。
  static const String ankiConnectAddonId = '2055492159';

  /// 插件在 Anki 插件列表里的显示名。
  static const String ankiConnectAddonName = 'AnkiConnect';

  /// 下载端点。`v` 是 AnkiWeb 的接口版本，与 Anki 版本无关。
  static const String _downloadEndpoint = 'https://ankiweb.net/shared/download';

  /// 请求下载时声称的 Anki「点版本」。
  ///
  /// 这个值**只用来让 AnkiWeb 挑分支**，不会写进 manifest（写进去的是
  /// AnkiWeb 在重定向里回给我们的 minpt/maxpt）。我们拿不到用户 Anki 的真实
  /// 版本 —— AnkiConnect 的 `version` 动作返回的是它自己的 API 版本 6，而这
  /// 会儿 AnkiConnect 恰恰还没装上。所以这里声称一个「足够新」的版本，语义
  /// 等价于「给我最新分支」。
  ///
  /// 这个参数**不能不传**：实测不传时 AnkiWeb 回的是 `minpt=0&maxpt=-44` 的
  /// 老分支，而 Anki 的 manifest 约定里 `max_point_version` 为**负数**才是硬
  /// 上限（`abs(n)` 为最高支持版本），正数只表示「在该版本上测过」并被忽略，
  /// 于是现代 Anki 会把老分支判成不兼容并禁用。传 ≥45 的任意值都落到现代分支。
  ///
  /// 若用户的 Anki 老到不支持最新分支，Anki 会依据包内 manifest 的
  /// `min_point_version` 自行判定不兼容并如实告知 —— 由 Anki 说话，好过我们
  /// 在这里猜一个版本号。
  static const int _requestedPointVersion = 250600;

  /// 下载体积上限；AnkiConnect 实际约 25KB，这里纯粹是防御异常响应。
  static const int _maxDownloadBytes = 32 * 1024 * 1024;

  /// 单测替身：注入后取代真实的下载 + 落盘 + 启动进程。
  @visibleForTesting
  static AnkiConnectInstallerHost? debugHost;

  static AnkiConnectInstallerHost get _host =>
      debugHost ?? const _RealAnkiConnectInstallerHost();

  /// 下载 AnkiConnect 并交给正在运行的 Anki 安装。
  ///
  /// 返回后**插件还没装上**：Anki 会弹自己的确认框，用户点「是」才真正安装，
  /// 之后还要按 Anki 的提示重启。所以这里的成功只代表「已经把包交到 Anki
  /// 手上」，绝不能对外说成「已安装」。
  static Future<AnkiAddonInstallResult> install() async {
    final String? ankiExecutable = _host.findRunningAnkiExecutable();
    if (ankiExecutable == null) {
      return const AnkiAddonInstallResult(
        AnkiAddonInstallStatus.ankiNotRunning,
      );
    }

    final AnkiWebAddonDownload download;
    try {
      download = await _host.download(
        buildDownloadUri(
          addonId: ankiConnectAddonId,
          pointVersion: _requestedPointVersion,
        ),
        maxBytes: _maxDownloadBytes,
      );
    } on Object catch (error) {
      return AnkiAddonInstallResult(
        AnkiAddonInstallStatus.downloadFailed,
        detail: error.toString(),
      );
    }

    final Uint8List packaged;
    try {
      packaged = repackWithManifest(
        downloadedZip: download.bytes,
        manifest: buildManifest(
          addonId: ankiConnectAddonId,
          addonName: ankiConnectAddonName,
          branch: AnkiWebAddonBranch.fromDownloadUri(download.resolvedUri),
        ),
      );
    } on Object catch (error) {
      return AnkiAddonInstallResult(
        AnkiAddonInstallStatus.invalidPackage,
        detail: error.toString(),
      );
    }

    try {
      final String path = await _host.writeTempAddon(
        '$ankiConnectAddonName.ankiaddon',
        packaged,
      );
      await _host.launch(ankiExecutable, path);
      return const AnkiAddonInstallResult(AnkiAddonInstallStatus.handedToAnki);
    } on Object catch (error) {
      return AnkiAddonInstallResult(
        AnkiAddonInstallStatus.launchFailed,
        detail: error.toString(),
      );
    }
  }

  /// 拼下载 URL。抽出来是为了让「必须带 p」这条约束可被测试钉住。
  static Uri buildDownloadUri({
    required String addonId,
    required int pointVersion,
  }) {
    return Uri.parse('$_downloadEndpoint/$addonId').replace(
      queryParameters: <String, String>{
        'v': '2.1',
        'p': pointVersion.toString(),
      },
    );
  }

  /// 按 Anki 的 manifest schema 造一份元信息。
  ///
  /// schema 只强制 `package` + `name`；其余字段带 `meta: true`，会被 Anki 原样
  /// 抄进它自己的 `meta.json`。`package` 必须是插件编号 —— 它同时是安装目录名，
  /// 装错会导致 AnkiConnect 找不到自己的配置。
  static Map<String, Object?> buildManifest({
    required String addonId,
    required String addonName,
    required AnkiWebAddonBranch branch,
  }) {
    return <String, Object?>{
      'package': addonId,
      'name': addonName,
      'mod': branch.modTime,
      'min_point_version': branch.minPointVersion,
      'max_point_version': branch.maxPointVersion,
      'branch_index': branch.branchIndex,
    };
  }

  /// 给 AnkiWeb 的裸包补上 `manifest.json` 后重新打包。
  ///
  /// 包内**已有** `manifest.json` 时原样保留：那说明上游改了下发格式，或这是
  /// 作者自行导出的完整包，作者写的元信息永远比我们复刻的更权威。
  static Uint8List repackWithManifest({
    required List<int> downloadedZip,
    required Map<String, Object?> manifest,
  }) {
    final Archive archive = ZipDecoder().decodeBytes(downloadedZip);
    if (archive.files.isEmpty) {
      throw const FormatException('AnkiWeb 返回的插件包是空的');
    }
    final bool hasManifest =
        archive.files.any((ArchiveFile file) => file.name == 'manifest.json');
    if (!hasManifest) {
      final Uint8List encoded =
          Uint8List.fromList(utf8.encode(jsonEncode(manifest)));
      archive.addFile(ArchiveFile('manifest.json', encoded.length, encoded));
    }
    final List<int>? encoded = ZipEncoder().encode(archive);
    if (encoded == null) {
      throw const FormatException('重新打包插件失败');
    }
    return Uint8List.fromList(encoded);
  }
}

/// [AnkiConnectInstaller] 的安装结果。
///
/// 注意没有「已安装」这个态：装或不装由用户在 Anki 的确认框里决定，Fushi 无从
/// 得知。能确认插件真的到位的唯一判据是之后 AnkiConnect 能应答，那属于连接探活。
enum AnkiAddonInstallStatus {
  /// 包已交给 Anki；Anki 会弹确认框，用户确认后按提示重启。
  handedToAnki,

  /// 没找到正在运行的 Anki（也包含非 Windows 平台）。
  ankiNotRunning,

  /// 从 AnkiWeb 下载失败。
  downloadFailed,

  /// 下载到的内容不是一个能重新打包的插件包。
  invalidPackage,

  /// 包已备好但没能把它交给 Anki。
  launchFailed,
}

/// 安装结果 + 失败时的原始错误描述（用于日志与错误提示，不做用户文案）。
@immutable
class AnkiAddonInstallResult {
  const AnkiAddonInstallResult(this.status, {this.detail});

  final AnkiAddonInstallStatus status;
  final String? detail;

  bool get isHandedToAnki => status == AnkiAddonInstallStatus.handedToAnki;

  @override
  String toString() =>
      'AnkiAddonInstallResult($status${detail == null ? '' : ', $detail'})';
}

/// AnkiWeb 在下载重定向里回给我们的分支元信息。
///
/// AnkiWeb 的 `/shared/download/<id>` 会 303 到
/// `/svc/shared/download-addon/<id>?t=…&minpt=…&maxpt=…&bidx=…`，四个 query
/// 参数正是 Anki 自己安装时写进 `meta.json` 的那四项（见 aqt 的
/// `extract_meta_from_download_url`）。我们必须走同一个来源，而不是硬编码 ——
/// 上游换分支时这些值会跟着变。
@immutable
class AnkiWebAddonBranch {
  const AnkiWebAddonBranch({
    required this.modTime,
    required this.minPointVersion,
    required this.maxPointVersion,
    required this.branchIndex,
  });

  /// 插件最后更新时间（unix 秒），对应 query 的 `t`。
  final int modTime;

  /// 支持的最低 Anki 点版本，对应 `minpt`。
  final int minPointVersion;

  /// 对应 `maxpt`。**负数**才表示硬上限（`abs(n)` 为最高支持版本），正数只表示
  /// 「在该版本上测过」并被 Anki 忽略。
  final int maxPointVersion;

  /// 用户下到的是哪条分支，对应 `bidx`。
  final int branchIndex;

  /// 从下载重定向后的最终 URL 解析。缺字段或非整数一律抛 [FormatException] ——
  /// 与其猜一个默认值写进 manifest 让 Anki 误判兼容性，不如当场失败。
  static AnkiWebAddonBranch fromDownloadUri(Uri uri) {
    int read(String key) {
      final String? raw = uri.queryParameters[key];
      if (raw == null) {
        throw FormatException('AnkiWeb 下载地址缺少 $key 参数', uri.toString());
      }
      final int? value = int.tryParse(raw);
      if (value == null) {
        throw FormatException('AnkiWeb 下载地址的 $key 不是整数', raw);
      }
      return value;
    }

    return AnkiWebAddonBranch(
      modTime: read('t'),
      minPointVersion: read('minpt'),
      maxPointVersion: read('maxpt'),
      branchIndex: read('bidx'),
    );
  }
}

/// 一次下载的结果：包体 + **重定向后**的最终地址。
///
/// 最终地址不是可有可无的日志信息，分支元信息只存在于它的 query 里。
@immutable
class AnkiWebAddonDownload {
  const AnkiWebAddonDownload({required this.bytes, required this.resolvedUri});

  final Uint8List bytes;
  final Uri resolvedUri;
}

/// 重定向跟随上限，防御异常的重定向环。
const int _maxAddonDownloadRedirects = 5;

/// 手动逐跳跟随重定向地下载，返回包体与**最终**地址。
///
/// 为什么不用 `package:http` 的自动跟随：它跟完之后**拿不到最终 URL**，而这个功能
/// 赖以生存的分支元信息（`t`/`minpt`/`maxpt`/`bidx`）只存在于最终 URL 的 query 里。
/// 自动跟随会把它悄悄丢掉，然后我们只能去猜兼容区间 —— 猜错的症状是「插件装上了却
/// 被 Anki 静默禁用」。所以这一跳一跳是**必须**自己走的。
///
/// 独立成顶层函数而不是埋进 host 实现，是为了能用 `MockClient` 钉住它。
@visibleForTesting
Future<AnkiWebAddonDownload> downloadFollowingRedirects(
  http.Client client,
  Uri uri, {
  required int maxBytes,
  int maxRedirects = _maxAddonDownloadRedirects,
}) async {
  Uri current = uri;
  for (int hop = 0; hop <= maxRedirects; hop++) {
    final http.Request request = http.Request('GET', current)
      ..followRedirects = false;
    final http.StreamedResponse response = await client.send(request);
    final String? location = response.headers['location'];
    if (response.isRedirect && location != null) {
      await response.stream.drain<void>();
      // 相对 Location（AnkiWeb 回的正是 `/svc/shared/download-addon/...`）要按
      // 当前地址解析成绝对地址。
      current = current.resolve(location);
      continue;
    }
    if (response.statusCode != 200) {
      throw http.ClientException(
        'AnkiWeb 返回 HTTP ${response.statusCode}',
        current,
      );
    }
    final Uint8List bytes = await _readCapped(response, maxBytes, current);
    return AnkiWebAddonDownload(bytes: bytes, resolvedUri: current);
  }
  throw http.ClientException('AnkiWeb 重定向次数过多', uri);
}

/// 边收边判上限，不先收完再看大小。
Future<Uint8List> _readCapped(
  http.StreamedResponse response,
  int maxBytes,
  Uri uri,
) async {
  final BytesBuilder builder = BytesBuilder(copy: false);
  await for (final List<int> chunk in response.stream) {
    builder.add(chunk);
    if (builder.length > maxBytes) {
      throw http.ClientException('AnkiWeb 返回的内容超出上限', uri);
    }
  }
  return builder.takeBytes();
}

/// 安装过程里的全部外部作用：找 Anki、下载、落盘、起进程。
///
/// 抽成接口是为了让编排逻辑可测 —— 真实实现只有薄薄一层。
abstract interface class AnkiConnectInstallerHost {
  /// 正在运行的 Anki 可执行文件完整路径；没有则 null（含非 Windows）。
  String? findRunningAnkiExecutable();

  /// 下载并跟随重定向，返回包体与最终地址。
  Future<AnkiWebAddonDownload> download(Uri uri, {required int maxBytes});

  /// 把包写进临时目录，返回完整路径。
  Future<String> writeTempAddon(String fileName, Uint8List bytes);

  /// 用 [executable] 打开 [addonPath]。
  Future<void> launch(String executable, String addonPath);
}

class _RealAnkiConnectInstallerHost implements AnkiConnectInstallerHost {
  const _RealAnkiConnectInstallerHost();

  @override
  String? findRunningAnkiExecutable() =>
      AnkiDesktopForeground.findRunningAnkiExecutable();

  @override
  Future<AnkiWebAddonDownload> download(
    Uri uri, {
    required int maxBytes,
  }) async {
    final http.Client client =
        ankiAddonDownloadHttpClientFactory?.call() ?? http.Client();
    try {
      return await downloadFollowingRedirects(client, uri, maxBytes: maxBytes);
    } finally {
      client.close();
    }
  }

  @override
  Future<String> writeTempAddon(String fileName, Uint8List bytes) async {
    final Directory dir =
        await Directory.systemTemp.createTemp('fushi_ankiaddon_');
    final File file = File('${dir.path}${Platform.pathSeparator}$fileName');
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  @override
  Future<void> launch(String executable, String addonPath) async {
    // 不等它退出：Anki 已在运行时这个进程会把参数经单实例通道转交给既有实例后
    // 立刻退出；而我们也不该阻塞在用户面前那个确认框上。
    await Process.start(executable, <String>[addonPath]);
  }
}
