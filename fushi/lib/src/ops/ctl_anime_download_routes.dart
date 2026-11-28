import 'package:fushi_cli/fushi_cli.dart';

import 'package:fushi/src/media/torrent/anime_download_plan.dart';
import 'package:fushi/src/media/torrent/anime_download_service.dart';
import 'package:fushi/src/models/store_compliance.dart';
import 'package:fushi/src/ops/op_describe_kit.dart';

/// 动画下载计划（「下载动画」对话框里的计划列表）的操作实现（拍板台 PGpPujl99g；声明见
/// `packages/fushi_cli/lib/src/ops/specs/anime_download_ops.dart`）：
/// 列出计划，以及计划行「边下边播」背后的 [AnimeDownloadService.importNow]——不等种子下完，
/// 立刻按计划入库。下载中心属于 iOS 上架去掉的能力（判据只认 [StoreRestrictedCapability]）。
///
/// CLI 侧是 `fushi_cli anime plans / anime import-now <planId>`。
List<FushiOp> buildAnimeDownloadOps(OpDescribeKit kit) =>
    buildAnimeDownloadOpsFor(
      () => StoreRestrictedCapability.downloads.isAvailable
          ? kit.context.appModel.animeDownloadService
          : null,
      availability: kit.whenStoreAllows(StoreRestrictedCapability.downloads),
    );

/// 操作本体：服务按回调注入；null = 不可用（合规门 / 还没初始化）。
List<FushiOp> buildAnimeDownloadOpsFor(
  AnimeDownloadService? Function() service, {
  OpAvailability Function()? availability,
}) {
  AnimeDownloadService requireService() {
    final AnimeDownloadService? s = service();
    if (s == null) {
      throw const CtlFailure.unsupported('本机没有动画下载（下载中心不可用或还没初始化）');
    }
    return s;
  }

  return <FushiOp>[
    AnimeDownloadOps.planList.bind(
      availability: availability,
      handler: (OpArgs args) async {
        final AnimeDownloadService s = requireService();
        return <String, Object?>{
          'plans': <Object?>[
            for (final AnimeDownloadPlan plan in await s.store.loadAll())
              <String, Object?>{
                'id': plan.id,
                'series': plan.seriesTitle,
                'torrent': plan.torrentTitle,
                'status': plan.status,
                if (plan.importedEarly) 'importedEarly': true,
                if (plan.importInProgress) 'importing': true,
                'failReason': ?plan.failReason,
                'collectionId': ?plan.collectionId,
                'createdAt': plan.createdAtMs,
              },
          ],
        };
      },
    ),
    AnimeDownloadOps.planImportNow.bind(
      availability: availability,
      handler: (OpArgs args) async {
        final AnimeDownloadService s = requireService();
        final String id = args.rawText(AnimeDownloadOps.planId)!;
        AnimeDownloadPlan? plan;
        for (final AnimeDownloadPlan p in await s.store.loadAll()) {
          if (p.id == id) plan = p;
        }
        if (plan == null) {
          throw CtlFailure.notFound('没有下载计划 $id（见 anime plans）');
        }
        if (plan.status != AnimeDownloadPlan.statusDownloading) {
          throw CtlFailure.conflict('计划 $id 不在下载中（${plan.status}），不用提前入库');
        }
        if (!await s.importNow(id)) {
          throw const CtlFailure.conflict(
            '还不能入库：种子元数据还没解析出视频文件，或下载后端没配置好；稍后再试',
          );
        }
        return <String, Object?>{'id': id, 'imported': true};
      },
    ),
  ];
}
