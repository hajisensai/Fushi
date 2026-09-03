import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

/// AnkiConnect 在 AnkiWeb 的插件号，也是 `addons21/` 下的安装目录名。
/// 保留数字号目录，装完后 Anki 自带的「检查更新」仍能从 AnkiWeb 升级它。
const String kAnkiConnectAddonId = '2055492159';

/// 内置 AnkiConnect 插件包资产（FooSoft/anki-connect@4064fa14 的 plugin/
/// 三件套打成的 zip；GPLv3，许可全文在 assets/licenses/anki-connect.txt 并已
/// 注册进应用许可页）。
const String kAnkiConnectAddonAsset = 'assets/anki/ankiconnect.ankiaddon';

enum AnkiConnectAddonInstallStatus {
  /// 插件文件已解压到位（新装或覆盖修复）；需（重）启动 Anki 才会加载。
  installed,

  /// 没找到 Anki 数据目录（`Anki2`）：Anki 未安装，或装了但一次都没运行过
  /// （数据目录在首次运行时才创建）。
  ankiDataDirNotFound,
}

class AnkiConnectAddonInstallResult {
  const AnkiConnectAddonInstallResult(this.status, {this.addonDir});

  final AnkiConnectAddonInstallStatus status;

  /// 安装落地目录（仅 [AnkiConnectAddonInstallStatus.installed] 时非空）。
  final Directory? addonDir;
}

/// 定位 Anki 桌面版数据根（`Anki2`，标准安装均在此；自定义 `-b` 基目录的用户
/// 不在覆盖范围，走手动安装路径）。找不到返回 null。
Directory? locateAnkiDataDir({Map<String, String>? environment}) {
  final Map<String, String> env = environment ?? Platform.environment;
  final List<String> candidates = <String>[
    if (Platform.isWindows && env['APPDATA'] != null)
      p.join(env['APPDATA']!, 'Anki2'),
    if (Platform.isMacOS && env['HOME'] != null)
      p.join(env['HOME']!, 'Library', 'Application Support', 'Anki2'),
    if (Platform.isLinux) ...<String>[
      if (env['XDG_DATA_HOME'] != null) p.join(env['XDG_DATA_HOME']!, 'Anki2'),
      if (env['HOME'] != null) p.join(env['HOME']!, '.local', 'share', 'Anki2'),
    ],
  ];
  for (final String path in candidates) {
    final Directory dir = Directory(path);
    if (dir.existsSync()) return dir;
  }
  return null;
}

/// 把内置 AnkiConnect 插件包解压进 Anki 的 `addons21/2055492159/`。
///
/// - 覆盖式安装：目录已存在也重写为内置的钉定版本（修复损坏/被禁用的安装；
///   AnkiWeb 上更新的版本之后可由 Anki 的更新检查再升回去）。
/// - `meta.json` 里的用户配置保留：只把 `disabled` 拉回 false，其余字段
///   （用户改过的 `config` 等）原样不动；文件缺失时写一份最小骨架。
/// - Anki 是否正在运行不影响解压；插件在下一次 Anki 启动时加载。
///
/// [ankiDataDir] 仅测试注入；生产走 [locateAnkiDataDir]。
Future<AnkiConnectAddonInstallResult> installAnkiConnectAddon({
  required Uint8List addonZipBytes,
  Directory? ankiDataDir,
}) async {
  final Directory? base = ankiDataDir ?? locateAnkiDataDir();
  if (base == null || !base.existsSync()) {
    return const AnkiConnectAddonInstallResult(
      AnkiConnectAddonInstallStatus.ankiDataDirNotFound,
    );
  }
  final Directory addonDir =
      Directory(p.join(base.path, 'addons21', kAnkiConnectAddonId));
  addonDir.createSync(recursive: true);

  final Archive archive = ZipDecoder().decodeBytes(addonZipBytes);
  for (final ArchiveFile file in archive) {
    if (!file.isFile) continue;
    // 防御 zip-slip：拒绝绝对路径与越界成分（内置包本是扁平三文件，这里只是
    // 不给未来换包留坑）。
    final String name = p.normalize(file.name.replaceAll('\\', '/'));
    if (p.isAbsolute(name) || p.split(name).contains('..')) continue;
    final File out = File(p.join(addonDir.path, name));
    out.parent.createSync(recursive: true);
    out.writeAsBytesSync(file.content as List<int>, flush: true);
  }

  final File metaFile = File(p.join(addonDir.path, 'meta.json'));
  Map<String, dynamic> meta = <String, dynamic>{};
  if (metaFile.existsSync()) {
    try {
      final Object? decoded = json.decode(metaFile.readAsStringSync());
      if (decoded is Map<String, dynamic>) meta = decoded;
    } on FormatException {
      // 坏 meta 当缺失处理，重写骨架。
    }
  }
  meta['name'] ??= 'AnkiConnect';
  meta['mod'] ??= 0;
  meta['disabled'] = false;
  metaFile.writeAsStringSync(json.encode(meta), flush: true);

  return AnkiConnectAddonInstallResult(
    AnkiConnectAddonInstallStatus.installed,
    addonDir: addonDir,
  );
}
