import 'package:flutter/material.dart';

import 'package:fushi/src/media/manga/aidoku/aidoku_cloudflare_challenge_page.dart';
import 'package:fushi/src/media/manga/cookie/manga_cookie_jar.dart';
import 'package:fushi/src/media/manga/mihon/mihon_cloudflare_gate.dart';

/// 把「在 WebView 里解 Cloudflare 挑战」装成 [MihonCloudflareGate.resolver]。
/// 在 app 根 navigator 就绪后调用一次；桌面 Mihon 运行时的 `solveCloudflare`
/// 会推一页 [AidokuCloudflareChallengePage]，拿到 `cf_clearance` 后自动关闭。
///
/// 页面本体与 Aidoku 共用：两边的需求逐字相同（同 UA 打开被拦 URL、轮询到
/// 一个值不同于 jar 现存条目的 `cf_clearance`、整站回存），分成两页只会让完成
/// 判据悄悄漂移。
///
/// 按 host 单飞：同站的并发解题共享同一次，后到的等第一次的结果。顺序是硬要求
/// ——**先建 future → 再写 map → 最后挂清理**；`map[k] ??= asyncFn()` 会在
/// navigator 未就绪的同步早退路径上把已完成的 `Future(false)` 钉死进 map。
void installMihonCloudflareResolver(
  GlobalKey<NavigatorState> navigatorKey, {
  @visibleForTesting
  Widget Function(Uri challengeUrl, String userAgent, MangaCookieJar jar)?
  pageBuilder,
}) {
  final Map<String, Future<bool>> inflight = <String, Future<bool>>{};
  MihonCloudflareGate.resolver =
      (Uri challengeUrl, String userAgent, MangaCookieJar jar) {
        final String host = challengeUrl.host;
        final Future<bool>? pending = inflight[host];
        if (pending != null) return pending;
        final Future<bool> solving = _solveChallenge(
          navigatorKey,
          challengeUrl,
          userAgent,
          jar,
          pageBuilder,
        );
        inflight[host] = solving;
        return solving.whenComplete(() => inflight.remove(host));
      };
}

Future<bool> _solveChallenge(
  GlobalKey<NavigatorState> navigatorKey,
  Uri challengeUrl,
  String userAgent,
  MangaCookieJar jar,
  Widget Function(Uri challengeUrl, String userAgent, MangaCookieJar jar)?
  pageBuilder,
) async {
  final NavigatorState? navigator = navigatorKey.currentState;
  if (navigator == null) return false;
  final bool? solved = await navigator.push<bool>(
    MaterialPageRoute<bool>(
      builder: (BuildContext context) =>
          pageBuilder?.call(challengeUrl, userAgent, jar) ??
          AidokuCloudflareChallengePage(
            challengeUrl: challengeUrl,
            userAgent: userAgent,
            jar: jar,
          ),
      fullscreenDialog: true,
    ),
  );
  return solved ?? false;
}
