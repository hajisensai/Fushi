/// data 域控制通道：视频下载订阅（CLI `fushi_cli sub`，命令见
/// `packages/fushi_cli/lib/src/commands/data_commands.dart`）。
///
/// 每条路由只调 [AppSubscriptionHost]——订阅页（`video_download_subscriptions_panel.dart`）
/// 按钮背后的同一份实现，这里只做门控、参数解析与出参。路径与无头服务端
/// `admin_api.dart` 的 `/api/admin/subscriptions` 同形（列表 / 检查 / 启停 / 删除），
/// 本机多出详情、逐集历史与编辑。新建订阅走 `aidl`（AI 下视频）或发现页，不在这里。
library;

import 'package:drift/drift.dart' show Value;
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart'
    show
        MediaSourceRow,
        VideoDownloadSubscriptionItemRow,
        VideoDownloadSubscriptionRow;
import 'package:fushi_engine/media/video/download/video_download_subscription_service.dart'
    show kVideoSubscriptionTitleExcludeKey, kVideoSubscriptionTitleIncludeKey;
import 'package:fushi_engine/sync/subscriptions/host_subscription_host.dart'
    show videoDownloadSubscriptionToWire;
import 'package:fushi_engine/sync/subscriptions/host_subscription_routes.dart'
    show HostSubscriptionRejected;
import 'package:fushi_engine/sync/subscriptions/pipeline_subscription_host.dart'
    show VideoDownloadSubscriptionRuleEdit;

import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/video_download_subscription_edit_dialog.dart'
    show editVideoSubscriptionFilterJson, videoSubscriptionFilterValues;
import 'package:fushi/src/ops/ctl_download_support.dart'
    show requireCtlDownloadCenter;
import 'package:fushi/src/ops/op_context.dart';
import 'package:fushi/src/sync/app_download_host.dart' show AppSubscriptionHost;

/// 订阅路由表（挂在 `buildDataCtlRoutes` 下）。
List<CtlRoute> buildDownloadSubscriptionCtlRoutes(OpContext context) {
  AppSubscriptionHost host() {
    requireCtlDownloadCenter(context.appModel);
    return context.appModel.appDownloadHost.subscriptions;
  }

  return <CtlRoute>[
    // 与订阅页列表同一份数据：能力位 + 订阅行 + 卡片上的逐集计数。
    CtlRoute.get('/api/admin/subscriptions', (CtlCall call) async {
      final AppSubscriptionHost subs = host();
      final Map<String, Map<String, int>> counts = await subs.itemCounts();
      return <String, Object?>{
        ...await subs.capability(),
        'subscriptions': <Map<String, Object?>>[
          for (final VideoDownloadSubscriptionRow row in await subs.list())
            _subscriptionToWire(row, counts[row.subscriptionId]),
        ],
      };
    }),
    CtlRoute.get('/api/admin/subscriptions/:id', (CtlCall call) async {
      final AppSubscriptionHost subs = host();
      final VideoDownloadSubscriptionRow row = await _requireRow(
        subs,
        call.params['id']!,
      );
      return _subscriptionToWire(
        row,
        (await subs.itemCounts())[row.subscriptionId],
      );
    }),
    // 订阅卡展开后的逐集状态视图。
    CtlRoute.get('/api/admin/subscriptions/:id/items', (CtlCall call) async {
      final List<VideoDownloadSubscriptionItemRow> items = await _mapRejected(
        () => host().items(call.params['id']!),
      );
      return <String, Object?>{
        'items': <Map<String, Object?>>[
          for (final VideoDownloadSubscriptionItemRow item in items)
            _itemToWire(item),
        ],
      };
    }),
    // 订阅页「全部检查」：所有启用的订阅立即到期，跑一轮。
    CtlRoute.post('/api/admin/subscriptions/check', (CtlCall call) async {
      await _mapRejected(() => host().checkNow(null));
      return null;
    }),
    // 订阅卡「立即检查」。
    CtlRoute.post('/api/admin/subscriptions/:id/check', (CtlCall call) async {
      await _mapRejected(() => host().checkNow(call.params['id']!));
      return null;
    }),
    // 订阅卡开关（body `enabled`）。
    CtlRoute.post('/api/admin/subscriptions/:id/enable', (CtlCall call) async {
      final bool enabled =
          call.optBool('enabled') ??
          (throw const CtlFailure.badRequest('enabled 缺失'));
      final AppSubscriptionHost subs = host();
      final String id = call.params['id']!;
      await _mapRejected(() => subs.setEnabled(id, enabled));
      return _subscriptionToWire(await _requireRow(subs, id), null);
    }),
    // 订阅卡「编辑」：只改给出的字段（与编辑对话框同一组白名单列）。
    CtlRoute.put('/api/admin/subscriptions/:id', (CtlCall call) async {
      final AppSubscriptionHost subs = host();
      final VideoDownloadSubscriptionRow row = await _requireRow(
        subs,
        call.params['id']!,
      );
      final VideoDownloadSubscriptionRuleEdit edit = await _parseEdit(
        context.appModel,
        call,
        row,
      );
      if (edit.isEmpty) {
        throw const CtlFailure.badRequest('没有要改的字段');
      }
      return _subscriptionToWire(
        await _mapRejected(() => subs.update(row.subscriptionId, edit)),
        null,
      );
    }),
    // 订阅卡「删除」：只删订阅与逐集历史，已派出的下载任务与文件不动。
    CtlRoute.delete('/api/admin/subscriptions/:id', (CtlCall call) async {
      if (call.optBool('confirm') != true) {
        throw const CtlFailure.badRequest('删除订阅需要确认（confirm: true）');
      }
      final String id = call.params['id']!;
      await _mapRejected(() => host().delete(id));
      return <String, Object?>{'ok': true, 'subscriptionId': id};
    }),
  ];
}

Future<VideoDownloadSubscriptionRow> _requireRow(
  AppSubscriptionHost subs,
  String id,
) async {
  for (final VideoDownloadSubscriptionRow row in await subs.list()) {
    if (row.subscriptionId == id) return row;
  }
  throw CtlFailure.notFound('没有这个订阅：$id');
}

/// host 的拒绝 → 对应状态码（没有下载后端 / 订阅已停用是 409，未知 id 404）。
Future<T> _mapRejected<T>(Future<T> Function() body) async {
  try {
    return await body();
  } on HostSubscriptionRejected catch (e) {
    final String message = switch (e.reason) {
      'unsupported' => '本机下载后端没有配好（浏览 › 下载 里配置）',
      'disabled' => '订阅已停用，先 sub enable',
      'not_found' => '没有这个订阅',
      _ => e.message,
    };
    throw CtlFailure(e.status, e.reason, message);
  } on FormatException catch (e) {
    throw CtlFailure.badRequest(e.message);
  }
}

/// body → 编辑白名单。没出现的字段不动；`startAfterEpisode: null` = 清掉起始集。
/// 版本规则只改给出的那几项（字幕组 / 分辨率 / 标题包含 / 标题排除），其余规则
/// 原样保留——与编辑对话框同一个 [editVideoSubscriptionFilterJson]。
Future<VideoDownloadSubscriptionRuleEdit> _parseEdit(
  AppModel appModel,
  CtlCall call,
  VideoDownloadSubscriptionRow row,
) async {
  final Map<String, Object?> body = call.body;
  Value<int?> startAfter = const Value<int?>.absent();
  if (body.containsKey('startAfterEpisode')) {
    startAfter = Value<int?>(call.optInt('startAfterEpisode'));
  }
  Value<int?> target = const Value<int?>.absent();
  final int? source = call.optInt('source');
  if (source != null) {
    final List<MediaSourceRow> sources = await appModel
        .getManagedVideoDownloadSources();
    if (!sources.any((MediaSourceRow s) => s.id == source)) {
      throw CtlFailure.badRequest('目标库 $source 不是可用的受管视频来源（dl targets 查看）');
    }
    target = Value<int?>(source);
  }
  List<String> rule(String bodyKey, String filterKey) =>
      body.containsKey(bodyKey)
      ? call.stringList(bodyKey)
      : videoSubscriptionFilterValues(row.filterJson, filterKey);
  const List<String> ruleKeys = <String>[
    'releaseGroups',
    'resolutions',
    'titleIncludes',
    'titleExcludes',
  ];
  final Value<String> filter = ruleKeys.any(body.containsKey)
      ? Value<String>(
          editVideoSubscriptionFilterJson(
            row.filterJson,
            releaseGroups: rule('releaseGroups', 'releaseGroup'),
            resolutions: rule('resolutions', 'resolution'),
            titleIncludes: rule(
              'titleIncludes',
              kVideoSubscriptionTitleIncludeKey,
            ),
            titleExcludes: rule(
              'titleExcludes',
              kVideoSubscriptionTitleExcludeKey,
            ),
          ),
        )
      : const Value<String>.absent();
  final String? query = call.optString('searchQuery');
  final String? subtitles = call.optString('subtitlePolicy');
  try {
    return VideoDownloadSubscriptionRuleEdit(
      searchQuery: query == null
          ? const Value<String>.absent()
          : Value<String>(query),
      startAfterEpisode: startAfter,
      subtitlePolicy: subtitles == null
          ? const Value<String>.absent()
          : Value<String>(subtitles),
      targetSourceId: target,
      filterJson: filter,
    );
  } on FormatException catch (e) {
    throw CtlFailure.badRequest(e.message);
  }
}

/// 订阅行出参：wire 同互联 / 服务端，外加本机才有意义的目标库与版本规则。
Map<String, Object?> _subscriptionToWire(
  VideoDownloadSubscriptionRow row,
  Map<String, int>? itemCounts,
) => <String, Object?>{
  ...videoDownloadSubscriptionToWire(row, itemCounts: itemCounts),
  'targetSourceId': row.targetSourceId,
  'filterJson': row.filterJson,
};

Map<String, Object?> _itemToWire(VideoDownloadSubscriptionItemRow item) =>
    <String, Object?>{
      'title': item.title,
      'season': item.season,
      'episode': item.episode,
      'status': item.status,
      'jobId': item.jobId,
      'error': item.error,
      'publishedAt': item.publishedAt,
      'discoveredAt': item.discoveredAt,
      'updatedAt': item.updatedAt,
    };
