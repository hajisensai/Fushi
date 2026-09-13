import 'package:fushi/src/media/manga/cookie/manga_cookie_jar.dart';

/// 在浏览器里解 Cloudflare 挑战并把整站 cookie 写进 [jar]；返回 true 表示拿到了
/// 新的 `cf_clearance`，false 表示用户关掉了页面或 navigator 还没就绪。
typedef MihonCloudflareResolver =
    Future<bool> Function(
      Uri challengeUrl,
      String userAgent,
      MangaCookieJar jar,
    );

/// 桌面 Mihon 运行时与 UI 层的接线点。
///
/// 运行时层没有 `BuildContext`，而解题必须弹一页真实 WebView，所以 UI 启动时装一个
/// resolver 进来（`installMihonCloudflareResolver`），`DesktopMihonRuntime.solveCloudflare`
/// 只管调用。没装（测试 / 无 UI）时运行时按 `CHALLENGE_UNAVAILABLE` 报错，而不是
/// 静默当作解完。
///
/// 与 Aidoku 那套的差别只有一点：Mihon 的解题**总是用户点按钮触发**
/// （`MihonCloudflareAction`），运行时自己不会在后台流里弹页，所以这里不需要
/// `runSuppressed` 那层 Zone 抑制。
abstract final class MihonCloudflareGate {
  static MihonCloudflareResolver? resolver;
}
