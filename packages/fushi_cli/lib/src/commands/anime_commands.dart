import '../ctl_commands.dart';
import '../ops/specs/anime_download_ops.dart';

/// `fushi_cli anime …`：动画下载计划（app 侧路由见
/// `fushi/lib/src/ops/ctl_anime_download_routes.dart`）。新建计划仍走 app 的「下载动画」
/// 或 `aidl`（AI 下载会话）。
const List<CtlCommandGroup> animeCommandGroups = <CtlCommandGroup>[
  CtlCommandGroup(
    name: 'anime',
    summary: '动画下载计划：列表 / 边下边播（提前入库）',
    commands: <CtlCommandSpec>[
      CtlCommandSpec(
        name: 'plans',
        summary: '列出动画下载计划',
        op: AnimeDownloadOps.planList,
        call: _callPlans,
        render: _renderPlans,
      ),
      CtlCommandSpec(
        name: 'import-now',
        summary: '边下边播：不等下完，立刻把这个计划入库（还没下到的集显示为缺失）',
        usage: '<planId>',
        op: AnimeDownloadOps.planImportNow,
        call: _callImportNow,
      ),
    ],
  ),
];

CtlOpCall _callPlans(CtlCommandContext c) => const CtlOpCall();

CtlOpCall _callImportNow(CtlCommandContext c) => CtlOpCall(
  pathArgs: <String, String>{
    AnimeDownloadOps.planId.name: c.positional(0, 'planId').trim(),
  },
);

String _renderPlans(Object? data) => renderCtlTable(
  data,
  const <(String, String)>[
    ('id', 'id'),
    ('作品', 'series'),
    ('状态', 'status'),
    ('已提前入库', 'importedEarly'),
    ('种子', 'torrent'),
    ('失败原因', 'failReason'),
  ],
  listKey: 'plans',
  empty: '（没有下载计划）',
);
