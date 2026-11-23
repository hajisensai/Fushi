import 'dart:convert';

import 'package:fushi_cli/fushi_cli.dart';

import 'package:fushi/src/mining/galgame_hook_code_profile.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/ops/ctl_game_hook_code_routes.dart';
import 'package:fushi/src/ops/op_describe_kit.dart';

/// Galgame Hook Code 配置导入 / 导出的操作描述；路由见 `ctl_game_hook_code_routes.dart`。
///
/// - 导入 = 整份替换：执行前给整份内容拍快照，撤销时内容还是导入后的样子（指纹相同）才
///   写回，之后被改过（手动加 / 删 Hook Code、再导入）报 superseded；
/// - 导出写用户磁盘（`overwrite` 覆盖已有文件），irreversible。
List<OpDescription> describeGameHookCodeOps(OpDescribeKit kit) {
  final GameHookCodeCtlDeps deps = gameHookCodeCtlDeps(kit.context);
  final OpAvailability Function() available = kit
      .all(<OpAvailability Function()>[
        () => deps.available()
            ? const OpAvailability.available()
            : const OpAvailability.unavailable(
                'platform_unsupported',
                'Galgame Hook 只支持 Windows',
              ),
        kit.whenModule(ModuleId.games),
      ]);
  return <OpDescription>[
    OpDescription(
      id: 'game.hook-codes.list',
      method: 'GET',
      pattern: kGameHookCodeCtlRoot,
      summary:
          'Saved LunaHook hook codes (per game exe / module SHA-256, codepage, '
          'label) used to pick the text thread automatically.',
      availability: available,
    ),
    OpDescription(
      id: 'game.hook-codes.export',
      method: 'POST',
      pattern: '$kGameHookCodeCtlRoot/export',
      summary:
          'Write the saved hook codes to a .tsv file (like "Export hook codes" '
          'on the text hook page). An existing file is only replaced with '
          'overwrite.',
      risk: OpRisk.irreversible,
      availability: available,
      params: const <OpParam>[
        OpParam.string(
          'path',
          description: 'Absolute output .tsv path.',
          required: true,
        ),
        OpParam.userGate(
          'overwrite',
          description: 'User agreed to replace the existing file.',
        ),
      ],
    ),
    OpDescription(
      id: 'game.hook-codes.import',
      method: 'POST',
      pattern: '$kGameHookCodeCtlRoot/import',
      summary:
          'Replace the saved hook codes with a .tsv file (like "Import hook '
          'codes"; not merged). Undo restores the previous list.',
      risk: OpRisk.write,
      availability: available,
      params: const <OpParam>[
        OpParam.string(
          'path',
          description: 'Absolute .tsv path.',
          required: true,
        ),
      ],
      undo: opCustomUndo(
        capture: (CtlCall call) async {
          final LunaHookCodeProfileStore store = await deps.store();
          return <String, Object?>{
            'before': await store.file.readAsString(encoding: utf8),
          };
        },
        payloadOf:
            (CtlCall call, Map<String, Object?> before, Object? result) =>
                <String, Object?>{
                  ...before,
                  if (result is Map) 'revision': result['revision'],
                  if (result is Map) 'path': result['path'],
                },
        describe: (Map<String, Object?> p) => 'hook codes from ${p['path']}',
        revert: (Map<String, Object?> payload) async {
          final LunaHookCodeProfileStore store = await deps.store();
          if (await hookCodeStoreRevision(store) != payload['revision']) {
            return const OpUndoOutcome.superseded('导入之后 Hook Code 配置又被改过，没有覆盖');
          }
          final Object? before = payload['before'];
          if (before is! String) {
            return const OpUndoOutcome.failed('撤销载荷里没有导入前的配置');
          }
          await store.save(parseLunaHookCodeProfiles(before));
          return const OpUndoOutcome.done();
        },
      ),
    ),
  ];
}
