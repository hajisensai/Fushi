import 'package:url_launcher/url_launcher.dart';

import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 官网地址。应用里所有「打开官网」的入口（宽屏侧栏左上角的 app 图标、设置 ·
/// 通用 · 官网）都从这里取值，URL 只存在一处。
///
/// 更新链路另有自己的常量（`update_checker_net.dart` 的官方镜像 host）：那边要的是
/// 版本化的 R2 下载路径，不是站点首页，两者刻意不共用一个字符串。
const String kOfficialWebsiteUrl = 'https://fushi.moe';

/// 官网下载页。除了 app 安装包，这一页还带**推荐包**那一节：分片直链
/// （IDM / aria2 直接喂）、整包镜像，以及「导入方式要选合并、不要选覆盖整库」
/// 的说明。新手引导里的「在官网下载」指向这里，而不是甩一条 9.5 GB 的裸直链
/// ——直链下完了，用户还是不知道下一步该干什么。
const String kOfficialDownloadPageUrl = '$kOfficialWebsiteUrl/download';

/// 在系统浏览器里打开官网下载页。打不开返回 false，**不抛**（理由同
/// [openOfficialWebsite]）。
Future<bool> openOfficialDownloadPage() async {
  try {
    return await launchUrl(
      Uri.parse(kOfficialDownloadPageUrl),
      mode: LaunchMode.externalApplication,
    );
  } on Object catch (error, stack) {
    ErrorLogService.instance.log('openOfficialDownloadPage', error, stack);
    return false;
  }
}

/// 在系统浏览器里打开官网。打不开返回 false，**不抛**。
///
/// 两个调用点一个 `await`、一个挂在 `onTap` 上（同步回调，接不住 future），
/// 所以异常必须在这里收口：`launchUrl` 在没有 handler 的环境（Linux 缺
/// xdg-open、企业策略禁外链）会 throw，漏出去就是一次未捕获异步异常 —— 用户
/// 点一下 logo 拿到的是红屏日志，而不是「没反应」。
Future<bool> openOfficialWebsite() async {
  try {
    return await launchUrl(
      Uri.parse(kOfficialWebsiteUrl),
      mode: LaunchMode.externalApplication,
    );
  } on Object catch (error, stack) {
    ErrorLogService.instance.log('openOfficialWebsite', error, stack);
    return false;
  }
}
