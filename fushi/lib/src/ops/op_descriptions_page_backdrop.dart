import 'package:fushi_cli/fushi_cli.dart';

import 'package:fushi/src/ops/ctl_page_backdrop_routes.dart';
import 'package:fushi/src/ops/op_describe_kit.dart';

/// 页面背景图导入的操作描述；路由见 `ctl_page_backdrop_routes.dart`。
///
/// irreversible：换图时旧图（app 数据目录里的那份副本）随即删除，写不回。
List<OpDescription> describePageBackdropOps(
  OpDescribeKit kit,
) => <OpDescription>[
  OpDescription(
    id: 'appearance.page-backdrop.image',
    method: 'POST',
    pattern: kPageBackdropImageCtlPath,
    summary:
        'Use an image as the page background (copied into app data; the '
        'landscape image also switches the preset to "Custom image"). With '
        'module: only that main tab. With page: only that page inside a tab '
        '(it otherwise inherits its tab). With portrait: the image used in '
        'portrait orientation.',
    risk: OpRisk.irreversible,
    params: <OpParam>[
      const OpParam.string(
        'path',
        description: 'Absolute image path (jpg / png / webp / gif / bmp).',
        required: true,
      ),
      const OpParam.boolean(
        'portrait',
        description: 'Set the portrait-only image.',
      ),
      OpParam.string(
        'module',
        description: 'Main tab to set its own background for.',
        enumValues: pageBackdropModuleWires,
      ),
      OpParam.string(
        'page',
        description:
            'Page inside a main tab to set its own background for '
            '(srs_review = the review screen). Not with module.',
        enumValues: pageBackdropPageWires,
      ),
    ],
  ),
];
