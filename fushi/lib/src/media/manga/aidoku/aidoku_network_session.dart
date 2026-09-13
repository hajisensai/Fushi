import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:fushi/src/media/manga/cookie/manga_cookie_jar.dart';
import 'package:fushi/src/storage/app_paths.dart';

export 'package:fushi/src/media/manga/cookie/manga_cookie_jar.dart'
    show MangaCookie, kCloudflareClearanceCookie;

/// 单一浏览器身份：Aidoku wasm host（Rust reqwest）、解 Cloudflare 挑战的 WebView、
/// 阅读器图片下载三方**必须字节一致**——Cloudflare 把 `cf_clearance` 绑定到解题时的
/// User-Agent，任何一方不同就等于没拿到 cookie（BUG-1876）。
const String kAidokuUserAgent =
    'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) '
    'AppleWebKit/605.1.15 (KHTML, like Gecko) '
    'Version/18.0 Mobile/15E148 Safari/604.1';

/// 解题回调：把 [challengeUrl] 交给 UI 层在 WebView 里完成验证，返回是否拿到了放行
/// cookie（已写入 jar）。`false` = 用户取消或超时，调用方按原错误上报。
///
/// [userAgent] 是**被挑战那次请求实际用的 UA**（源可能自设，覆盖默认身份）；
/// 解题 WebView 必须用同一 UA，否则 `cf_clearance` 绑错身份、重试永远失败
/// （上游 Mihon 同样按请求自己的 UA 解题）。
typedef AidokuCloudflareResolver =
    Future<bool> Function(Uri challengeUrl, String userAgent);

/// 运行时与 UI 层的接线点：UI 启动时装一个 resolver，runtime 遇到
/// `CLOUDFLARE_CHALLENGE` 时调用它。没装（测试 / 无 UI）就退化成直接报错。
abstract final class AidokuCloudflareGate {
  static AidokuCloudflareResolver? resolver;

  static const Object _suppressKey = #aidokuCloudflareSuppressed;

  /// 当前异步链是否禁止弹解题页。后台批量流（全局搜索扇出、发现页自动匹配）
  /// 里被 Cloudflare 拦下不该无操作弹全屏 WebView——让错误按
  /// `CLOUDFLARE_CHALLENGE` 码上浮，由调用方标成徽标/状态，用户点进源页
  /// 再交互解题。
  static bool get suppressed => Zone.current[_suppressKey] == true;

  /// 在抑制解题页的 Zone 里跑 [body]；Zone 值随整条异步链继承，包括受限并发
  /// 扇出的每个 worker。
  static Future<T> runSuppressed<T>(Future<T> Function() body) =>
      runZoned<Future<T>>(
        body,
        zoneValues: <Object?, Object?>{_suppressKey: true},
      );
}

/// 一条按域名作用的 cookie（对齐 Rust 侧 `NetworkCookie`）。
///
/// 与 Mihon 桌面 sidecar 共用同一份实现：两边的需求逐字相同（宿主持有真值、
/// 按 RFC 6265 域匹配、会话 cookie 无过期时刻），分成两份只会让匹配规则悄悄
/// 漂移。别名保留是为了让 Aidoku 侧的调用点与测试一个字都不用改。
typedef AidokuCookie = MangaCookie;

/// 文件持久化的 cookie jar，Aidoku 源专用（与 WebView 自己的 cookie 存储分离：
/// WKHTTPCookieStore 只有 WebView 能读，wasm host 在 Rust 里发请求读不到它，
/// 所以解题后要**复制**一份出来，随每次 invoke 送进 host）。
///
/// 存储/匹配/持久化全部落在共用的 [MangaCookieJar]；这里只留 Aidoku 独有的两
/// 件事：共享实例的落盘路径，以及送进 Rust host 的 `network` payload 形状。
///
/// 只存 Aidoku 源站的 cookie，设备本地、不进同步/备份。
class AidokuCookieJar extends MangaCookieJar {
  AidokuCookieJar(super.file, {super.clock});

  /// 路径延迟解析（共享实例：支持目录要等平台通道就绪）。
  AidokuCookieJar.lazy(super.resolveFile, {super.clock}) : super.lazy();

  /// 进程级共享实例，落在 Aidoku 扩展目录旁的 `cookies.json`。
  static AidokuCookieJar get shared =>
      _shared ??= AidokuCookieJar.lazy(_sharedFile);
  static AidokuCookieJar? _shared;

  /// 测试替换共享实例。
  static set shared(AidokuCookieJar? value) => _shared = value;

  static Future<File> _sharedFile() async {
    final Directory supportRoot = await AppPaths.supportRootDirectory();
    return File(
      p.join(supportRoot.path, 'manga_extensions', 'aidoku', 'cookies.json'),
    );
  }

  /// 随每次 runtime invoke 送进 Rust host 的 `network` 字段。整个 jar 一起送：
  /// host 端自己按域匹配，而且一次调用里源会跨 api / cdn 子域发多个请求。
  Map<String, Object?> networkPayload() {
    final int now = nowMs;
    return <String, Object?>{
      'userAgent': kAidokuUserAgent,
      'cookies': <Object?>[
        for (final AidokuCookie cookie in cookies)
          if (!cookie.isExpiredAt(now)) cookie.toJson(),
      ],
    };
  }
}
