import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_engine/leaderboard/leaderboard_client.dart'
    show LeaderboardApiException;
import 'package:fushi_engine/leaderboard/leaderboard_models.dart'
    show LeaderboardSelf;

import 'package:fushi/src/leaderboard/leaderboard_service.dart';
import 'package:fushi/src/ops/op_context.dart';

/// 排行榜账户的控制通道路由（拍板台 PGpPujl99g / BUG-5123）：账户页「导入恢复码」背后的
/// [LeaderboardService.importRecoveryCode]（换设备的备用方式）。恢复码含账户私钥，是凭据：
/// 只收用户本人经 CLI 标准输入给的值（`fushi_cli leaderboard recovery-import`），模型
/// （AI 助手）调用一律拒绝——与设置里的凭据参数同一条线（spec §10：AI 不写凭据）。
List<CtlRoute> buildLeaderboardCtlRoutes(OpContext context) =>
    buildLeaderboardCtlRoutesFor(
      () => context.ref.read(leaderboardServiceProvider),
    );

/// 路由根。
const String kLeaderboardCtlRoot = '/api/admin/leaderboard';

/// 路由表本体：服务按回调注入（测试给假件）。
List<CtlRoute> buildLeaderboardCtlRoutesFor(
  LeaderboardService Function() service,
) => <CtlRoute>[
  CtlRoute.get(kLeaderboardCtlRoot, (CtlCall call) async {
    final LeaderboardService s = service();
    await s.load();
    return <String, Object?>{
      'status': s.status.name,
      if (s.self case final LeaderboardSelf self) ...<String, Object?>{
        'nickname': self.account.nickname,
        'visibility': self.visibility,
      },
      'uploadConsent': s.hasConsent,
    };
  }),
  CtlRoute.post('$kLeaderboardCtlRoot/recovery-code', (CtlCall call) async {
    if (call.fromModel) {
      throw const CtlFailure.rejected('恢复码含账户私钥，只能由用户本人经 fushi_cli 输入，AI 不经手');
    }
    final String code = call.requireString('code');
    final LeaderboardService s = service();
    try {
      await s.importRecoveryCode(
        code,
        consent: call.optBool('consent') ?? false,
      );
    } on FormatException {
      throw const CtlFailure.badRequest('恢复码格式不对');
    } on LeaderboardApiException catch (e) {
      throw CtlFailure(
        e.status == 401 || e.status == 404 ? 422 : 502,
        'leaderboard_${e.code}',
        '排行榜服务拒绝了这个恢复码：${e.code}',
      );
    }
    return <String, Object?>{
      'status': s.status.name,
      'uploadConsent': s.hasConsent,
    };
  }),
];
