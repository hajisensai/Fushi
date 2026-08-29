import 'package:url_launcher/url_launcher.dart';

/// 官网地址。应用里所有「打开官网」的入口（宽屏侧栏左上角的 app 图标、设置 ·
/// 通用 · 官网）都从这里取值，URL 只存在一处。
///
/// 更新链路另有自己的常量（`update_checker_net.dart` 的官方镜像 host）：那边要的是
/// 版本化的 R2 下载路径，不是站点首页，两者刻意不共用一个字符串。
const String kOfficialWebsiteUrl = 'https://fushi.moe';

/// 在系统浏览器里打开官网。
Future<bool> openOfficialWebsite() {
  return launchUrl(
    Uri.parse(kOfficialWebsiteUrl),
    mode: LaunchMode.externalApplication,
  );
}
