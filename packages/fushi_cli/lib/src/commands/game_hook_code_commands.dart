import 'package:args/args.dart';

import '../ctl_commands.dart';

/// `fushi_cli game hook-codes*`：Galgame Hook Code 配置的查看 / 导出 / 导入（app 侧路由见
/// `fushi/lib/src/ops/ctl_game_hook_code_routes.dart`）。并进 `game` 组。
const List<CtlCommandSpec> gameHookCodeCommands = <CtlCommandSpec>[
  CtlCommandSpec(
    name: 'hook-codes',
    summary: '列出已存的 Hook Code（按游戏 exe / 模块哈希）',
    build: _buildList,
    render: _renderList,
  ),
  CtlCommandSpec(
    name: 'hook-codes-export',
    summary: '把 Hook Code 配置导出成 .tsv（已存在要 --overwrite）',
    usage: '<文件.tsv>',
    configure: _configureExport,
    build: _buildExport,
    render: _renderCount,
  ),
  CtlCommandSpec(
    name: 'hook-codes-import',
    summary: '用 .tsv 整份替换 Hook Code 配置（不合并；可撤销）',
    usage: '<文件.tsv>',
    build: _buildImport,
    render: _renderCount,
  ),
];

const String _root = '/api/admin/game/hook-codes';

CtlRequestSpec _buildList(CtlCommandContext c) =>
    const CtlRequestSpec.get(_root);

void _configureExport(ArgParser parser) =>
    parser.addFlag('overwrite', negatable: false, help: '目标文件已存在时覆盖');

CtlRequestSpec _buildExport(CtlCommandContext c) => CtlRequestSpec.post(
  '$_root/export',
  body: <String, Object?>{
    'path': ctlAbsolutePath(c.positional(0, '文件.tsv')),
    if (c.flag('overwrite')) 'overwrite': true,
  },
);

CtlRequestSpec _buildImport(CtlCommandContext c) => CtlRequestSpec.post(
  '$_root/import',
  body: <String, Object?>{'path': ctlAbsolutePath(c.positional(0, '文件.tsv'))},
);

String _renderList(Object? data) => renderCtlTable(
  data,
  const <(String, String)>[
    ('exe sha256', 'executableSha256'),
    ('模块', 'module'),
    ('代码页', 'codepage'),
    ('Hook Code', 'hookCode'),
    ('备注', 'label'),
  ],
  listKey: 'profiles',
  empty: '（没有已存的 Hook Code）',
);

String _renderCount(Object? data) => data is Map
    ? '${data['path']}：${data['profiles']} 条 Hook Code'
    : renderCtlJson(data);
