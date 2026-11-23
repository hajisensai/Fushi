import 'package:fushi_cli/fushi_cli.dart';

import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/ops/ctl_srs_mined_import_routes.dart';
import 'package:fushi/src/ops/ctl_srs_routes.dart';
import 'package:fushi/src/ops/op_describe_kit.dart';

/// 「从制卡历史导入」的操作描述；路由见 `ctl_srs_mined_import_routes.dart`。
///
/// irreversible：一次建出几百上千条笔记，导入后马上就能复习、产生复习记录，按 guid
/// 删回去会连复习记录一起删掉；界面同样先确认。重复导入按内容 guid 去重，不会重复建卡。
List<OpDescription> describeSrsMinedImportOps(OpDescribeKit kit) {
  final SrsCtlDeps deps = srsCtlDeps(kit.context);
  return <OpDescription>[
    OpDescription(
      id: 'srs.import-mined',
      method: 'POST',
      pattern: kSrsMinedImportCtlPath,
      summary:
          'Turn the card-mining history (every sentence ever mined) into review '
          'notes in the current profile\'s default deck (like "Import from '
          'mining history"). Already imported records are skipped.',
      risk: OpRisk.irreversible,
      availability: () => deps.moduleEnabled()
          ? const OpAvailability.available()
          : OpAvailability.unavailable('module_disabled', ModuleId.srs.name),
      params: const <OpParam>[
        OpParam.userGate(
          'confirm',
          description: 'User confirmed importing the whole mining history.',
        ),
      ],
    ),
  ];
}
