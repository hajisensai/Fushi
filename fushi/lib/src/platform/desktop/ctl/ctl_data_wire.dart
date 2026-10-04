/// data 域控制通道的纯函数部分：把 app 里的模型转成应答 JSON、解析 CLI 传来的
/// 参数。不碰 [AppModel]、不做 IO，便于单测（路由本体见 `ctl_data_routes.dart`）。
///
/// 这里的每个 `*ToWire` 都是**白名单**式的：只挑出明确可以出现在终端里的字段。
/// 令牌、密码、证书私钥、OAuth refresh token 一律不在白名单里——新增字段时也要
/// 按这个口径挑，别图省事整个对象 `toJson()` 出去。
library;

import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_engine/sync/sync_backend_type.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/video/media_server/media_server_browser.dart';
import 'package:fushi/src/media/video/media_server/media_server_config.dart';
import 'package:fushi/src/sync/backup_service.dart';
import 'package:fushi/src/sync/sync_activity.dart';
import 'package:fushi/src/sync/sync_repository.dart';

/// 错误信息里可能夹带的凭据（媒体服务器 URL 上的 `api_key` / `X-Plex-Token`、
/// `Authorization` 头回显等）统一抹掉后才回给终端。
final RegExp _secretQueryPattern = RegExp(
  r'((?:api_key|apikey|access_token|token|x-plex-token|x-emby-token|password|passwd|secret)=)[^&\s"]+',
  caseSensitive: false,
);
final RegExp _bearerPattern = RegExp(
  r'((?:bearer|basic)\s+)[A-Za-z0-9._~+/=-]+',
  caseSensitive: false,
);

String redactCtlSecrets(String message) => message
    .replaceAllMapped(_secretQueryPattern, (Match m) => '${m.group(1)}***')
    .replaceAllMapped(_bearerPattern, (Match m) => '${m.group(1)}***');

// ── 备份 ─────────────────────────────────────────────────────────────

/// `--category` 名单 → 分类集合。空名单返回 null（交给调用方用默认集）；认不出的
/// 名字抛 400，并把合法取值列出来。
Set<BackupCategory>? parseBackupCategories(List<String> names) {
  if (names.isEmpty) return null;
  final Set<BackupCategory> out = <BackupCategory>{};
  for (final String raw in names) {
    for (final String name in raw.split(',')) {
      final String trimmed = name.trim();
      if (trimmed.isEmpty) continue;
      final BackupCategory? category = BackupCategory.values
          .where((BackupCategory c) => c.name == trimmed)
          .firstOrNull;
      if (category == null) {
        throw CtlFailure.badRequest(
          '未知的备份分类：$trimmed（可选：'
          '${BackupCategory.values.map((BackupCategory c) => c.name).join(', ')}）',
        );
      }
      out.add(category);
    }
  }
  return out.isEmpty ? null : out;
}

/// 备份输出路径：给的是已存在的目录就在里面用默认文件名，否则当文件路径用。
/// 只接受绝对路径（CLI 侧已经按 shell 的工作目录转好了）。
String resolveBackupOutputPath(
  String output, {
  required bool isDirectory,
  required String defaultFilename,
}) {
  if (!p.isAbsolute(output)) {
    throw CtlFailure.badRequest('输出路径必须是绝对路径：$output');
  }
  return isDirectory ? p.join(output, defaultFilename) : output;
}

Map<String, Object?> backupMetaToWire(BackupMeta meta) => <String, Object?>{
  'appVersion': meta.appVersion,
  'schemaVersion': meta.schemaVersion,
  'createdAt': meta.createdAt.millisecondsSinceEpoch,
  'bookCount': meta.bookCount,
  'statsCount': meta.statsCount,
  if (meta.videoBookCount != null) 'videoCount': meta.videoBookCount,
  if (meta.audiobookCount != null) 'audiobookCount': meta.audiobookCount,
  if (meta.gameCount != null) 'gameCount': meta.gameCount,
  'excludedCategories': meta.excludedCategories.toList()..sort(),
};

Map<String, Object?> backupSummaryToWire(BackupContentSummary summary) =>
    <String, Object?>{
      for (final MapEntry<BackupCategory, int> e in summary.counts.entries)
        e.key.name: e.value,
    };

// ── 云同步 ───────────────────────────────────────────────────────────

/// 一种同步后端在本机的状态（**只有**是否配置 / 是否选中，不含任何凭据）。
Map<String, Object?> syncBackendToWire({
  required SyncBackendType type,
  required bool selected,
  required bool configured,
}) => <String, Object?>{
  'id': type.name,
  'selected': selected,
  'configured': configured,
};

Map<String, Object?>? syncOutcomeToWire(SyncRunOutcome? outcome) =>
    outcome == null
    ? null
    : <String, Object?>{
        'kind': outcome.kind.name,
        'reason': outcome.reason.name,
        'channelsRun': outcome.channelsRun,
        'finishedAt': outcome.finishedAt,
      };

// ── 互联 ─────────────────────────────────────────────────────────────

/// 本机作为 client 记住的一条 host 地址。`token` 只报「有没有」，绝不回值。
Map<String, Object?> peerHostUrlToWire(FushiClientUrl url) => <String, Object?>{
  'url': url.url,
  'enabled': url.enabled,
  if (url.deviceName != null) 'deviceName': url.deviceName,
  if (url.hostId != null) 'hostId': url.hostId,
  if (url.addressKind != null) 'addressKind': url.addressKind,
  'learned': url.learned,
  'paired': url.token?.isNotEmpty ?? false,
  'pinned': url.fingerprintSha256?.isNotEmpty ?? false,
};

// ── 下载 ─────────────────────────────────────────────────────────────

/// `dl add` 的目标分型。
enum CtlDownloadTargetKind { magnet, torrentFile, url }

CtlDownloadTargetKind classifyDownloadTarget(String target) {
  final String lower = target.trim().toLowerCase();
  if (lower.startsWith('magnet:?')) return CtlDownloadTargetKind.magnet;
  if (lower.startsWith('http://') || lower.startsWith('https://')) {
    return CtlDownloadTargetKind.url;
  }
  if (lower.endsWith('.torrent')) return CtlDownloadTargetKind.torrentFile;
  throw const CtlFailure.badRequest('只认磁力链接（magnet:?…）或 .torrent 文件');
}

/// 磁链任务的标题：显式给的优先，否则取磁链里的 `dn`（显示名）。都没有返回 null。
String? magnetTaskTitle(String magnet, String? explicitTitle) {
  final String? given = explicitTitle?.trim();
  if (given != null && given.isNotEmpty) return given;
  final Uri? uri = Uri.tryParse(magnet.trim());
  final String? dn = uri?.queryParameters['dn']?.trim();
  return (dn == null || dn.isEmpty) ? null : dn;
}

// ── 媒体服务器 ───────────────────────────────────────────────────────

/// 按 CLI 给的 id 找服务器：1 起的序号（`mediaserver ls` 的第一列），或完整
/// `sourceId`。找不到抛 404。
MediaServerConfig resolveMediaServerConfig(
  List<MediaServerConfig> configs,
  String id,
) {
  final int? index = int.tryParse(id);
  if (index != null && index >= 1 && index <= configs.length) {
    return configs[index - 1];
  }
  for (final MediaServerConfig config in configs) {
    if (config.sourceId == id) return config;
  }
  throw CtlFailure.notFound('没有这台媒体服务器：$id（用 mediaserver ls 查看）');
}

/// 服务器配置的展示面：`accountName` 是用户名（不是凭据），URL 是服务器根地址。
Map<String, Object?> mediaServerConfigToWire(
  MediaServerConfig config, {
  required int index,
}) => <String, Object?>{
  'index': index,
  'id': config.sourceId,
  'kind': config.kind.wireName,
  'url': config.effectiveServerUrl,
  'account': config.accountName,
  'routes': config.routeUrls.length,
};

Map<String, Object?> mediaServerLibraryToWire(MediaServerLibrary library) =>
    <String, Object?>{
      'id': library.id,
      'name': library.name,
      'type': 'library:${library.kind.name}',
    };

Map<String, Object?> mediaServerItemToWire(MediaServerItem item) =>
    <String, Object?>{
      'id': item.id,
      'name': item.name,
      'type': item.type.name,
      if (item.productionYear != null) 'year': item.productionYear,
      if (item.seriesName != null) 'seriesName': item.seriesName,
      if (item.episodeCode.isNotEmpty) 'episode': item.episodeCode,
      if (item.childCount != null) 'childCount': item.childCount,
      if (item.durationMs != null) 'durationMs': item.durationMs,
      'played': item.played,
      'playable': item.isPlayable,
    };

Map<String, Object?> mediaServerPageToWire(MediaServerPage page) =>
    <String, Object?>{
      'items': page.items.map(mediaServerItemToWire).toList(),
      'totalCount': page.totalCount,
      'startIndex': page.startIndex,
      'nextStartIndex': page.nextStartIndex,
      'hasMore': page.hasMore,
    };
