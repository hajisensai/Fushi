/// 排行榜账户的操作声明（拍板台 PGpPujl99g / BUG-5123）。实现在 app
/// `fushi/lib/src/ops/ctl_leaderboard_routes.dart`，CLI 命令在
/// `commands/leaderboard_commands.dart`，都引用这里的同一个对象。
///
/// 导入恢复码 irreversible：换掉本机账户钥匙（原来的账户没有恢复码就找不回），且只收
/// 用户本人经 CLI 标准输入给的恢复码——模型调用由实现直接拒绝。
library;

import '../fushi_op.dart';
import '../op_spec.dart';

abstract final class LeaderboardOps {
  /// 路由根。
  static const String root = '/api/admin/leaderboard';

  static const OpSpec status = OpSpec(
    id: 'leaderboard.status',
    method: 'GET',
    pattern: root,
    summary:
        'Leaderboard account on this profile: signed in or not, nickname, '
        'visibility, whether shelf upload is consented.',
  );

  static const OpParam recoveryCode = OpParam.string(
    'code',
    description: 'Recovery code (entered by the user via stdin).',
    required: true,
  );

  static const OpParam recoveryConsent = OpParam.boolean(
    'consent',
    description: 'User agreed to public shelf upload.',
  );

  static const OpSpec recoveryImport = OpSpec(
    id: 'leaderboard.recovery-import',
    method: 'POST',
    pattern: '$root/recovery-code',
    summary:
        'Sign in to the leaderboard on this device with a recovery code '
        '(like "Import recovery code"). User only: the code holds the '
        'account private key, so the assistant cannot call this.',
    risk: OpRisk.irreversible,
    params: <OpParam>[recoveryCode, recoveryConsent],
  );
}
