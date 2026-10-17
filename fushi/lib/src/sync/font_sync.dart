import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:fushi/src/reader/font_catalog.dart';
import 'package:fushi_engine/sync/sync_asset_store.dart';
import 'package:path/path.dart' as p;

/// 字体同步的远端命名空间（与 `__dictionaries__` / `__local_audio__` 同级）。
///
/// 里面两类东西：
///   * 字体文件本体，**按内容寻址**：资产名 = `<sha256>.<扩展名>`。两台设备导入同一个
///     字体文件只存一份，再次上传也不重复传（去重靠名字本身，不用另记清单）；
///   * [kFontSyncManifestName]：字体库目录 + 各用途（正文 / 界面 / 词典 / 字幕 /
///     游戏）的选用顺序与开关——即「字体相关配置」。
const String kSyncFontsNamespace = '__fonts__';

/// 字体配置清单的资产名。每次上传整份覆盖（最后一次上传为准）。
const String kFontSyncManifestName = 'font-config.json';

/// 单个字体文件的上传上限。
///
/// 日文 / 中文字体常见 5–25 MB，带全部字重的 TTC 偶尔到 50 MB 上下；超过这个的
/// 多半是整套合集包，传到云盘 / 对端既慢又占配额。超限的字体**不上传**，并从清单里
/// 摘掉（别的设备下载后不会出现一个指向不存在文件的条目），记进
/// [FontSyncReport.skippedOversize] 告诉用户是哪几个。
const int kFontSyncMaxFileBytes = 64 * 1024 * 1024;

/// 清单格式版本。
const int kFontSyncManifestVersion = 1;

/// 字体同步与本机字体库之间的接口（读 / 写字体目录状态）。
///
/// 生产实现走字体库页同一条写入路径（`persistCustomFontState`）：写穿 DB 后刷新
/// 阅读器缓存、app 全局字体、galgame 浮窗——下载下来的字体**当场注册生效**，不用
/// 重启。
abstract interface class FontSyncLocal {
  /// 用户导入字体所在目录（`<appDoc>/custom_fonts`）。只有这个目录下的字体文件
  /// 才会被上传；指向别处的条目（系统字体文件等）在另一台设备上本来就不存在。
  String get fontsRoot;

  Future<FontCatalogState> readState();

  Future<void> applyState(FontCatalogState state);
}

/// 一次字体同步的结果（计数进 [SyncRunReport]，超限名单给用户看）。
class FontSyncReport {
  int filesUploaded = 0;
  int filesDownloaded = 0;
  bool configUploaded = false;
  bool configApplied = false;

  /// 因超过 [kFontSyncMaxFileBytes] 没有上传的字体名。
  final List<String> skippedOversize = <String>[];

  /// 单项失败（一个字体下载失败不拦其余），格式 `<字体名>: <错误>`。
  final List<String> errors = <String>[];
}

/// 字体文件 + 字体配置在同步后端上的上传 / 下载。
///
/// 与词典 / 本地音频库同形：显式的一次性动作，方向由用户点击时给出。
///
/// 下载的合并语义（「把另一台设备的字体配置搬过来」）：
///   * 字体库目录是**并集**——本机已有的字体一个都不删；
///   * 远端清单里出现的用途（正文、界面……）整组**换成**远端的选用顺序与开关；
///     远端没提到的用途保持本机原样；
///   * 远端字体文件按内容哈希与本机比对，本机已有同一份文件就直接复用，不重复下载。
class FontSyncService {
  FontSyncService({
    required SyncAssetStore store,
    required FontSyncLocal local,
    required Directory tempDir,
    this.maxFileBytes = kFontSyncMaxFileBytes,
  })  : _store = store,
        _local = local,
        _tempDir = tempDir;

  final SyncAssetStore _store;
  final FontSyncLocal _local;
  final Directory _tempDir;

  /// 可注入的上限（测试用小值，生产恒为 [kFontSyncMaxFileBytes]）。
  final int maxFileBytes;

  Future<FontSyncReport> upload() async {
    final FontSyncReport report = FontSyncReport();
    final FontCatalogState state = await _local.readState();
    final String ns = await _store.ensureNamespace(kSyncFontsNamespace);
    final Set<String> remoteNames = <String>{
      for (final AssetEntry e in await _store.listChildren(ns))
        if (!e.isFolder) e.name,
    };

    final List<Map<String, Object?>> fonts = <Map<String, Object?>>[];
    for (final FontCatalogEntry font in state.fonts) {
      final String? path = font.path;
      if (path == null) {
        // 系统字体：只带名字，另一台设备上按族名找。
        fonts.add(<String, Object?>{'id': font.id, 'name': font.name});
        continue;
      }
      final File file = File(path);
      if (!_isUnderFontsRoot(path) || !file.existsSync()) continue;
      if (file.lengthSync() > maxFileBytes) {
        report.skippedOversize.add(font.name);
        continue;
      }
      try {
        final String assetName = await fontAssetNameFor(file);
        if (!remoteNames.contains(assetName)) {
          await _store.putAsset(ns, assetName, file);
          remoteNames.add(assetName);
          report.filesUploaded++;
        }
        fonts.add(<String, Object?>{
          'id': font.id,
          'name': font.name,
          'file': assetName,
        });
      } catch (e) {
        report.errors.add('${font.name}: $e');
      }
    }

    final Set<String> portableIds = <String>{
      for (final Map<String, Object?> f in fonts) f['id']! as String,
    };
    await _store.putJsonAsset(ns, kFontSyncManifestName, <String, Object?>{
      'version': kFontSyncManifestVersion,
      'fonts': fonts,
      'targets': <String, Object?>{
        for (final MapEntry<String, List<FontTargetFont>> target
            in state.targets.entries)
          target.key: <Map<String, Object?>>[
            for (final FontTargetFont row in target.value)
              if (portableIds.contains(row.fontId))
                <String, Object?>{'fontId': row.fontId, 'enabled': row.enabled},
          ],
      },
    });
    report.configUploaded = true;
    return report;
  }

  Future<FontSyncReport> download() async {
    final FontSyncReport report = FontSyncReport();
    final String ns = await _store.ensureNamespace(kSyncFontsNamespace);
    final Map<String, AssetEntry> remote = <String, AssetEntry>{
      for (final AssetEntry e in await _store.listChildren(ns))
        if (!e.isFolder) e.name: e,
    };
    final AssetEntry? manifestEntry = remote[kFontSyncManifestName];
    if (manifestEntry == null) return report;
    final Object? manifest = await _store.getJsonAsset(manifestEntry.id);
    if (manifest is! Map ||
        manifest['version'] != kFontSyncManifestVersion ||
        manifest['fonts'] is! List) {
      throw const FormatException('Unrecognised font sync manifest');
    }

    final FontCatalogState local = await _local.readState();
    final Map<String, String> localPathByAsset =
        await _localFilesByAssetName(local);

    // 远端字体 id → 本机落地后的 (name, path)。下载失败的字体不进这张表，指向它们
    // 的用途行随之丢掉，不会留下一个指向不存在文件的条目。
    final Map<String, ({String name, String? path})> resolved =
        <String, ({String name, String? path})>{};
    for (final Object? row in manifest['fonts'] as List<Object?>) {
      if (row is! Map) continue;
      final Object? id = row['id'];
      final Object? name = row['name'];
      if (id is! String || name is! String || name.isEmpty) continue;
      final Object? assetName = row['file'];
      if (assetName == null) {
        resolved[id] = (name: name, path: null);
        continue;
      }
      if (assetName is! String || !isFontAssetName(assetName)) continue;
      final String? existing = localPathByAsset[assetName];
      if (existing != null) {
        resolved[id] = (name: name, path: existing);
        continue;
      }
      final AssetEntry? entry = remote[assetName];
      if (entry == null) {
        report.errors.add('$name: missing on remote');
        continue;
      }
      try {
        final String path = await _downloadFont(entry);
        localPathByAsset[assetName] = path;
        resolved[id] = (name: name, path: path);
        report.filesDownloaded++;
      } catch (e) {
        report.errors.add('$name: $e');
      }
    }

    final Object? rawTargets = manifest['targets'];
    final FontCatalogState merged = mergeRemoteFontConfig(
      local: local,
      remoteFonts: resolved,
      remoteTargets: rawTargets is Map ? rawTargets : const <String, Object?>{},
    );
    await _local.applyState(merged);
    report.configApplied = true;
    return report;
  }

  bool _isUnderFontsRoot(String path) =>
      p.isWithin(p.normalize(_local.fontsRoot), p.normalize(path));

  Future<Map<String, String>> _localFilesByAssetName(
    FontCatalogState state,
  ) async {
    final Map<String, String> byAsset = <String, String>{};
    for (final FontCatalogEntry font in state.fonts) {
      final String? path = font.path;
      if (path == null) continue;
      final File file = File(path);
      if (!file.existsSync()) continue;
      try {
        byAsset[await fontAssetNameFor(file)] = path;
      } catch (_) {
        // 读不了的本机文件当它不在：远端那份照常下载。
      }
    }
    return byAsset;
  }

  Future<String> _downloadFont(AssetEntry entry) async {
    final Directory root = Directory(_local.fontsRoot);
    await root.create(recursive: true);
    // 文件名带哈希前缀：同名不同内容的两个字体不会互相覆盖，同一份内容恒落同一路径。
    final String target = p.join(root.path, 'synced-${entry.name}');
    final File staging = File(
      p.join(
          _tempDir.path, 'font-sync-${DateTime.now().microsecondsSinceEpoch}'),
    );
    try {
      await _store.getAsset(entry.id, staging);
      final File dest = File(target);
      if (dest.existsSync()) await dest.delete();
      await staging.copy(target);
    } finally {
      if (staging.existsSync()) await staging.delete();
    }
    // 落盘后再核一次内容：传输截断的半个字体文件注册进引擎只会静默渲染失败。
    if (await fontAssetNameFor(File(target)) != entry.name) {
      await File(target).delete();
      throw const FormatException('font content hash mismatch');
    }
    return target;
  }
}

/// 字体文件的远端资产名：`<sha256 hex>.<小写扩展名>`。
Future<String> fontAssetNameFor(File file) async {
  final Digest digest = await sha256.bind(file.openRead()).first;
  final String ext = p.extension(file.path).toLowerCase();
  return '$digest$ext';
}

/// 是不是一个合法的字体资产名（64 位小写 hex + 扩展名）。清单是远端数据，拿来拼
/// 本机路径之前必须先过这道，`../` 之类的东西进不来。
bool isFontAssetName(String name) =>
    RegExp(r'^[0-9a-f]{64}\.[a-z0-9]{1,8}$').hasMatch(name);

/// 下载合并（纯函数，见 [FontSyncService] 的合并语义）。
///
/// [remoteFonts] 是已落地到本机的远端字体（远端 id → 名字 + 本机路径，系统字体
/// 路径为 null）；[remoteTargets] 是清单里的 `targets`（用途键 → 行列表）。
FontCatalogState mergeRemoteFontConfig({
  required FontCatalogState local,
  required Map<String, ({String name, String? path})> remoteFonts,
  required Map<Object?, Object?> remoteTargets,
}) {
  final List<FontCatalogEntry> fonts = <FontCatalogEntry>[...local.fonts];
  final Set<String> ids = <String>{
    for (final FontCatalogEntry f in fonts) f.id
  };
  final Map<String, String> idByIdentity = <String, String>{
    for (final FontCatalogEntry f in fonts) f.identity: f.id,
  };
  int next = 1;
  String reserveId() {
    while (ids.contains('font_$next')) {
      next++;
    }
    final String id = 'font_$next';
    ids.add(id);
    return id;
  }

  final Map<String, String> localIdByRemoteId = <String, String>{};
  for (final MapEntry<String, ({String name, String? path})> remote
      in remoteFonts.entries) {
    final String identity =
        FontCatalogEntry.identityOf(remote.value.name, remote.value.path);
    String? id = idByIdentity[identity];
    if (id == null) {
      id = reserveId();
      idByIdentity[identity] = id;
      fonts.add(FontCatalogEntry(
        id: id,
        name: remote.value.name,
        path: remote.value.path,
      ));
    }
    localIdByRemoteId[remote.key] = id;
  }

  final Map<String, List<FontTargetFont>> targets =
      <String, List<FontTargetFont>>{...local.targets};
  for (final MapEntry<Object?, Object?> target in remoteTargets.entries) {
    final Object? key = target.key;
    final Object? rows = target.value;
    if (key is! String || rows is! List) continue;
    targets[key] = <FontTargetFont>[
      for (final Object? row in rows)
        if (row is Map &&
            row['fontId'] is String &&
            localIdByRemoteId.containsKey(row['fontId']))
          FontTargetFont(
            fontId: localIdByRemoteId[row['fontId']]!,
            enabled: row['enabled'] is bool ? row['enabled']! as bool : true,
          ),
    ];
  }
  return FontCatalogState(fonts: fonts, targets: targets);
}
