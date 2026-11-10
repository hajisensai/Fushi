import 'package:fushi_engine/media/discovery/download_gateway_challenge.dart';

/// 下载队列（引擎层，没有 `BuildContext`）与下载网关验证页的接线点（BUG-4323）。
///
/// app 根 navigator 就绪后 `installDownloadGatewayChallengeSolver` 装一次；没装
/// （测试 / 无 UI）时 [solve] 返回 null，挑战按「需要人机验证」失败上浮，而不是
/// 静默当成解完。单独成文件：组装点（`AppModel`）只依赖这个闸口，不 import WebView 页。
abstract final class DownloadGatewayChallengeGate {
  static DownloadGatewayChallengeSolver? solver;

  static Future<DownloadGatewayClearance?> solve(Uri challengeUrl) async {
    final DownloadGatewayChallengeSolver? installed = solver;
    if (installed == null) return null;
    return installed(challengeUrl);
  }
}
