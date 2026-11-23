import 'package:fushi_cli/fushi_cli.dart';

import 'package:fushi/src/ops/ctl_leaderboard_routes.dart';
import 'package:fushi/src/ops/op_describe_kit.dart';

/// 排行榜账户的操作描述；路由见 `ctl_leaderboard_routes.dart`。
///
/// 导入恢复码 irreversible：换掉本机账户钥匙（原来的账户没有恢复码就找不回），且只收
/// 用户本人经 CLI 标准输入给的恢复码——模型调用路由直接拒绝。
List<OpDescription> describeLeaderboardOps(OpDescribeKit kit) =>
    const <OpDescription>[
      OpDescription(
        id: 'leaderboard.status',
        method: 'GET',
        pattern: kLeaderboardCtlRoot,
        summary:
            'Leaderboard account on this profile: signed in or not, nickname, '
            'visibility, whether shelf upload is consented.',
      ),
      OpDescription(
        id: 'leaderboard.recovery-import',
        method: 'POST',
        pattern: '$kLeaderboardCtlRoot/recovery-code',
        summary:
            'Sign in to the leaderboard on this device with a recovery code '
            '(like "Import recovery code"). User only: the code holds the '
            'account private key, so the assistant cannot call this.',
        risk: OpRisk.irreversible,
        params: <OpParam>[
          OpParam.string(
            'code',
            description: 'Recovery code (entered by the user via stdin).',
            required: true,
          ),
          OpParam.boolean(
            'consent',
            description: 'User agreed to public shelf upload.',
          ),
        ],
      ),
    ];
