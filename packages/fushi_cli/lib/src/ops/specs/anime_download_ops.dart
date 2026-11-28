/// 动画下载计划（「下载动画」对话框里的计划列表）的操作声明（拍板台 PGpPujl99g）。
/// 实现在 app `fushi/lib/src/ops/ctl_anime_download_routes.dart`，CLI 命令在
/// `commands/anime_commands.dart`，都引用这里的同一个对象。
///
/// 「边下边播」irreversible：视频行与合集立刻建进视频库（之后下载补齐时复用，不重复导入），
/// 没有可撤回的前态；计划仍在下载中、照常轮询。
library;

import '../fushi_op.dart';
import '../op_spec.dart';

abstract final class AnimeDownloadOps {
  /// 路由根。
  static const String root = '/api/admin/anime-downloads';

  static const OpSpec planList = OpSpec(
    id: 'anime.plan.list',
    method: 'GET',
    pattern: root,
    summary:
        'Anime download plans (series, torrent, status, imported early, '
        'failure reason).',
  );

  static const OpParam planId = OpParam.string(
    'id',
    description: 'Plan id from anime.plan.list.',
    required: true,
    inPath: true,
  );

  static const OpSpec planImportNow = OpSpec(
    id: 'anime.plan.import-now',
    method: 'POST',
    pattern: '$root/:id/import-now',
    summary:
        'Add a still-downloading anime plan to the video library now ("Play '
        'while downloading"): episodes not downloaded yet show as missing '
        'until the download fills them in.',
    risk: OpRisk.irreversible,
    params: <OpParam>[planId],
  );
}
