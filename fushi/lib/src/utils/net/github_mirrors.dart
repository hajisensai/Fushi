import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

/// GitHub **直链下载**（raw / release 资产）的公共加速镜像前缀，全仓唯一真相源。
///
/// 谁在用：更新检查/下载（`update_checker_net.dart` 的 `updateCheckProxyPrefixes`
/// 直接等于本常量）、Mihon 扩展仓库索引 / 扩展列表 / APK 拉取
/// （`mihon_extension_store_client.dart`，BUG-1875）。app 运行时**不走**本机命令行
/// 代理，GFW 机器直连 `github.com` 会吃满连接超时，全靠这些镜像兜底。
///
/// 这些公共镜像会不定期轮换/下线（`mirror.ghproxy.com`、`ghproxy.homeboyc.cn` 均因
/// DNS 不再解析被移除，TODO-666），具体哪个通取决于用户机器与时段，故多备几个
/// （BUG-277：单点不可达不该让整轮失败）。
///
/// **只对直链有效（BUG-292 实测）**：它们只代理 `raw.githubusercontent.com` /
/// release 资源下载，对 `api.github.com` JSON API 一律 403 或直接 TLS 失败。凡命中
/// API 的请求别指望镜像能救；[isGitHubDownloadHost] 有意不把 `api.github.com` 算进去。
const List<String> kGitHubMirrorPrefixes = <String>[
  'https://ghfast.top/',
  'https://gh-proxy.com/',
  'https://ghproxy.net/',
  'https://ghproxy.cc/',
  'https://gh.llkk.cc/',
];

/// 镜像能代理的 GitHub 下载域。`github.com/<o>/<r>/raw/<ref>/<p>` 会 302 到
/// `raw.githubusercontent.com`，release 资产会 302 到 `objects.githubusercontent.com`
/// / `release-assets.githubusercontent.com`，`codeload.github.com` 是源码归档直链。
/// 不含 `api.github.com`（镜像对它必 403，见 [kGitHubMirrorPrefixes]）。
const Set<String> _kGitHubDownloadHosts = <String>{
  'github.com',
  'raw.githubusercontent.com',
  'objects.githubusercontent.com',
  'release-assets.githubusercontent.com',
  'codeload.github.com',
};

/// [url] 的 host 是否是镜像能代理的 GitHub 下载域（精确匹配、大小写不敏感）。
bool isGitHubDownloadHost(Uri url) =>
    _kGitHubDownloadHosts.contains(url.host.toLowerCase());

/// **纯函数**：为 [url] 生成按优先级排序的候选列表。
///
/// 非 GitHub 下载域 → 只有 [url] 自己。GitHub 下载域 → 直连 [url] 首位（有 VPN /
/// 系统代理时最快、最权威），其后每个 [kGitHubMirrorPrefixes] 套在 [url] 前。直连只
/// 出现一次、候选无重复。
List<Uri> gitHubMirrorCandidates(Uri url) {
  if (!isGitHubDownloadHost(url)) return <Uri>[url];
  final String direct = url.toString();
  return <Uri>{
    url,
    for (final String prefix in kGitHubMirrorPrefixes)
      Uri.parse('$prefix$direct'),
  }.toList(growable: false);
}

/// [error] 是否是「这一跳根本没送到 / 没拿到响应」的传输层失败——只有这种失败才
/// 值得换下一个镜像候选重来。
///
/// - `SocketException`（连接超时 / 拒绝 / DNS 失败）、`TimeoutException`（我们自己的
///   整体超时）、`HandshakeException` / `TlsException`（TLS 失败）→ true。
/// - `http.ClientException`：`package:http` 的 `IOClient` 把底层 socket / HTTP 协议
///   错误包成它（其 `_ClientSocketException` 同时 implements `SocketException`）→ true。
/// - 其它——服务端**已经答复**的 HTTP 状态错误、格式错误、业务异常——→ false：换镜像
///   拿到的仍是同一份 404 / 同一份坏数据，回退只会掩盖真正原因。
bool isTransportFailure(Object error) =>
    error is SocketException ||
    error is TimeoutException ||
    error is HandshakeException ||
    error is TlsException ||
    error is http.ClientException;
