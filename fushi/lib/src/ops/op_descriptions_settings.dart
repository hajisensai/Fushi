import 'package:fushi_cli/fushi_cli.dart';

import 'package:fushi/src/ops/op_describe_kit.dart';

/// 设置域的操作描述（spec §4.3）：设置不逐项写操作，走 schema 的四个通用操作
/// 加模块开关。值的读写都是 `ctl_settings_routes.dart` 里同一组闭包（与在设置页
/// 拨开关等价）；机密项沿用 `isCtlSecretSetting`——读回脱敏、AI 写不进去
/// （路由要求机密值只能经 stdin / 环境变量，模型给的值一律按命令行值拒绝）。
List<OpDescription> describeSettingsOps(OpDescribeKit kit) => <OpDescription>[
  const OpDescription(
    id: 'settings.search',
    method: 'GET',
    pattern: '/api/admin/settings',
    summary:
        'Search app settings by keyword (matches id, title and breadcrumb). '
        'Returns key, title, section, type, current value and allowed options.',
    params: <OpParam>[
      OpParam.string(
        'search',
        description:
            'Keyword in the UI language or English, e.g. "subtitle size".',
      ),
      OpParam.string(
        'kind',
        description: 'Row kind filter; default value.',
        enumValues: <String>[
          'value',
          'action',
          'status',
          'list',
          'custom',
          'all',
        ],
      ),
      OpParam.boolean(
        'all',
        description: 'Include rows hidden on this platform / state.',
      ),
    ],
  ),
  const OpDescription(
    id: 'settings.get',
    method: 'GET',
    pattern: '/api/admin/settings/:key',
    summary: 'Read one setting by key (value, options, range, default).',
    params: <OpParam>[
      OpParam.string(
        'key',
        description: 'Setting key from settings.search.',
        required: true,
        inPath: true,
      ),
    ],
  ),
  OpDescription(
    id: 'settings.set',
    method: 'PUT',
    pattern: '/api/admin/settings/:key',
    summary:
        'Change one setting, exactly like changing it on the settings page. '
        'Value is a bool / number / option token or label / text.',
    risk: OpRisk.write,
    params: const <OpParam>[
      OpParam.string(
        'key',
        description: 'Setting key from settings.search.',
        required: true,
        inPath: true,
      ),
      OpParam.string(
        'value',
        description:
            'New value (true/false, number, option token or label, text).',
        required: true,
      ),
    ],
    undo: kit.readBackUndo(
      readMethod: 'GET',
      readPattern: '/api/admin/settings/:key',
      writeMethod: 'PUT',
      writePattern: '/api/admin/settings/:key',
    ),
  ),
  OpDescription(
    id: 'settings.reset',
    method: 'POST',
    pattern: '/api/admin/settings/:key/reset',
    summary: 'Reset one setting to its default value.',
    risk: OpRisk.write,
    params: const <OpParam>[
      OpParam.string(
        'key',
        description: 'Setting key.',
        required: true,
        inPath: true,
      ),
    ],
    undo: kit.readBackUndo(
      readMethod: 'GET',
      readPattern: '/api/admin/settings/:key',
      writeMethod: 'PUT',
      writePattern: '/api/admin/settings/:key',
    ),
  ),
  const OpDescription(
    id: 'settings.run',
    method: 'POST',
    pattern: '/api/admin/settings/:key/run',
    summary:
        'Run an action row of the settings page (clear cache, test connection, '
        'rebuild index…). Only rows listed with kind=action and runnable=true.',
    risk: OpRisk.irreversible,
    params: <OpParam>[
      OpParam.string(
        'key',
        description: 'Action row key.',
        required: true,
        inPath: true,
      ),
      OpParam.object(
        'args',
        description:
            'Parameters the action row declares (see "params" in settings.get).',
        spread: true,
      ),
      OpParam.userGate(
        'confirm',
        description: 'User confirmed a destructive action.',
      ),
    ],
  ),
  const OpDescription(
    id: 'modules.list',
    method: 'GET',
    pattern: '/api/admin/modules',
    summary:
        'List feature modules (books, manga, video, music, games…) and whether each is on.',
  ),
  OpDescription(
    id: 'modules.set',
    method: 'PUT',
    pattern: '/api/admin/modules/:id',
    summary: 'Turn a feature module on or off.',
    risk: OpRisk.write,
    params: const <OpParam>[
      OpParam.string(
        'id',
        description: 'Module id from modules.list.',
        required: true,
        inPath: true,
      ),
      OpParam.boolean('enabled', description: 'true = on.', required: true),
    ],
    undo: kit.snapshotUndo(
      read: (Map<String, String> params) => kit.readListField(
        pattern: '/api/admin/modules',
        listKey: 'modules',
        id: params['id']!,
        field: 'enabled',
      ),
      write: (Map<String, String> params, Object? old) async {
        await kit.callRoute(
          'PUT',
          '/api/admin/modules/:id',
          params: params,
          body: <String, Object?>{'enabled': old == true},
        );
      },
      newValue: (CtlCall call, Object? result) =>
          result is Map ? result['enabled'] : call.body['enabled'],
    ),
  ),
];
