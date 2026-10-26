/// data 域控制通道：磁链 / `.torrent` 任务的完整入队（目标库、字幕策略、文件选择、
/// 作品身份、优先级、执行设备），以及 `dl targets` 的落点清单。
///
/// 业务全在 app 既有入口里：参数校验复用互联代下载的 [HostDownloadAddRequest.fromJson]
/// （与 `/api/downloads`、无头服务端同一份规则），本机入队走「添加任务」对话框同一个
/// [VideoDownloadPipelineService.enqueueManual]，交给互联 host 走对话框远端分支同一个
/// [InterconnectDownloadClient.addMagnet]，「执行设备」偏好的解析复用
/// [resolveDownloadExecution]。这里只做参数拼装与错误映射。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart' show MediaSourceRow;
import 'package:fushi_engine/media/discovery/discovery_models.dart'
    show DiscoveryMediaKind;
import 'package:fushi_engine/media/torrent/torrent_metainfo.dart';
import 'package:fushi_engine/media/video/download/video_download_backend_identity.dart';
import 'package:fushi_engine/media/video/download/video_download_pipeline_service.dart';
import 'package:fushi_engine/sync/downloads/host_download_host.dart'
    show HostDownloadAddRequest;
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/downloads/download_execution_target.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/store_compliance.dart';
import 'package:fushi/src/ops/ctl_data_wire.dart';
import 'package:fushi/src/sync/interconnect_download_client.dart';
import 'package:fushi/src/sync/sync_repository.dart';

/// 下载中心（含订阅）的门：合规门（iOS 无下载中心）+「浏览」模块开关（下载页签挂在
/// 它下面）。
void requireCtlDownloadCenter(AppModel appModel) {
  if (!StoreRestrictedCapability.downloads.isAvailable) {
    throw const CtlFailure.unsupported('本平台不提供下载中心');
  }
  if (!appModel.moduleVisibility.isEnabled(ModuleId.browse)) {
    throw const CtlFailure.rejected('「浏览」模块已关闭（设置 › 功能模块）');
  }
}

/// 执行设备的解析结果：本机，或某台宣告了代下载能力的互联 host。
sealed class CtlDownloadDevice {
  const CtlDownloadDevice();
}

class CtlDownloadDeviceLocal extends CtlDownloadDevice {
  const CtlDownloadDeviceLocal();
}

class CtlDownloadDeviceRemote extends CtlDownloadDevice {
  const CtlDownloadDeviceRemote(this.target, this.client);

  final HostDownloadTarget target;
  final InterconnectDownloadClient client;
}

/// `--device`：缺省按「下载执行设备」偏好（与下载页添加任务同一解析，偏好指向的
/// host 连不上时**不**静默退回本机）；`local` = 本机；其余按 hostId / 地址 / 设备名
/// 在宣告代下载能力的 host 里找。
Future<CtlDownloadDevice> resolveCtlDownloadDevice(
  AppModel appModel,
  String? selector,
) async {
  final SyncRepository repo = SyncRepository(appModel.database);
  final InterconnectDownloadClient client = InterconnectDownloadClient(
    repo: repo,
  );
  if (selector == null) {
    final DownloadExecutionResolution execution =
        await resolveDownloadExecution(appModel, client: client);
    return switch (execution) {
      DownloadExecutionLocal() => const CtlDownloadDeviceLocal(),
      DownloadExecutionRemote(:final HostDownloadTarget target) =>
        CtlDownloadDeviceRemote(target, client),
      DownloadExecutionUnreachable(:final String label) =>
        throw CtlFailure.conflict(
          '下载执行设备「$label」连不上或没开代下载；用 --device local 改在本机下，'
          '或 dl targets 查看可用设备',
        ),
    };
  }
  if (selector == 'local') return const CtlDownloadDeviceLocal();
  final HostDownloadTarget? target = matchDownloadHost(
    await client.probeAll(),
    await repo.getFushiClientUrls(),
    selector,
  );
  if (target == null) {
    throw CtlFailure.notFound(
      '没有可代下载的 host：$selector（dl targets 查看；host 要在线且开了下载后端）',
    );
  }
  return CtlDownloadDeviceRemote(target, client);
}

/// 任务操作的 `device`：null / `local` = 本机任务（返回 null）；其余必须解析到一台
/// 在线、宣告代下载能力的 host。与下载页「远端任务」段同一套客户端。
Future<CtlDownloadDeviceRemote?> resolveCtlRemoteJobDevice(
  AppModel appModel,
  String? selector,
) async {
  if (selector == null || selector == 'local') return null;
  final CtlDownloadDevice device = await resolveCtlDownloadDevice(
    appModel,
    selector,
  );
  return device is CtlDownloadDeviceRemote ? device : null;
}

/// 远端请求失败 → 422（带 host 名，错误先抹凭据）。
Future<T> mapCtlHostErrors<T>(
  HostDownloadTarget target,
  Future<T> Function() body,
) async {
  try {
    return await body();
  } on HostDownloadException catch (e) {
    throw CtlFailure.rejected(
      'host「${target.label}」拒绝了操作：${redactCtlSecrets('$e')}',
    );
  }
}

/// 在远端任务表里找 [jobId]（远端协议没有单条查询，与任务段一样整表拉）。
Future<HostDownloadJob> requireCtlHostJob(
  CtlDownloadDeviceRemote remote,
  String jobId,
) async {
  final List<HostDownloadJob> jobs = await mapCtlHostErrors(
    remote.target,
    () => remote.client.listJobs(remote.target),
  );
  for (final HostDownloadJob job in jobs) {
    if (job.jobId == jobId) return job;
  }
  throw CtlFailure.notFound('host「${remote.target.label}」上没有这个任务：$jobId');
}

/// 磁链 / `.torrent` 入队。[torrentPath] 与 [magnet] 恰好给一个。
Future<Map<String, Object?>> addCtlTorrentDownload({
  required AppModel appModel,
  required CtlCall call,
  String? magnet,
  String? torrentPath,
}) async {
  final ({String mediaKind, String? discoveryKind}) kind = splitDownloadKind(
    call.optString('mediaKind'),
  );
  final int? sourceId = call.optInt('source');
  final int? priority = call.optInt('priority');
  if (kind.discoveryKind != null && sourceId != null) {
    throw const CtlFailure.badRequest('--source 只用于视频任务（movie / tv）');
  }
  // 线格式与 `/api/downloads` 一致，交给 HostDownloadAddRequest.fromJson 统一校验
  // （文件下标范围、年份、资料源 + id 成对、字幕策略取值）。
  final Map<String, Object?> wire = <String, Object?>{
    'mediaKind': kind.mediaKind,
    'discoveryKind': ?kind.discoveryKind,
    'files': ?parseDownloadFileIndexes(call.stringList('files')),
    'year': ?call.optInt('year'),
    'metadataProvider': ?call.optString('metadataProvider'),
    'externalId': ?call.optString('externalId'),
    'subtitlePolicy': ?call.optString('subtitlePolicy'),
  };
  String? title = call.optString('title');
  if (magnet != null) {
    wire['magnet'] = magnet;
    title ??= magnetTaskTitle(magnet, null);
    if (title == null) {
      throw const CtlFailure.badRequest('磁链里没有显示名（dn），请用 --title 指定');
    }
  } else {
    final String path = torrentPath!;
    if (!p.isAbsolute(path) || !await File(path).exists()) {
      throw CtlFailure.notFound('种子文件不存在：$path');
    }
    final Uint8List bytes = await File(path).readAsBytes();
    if (title == null) {
      try {
        title = inspectTorrentMetainfo(bytes).suggestedName;
      } on TorrentMetainfoException catch (e) {
        throw CtlFailure.badRequest('不是有效的 .torrent 文件：${e.message}');
      }
      title ??= p.basenameWithoutExtension(path);
    }
    wire['torrent'] = base64Encode(bytes);
  }
  wire['title'] = title;
  final HostDownloadAddRequest request;
  try {
    request = HostDownloadAddRequest.fromJson(wire);
  } on FormatException catch (e) {
    throw CtlFailure.badRequest(e.message);
  }

  final CtlDownloadDevice device = await resolveCtlDownloadDevice(
    appModel,
    call.optString('device'),
  );
  switch (device) {
    case CtlDownloadDeviceRemote(
      :final HostDownloadTarget target,
      :final InterconnectDownloadClient client,
    ):
      return _addRemote(
        request: request,
        target: target,
        client: client,
        sourceId: sourceId,
        priority: priority,
      );
    case CtlDownloadDeviceLocal():
      return _addLocal(
        appModel: appModel,
        request: request,
        sourceId: sourceId,
        priority: priority,
      );
  }
}

/// 本机：与「添加任务」对话框本机分支同一序列（后端落点 → 目标来源 → enqueueManual）。
Future<Map<String, Object?>> _addLocal({
  required AppModel appModel,
  required HostDownloadAddRequest request,
  required int? sourceId,
  required int? priority,
}) async {
  final VideoDownloadPipelineService pipeline =
      appModel.videoDownloadPipelineService ??
      (throw const CtlFailure.rejected('本机下载后端没有配好（浏览 › 下载 里配置）'));
  if (appModel.readyVideoDownloadBackend == null) {
    throw const CtlFailure.rejected('本机下载后端没有配好（浏览 › 下载 里配置）');
  }
  final String? discoveryName = request.discoveryKind;
  final DiscoveryMediaKind? discoveryKind = discoveryName == null
      ? null
      : DiscoveryMediaKind.values.byName(discoveryName);
  int? targetSourceId;
  if (discoveryKind == null) {
    final List<MediaSourceRow> sources = await appModel
        .getManagedVideoDownloadSources();
    if (sourceId != null) {
      if (!sources.any((MediaSourceRow s) => s.id == sourceId)) {
        throw CtlFailure.notFound('没有这个受管视频来源：$sourceId（dl targets 查看）');
      }
      targetSourceId = sourceId;
    } else {
      // 与对话框默认值同一规则：用户选的默认来源，没选就第一个可用的。
      final int? preferred = appModel.prefsRepo.videoDownloadTargetSourceId;
      targetSourceId =
          sources.any((MediaSourceRow s) => s.id == preferred) &&
              preferred != null
          ? preferred
          : sources.firstOrNull?.id;
    }
    if (targetSourceId == null) {
      throw const CtlFailure.rejected('没有可用的受管视频来源（先在视频库添加本地来源）');
    }
  }
  final VideoDownloadBackendTarget backendTarget;
  try {
    backendTarget = await appModel.currentVideoDownloadBackendTarget();
  } on VideoDownloadBackendUnavailable catch (e) {
    throw CtlFailure.rejected(e.message);
  }
  final String jobId;
  try {
    jobId = await pipeline.enqueueManual(
      request.toEnqueueRequest(
        backendTarget: backendTarget,
        discoveryKind: discoveryKind,
        targetSourceId: targetSourceId,
      ),
    );
    if (priority != null && priority != 0) {
      await pipeline.setJobPriority(jobId, priority);
    }
  } on VideoDownloadAlreadyQueued catch (e) {
    throw CtlFailure.conflict(e.message);
  } on VideoDownloadPipelineActionRequired catch (e) {
    throw CtlFailure.rejected(e.message);
  } on ArgumentError catch (e) {
    throw CtlFailure.badRequest('${e.message}');
  }
  return <String, Object?>{
    'jobId': jobId,
    'title': request.title,
    'device': 'local',
    'targetSourceId': ?targetSourceId,
    'subtitlePolicy':
        (request.subtitlePolicy ?? VideoDownloadSubtitlePolicy.none).name,
    if (request.selectedFileIndexes != null)
      'files': request.selectedFileIndexes!.toList()..sort(),
    'priority': priority ?? 0,
  };
}

/// 互联 host：与对话框远端分支同一入口，host 只收磁链（不收 `.torrent`、文件选择、
/// 字幕策略、作品身份——那几项远端协议客户端没有，硬塞只会被静默丢掉）。
Future<Map<String, Object?>> _addRemote({
  required HostDownloadAddRequest request,
  required HostDownloadTarget target,
  required InterconnectDownloadClient client,
  required int? sourceId,
  required int? priority,
}) async {
  final String? magnet = request.magnetUri;
  if (magnet == null) {
    throw CtlFailure.badRequest(
      '交给互联 host「${target.label}」只能用磁链（.torrent 用 --device local 在本机下）',
    );
  }
  final List<String> unsupported = <String>[
    if (sourceId != null) '--source',
    if (priority != null) '--priority',
    if (request.subtitlePolicy != null) '--subtitles',
    if (request.year != null) '--year',
    if (request.metadataProvider != null) '--provider / --external-id',
  ];
  if (unsupported.isNotEmpty) {
    throw CtlFailure.badRequest(
      '交给互联 host 的任务不支持 ${unsupported.join('、')}（由 host 按它的默认值处理）',
    );
  }
  if (!target.supportsKind(request.discoveryKind)) {
    throw CtlFailure.rejected(
      'host「${target.label}」不收这类内容：${request.discoveryKind}',
    );
  }
  final String jobId;
  try {
    jobId = await client.addMagnet(
      target,
      magnetUri: magnet,
      title: request.title,
      mediaKind: request.mediaKind,
      discoveryKind: request.discoveryKind,
    );
  } on HostDownloadException catch (e) {
    throw CtlFailure.rejected(
      'host「${target.label}」拒绝了任务：${redactCtlSecrets('$e')}',
    );
  }
  return <String, Object?>{
    'jobId': jobId,
    'title': request.title,
    'device': target.label,
    'remote': true,
  };
}

/// `dl targets`：视频任务可投的目标库 + 当前执行设备偏好 + 在线且能代下载的 host。
Future<Map<String, Object?>> ctlDownloadTargets(AppModel appModel) async {
  final SyncRepository repo = SyncRepository(appModel.database);
  final List<FushiClientUrl> paired = await repo.getFushiClientUrls();
  final List<MediaSourceRow> sources = await appModel
      .getManagedVideoDownloadSources();
  final int? preferred = appModel.prefsRepo.videoDownloadTargetSourceId;
  final int? defaultId =
      preferred != null && sources.any((MediaSourceRow s) => s.id == preferred)
      ? preferred
      : sources.firstOrNull?.id;
  final String executionUrl = appModel.prefsRepo.downloadExecutionHostUrl;
  final List<HostDownloadTarget> hosts = await InterconnectDownloadClient(
    repo: repo,
  ).probeAll();
  return <String, Object?>{
    'localBackend': appModel.readyVideoDownloadBackend ?? 'none',
    'executionDevice': executionUrl.isEmpty ? 'local' : executionUrl,
    'sources': <Map<String, Object?>>[
      for (final MediaSourceRow s in sources)
        downloadSourceToWire(s, isDefault: s.id == defaultId),
    ],
    'hosts': <Map<String, Object?>>[
      for (final HostDownloadTarget h in hosts) downloadHostToWire(h, paired),
    ],
  };
}
