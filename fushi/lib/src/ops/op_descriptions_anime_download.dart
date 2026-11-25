import 'package:fushi_cli/fushi_cli.dart';

import 'package:fushi/src/models/store_compliance.dart';
import 'package:fushi/src/ops/ctl_anime_download_routes.dart';
import 'package:fushi/src/ops/op_describe_kit.dart';

/// 动画下载计划的操作描述；路由见 `ctl_anime_download_routes.dart`。
///
/// 「边下边播」irreversible：视频行与合集立刻建进视频库（之后下载补齐时复用，不重复导入），
/// 没有可撤回的前态；计划仍在下载中、照常轮询。
List<OpDescription> describeAnimeDownloadOps(OpDescribeKit kit) {
  final OpAvailability Function() downloads = kit.whenStoreAllows(
    StoreRestrictedCapability.downloads,
  );
  return <OpDescription>[
    OpDescription(
      id: 'anime.plan.list',
      method: 'GET',
      pattern: kAnimeDownloadCtlRoot,
      summary:
          'Anime download plans (series, torrent, status, imported early, '
          'failure reason).',
      availability: downloads,
    ),
    OpDescription(
      id: 'anime.plan.import-now',
      method: 'POST',
      pattern: '$kAnimeDownloadCtlRoot/:id/import-now',
      summary:
          'Add a still-downloading anime plan to the video library now ("Play '
          'while downloading"): episodes not downloaded yet show as missing '
          'until the download fills them in.',
      risk: OpRisk.irreversible,
      availability: downloads,
      params: const <OpParam>[
        OpParam.string(
          'id',
          description: 'Plan id from anime.plan.list.',
          required: true,
          inPath: true,
        ),
      ],
    ),
  ];
}
