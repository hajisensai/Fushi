import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:fushi/src/utils/misc/channel_constants.dart';

/// 「不能应用内安装时，前往哪里拿更新」的落地入口种类。
///
/// 这不是装饰性的枚举：它同时决定按钮文案（去 TestFlight 还是去 App Store 还是
/// 打开发布页）和是否需要额外给出「发布页」次要入口，见
/// `update_checker_release.dart` 的 `_showFallbackDialog`。
enum UpdateLandingKind { releasePage, testFlight, appStore }

/// 「前往下载」按钮真正要打开的东西：URL + 它是什么种类。
@immutable
class UpdateLanding {
  const UpdateLanding({required this.url, required this.kind});

  final String url;
  final UpdateLandingKind kind;

  @override
  bool operator ==(Object other) =>
      other is UpdateLanding && other.url == url && other.kind == kind;

  @override
  int get hashCode => Object.hash(url, kind);

  @override
  String toString() => 'UpdateLanding($kind, $url)';
}

/// 这份 iOS app 是**从哪条渠道装到这台设备上的**。
///
/// 根因背景：iOS 同一个版本有三条互不相干的分发链路——App Store（将来）、
/// TestFlight（`upload_testflight` 的 beta / formal 构建，见
/// `docs/agent/apple-signing.md`）、以及 GitHub Release 里那个**未签名**的
/// `fushi-<v>-ios.ipa`（AltStore / Sideloadly 自签侧载）。「该去哪儿更新」的答案
/// 完全由「我是从哪儿来的」决定，跟更新通道（stable/beta/debug）无关：TestFlight
/// 装的包永远只能从 TestFlight 更新，侧载的包永远只能重新侧载。
///
/// 判据用 App Store 收据文件，这是系统写的事实、不是猜测：
/// - App Store 安装 → `.../receipt`
/// - TestFlight 安装 → `.../sandboxReceipt`
/// - 侧载 / 自签 / 开发构建 → 收据文件**根本不存在**（路径有、文件没有）
enum IosInstallSource { appStore, testFlight, sideload }

/// TestFlight 公开加入链接（形如 `https://testflight.apple.com/join/<code>`）。
///
/// 留空是**有意的默认**：本 app 的 TestFlight 用户机器上必然装着 TestFlight，
/// [kIosTestFlightAppUrl] 直接把它拉起来就够了，不需要公开招募链接。等对外公开
/// 招募时把链接填在这里，落地入口自动切过去（[iosUpdateLanding] 优先用它）。
const String kIosTestFlightJoinUrl = '';

/// TestFlight app 的 URL scheme。裸 scheme 即「打开 TestFlight」，用户在里面能看到
/// 本 app 的待更新构建。需要在 `ios/Runner/Info.plist` 的
/// `LSApplicationQueriesSchemes` 里登记，否则 url_launcher 的可用性探测会误判。
const String kIosTestFlightAppUrl = 'itms-beta://';

/// App Store 上架后本 app 的数字 ID（App Store Connect 里的 Apple ID，纯数字）。
///
/// **上架前必然为空**——App Store 记录还没发布，任何 `id` 都是死链。为空时
/// [iosUpdateLanding] 对 App Store 安装源回退到发布页（能打开的真链接），而不是
/// 造一个 404。上架当天把 ID 填进来即完成切换，不需要改逻辑。
const String kIosAppStoreAppId = '';

/// App Store 商店页 URL；未配置 [kIosAppStoreAppId] 时返回 null。
///
/// 用 `itms-apps://` 而不是 `https://`：前者直接拉起 App Store app 落到本 app 页，
/// 后者会先开 Safari 再跳一次。
String? iosAppStoreUrl() {
  if (kIosAppStoreAppId.isEmpty) return null;
  return 'itms-apps://apps.apple.com/app/id$kIosAppStoreAppId';
}

/// TestFlight 落地 URL：有公开加入链接优先用它，否则拉起本机 TestFlight app。
String iosTestFlightUrl() => kIosTestFlightJoinUrl.isNotEmpty
    ? kIosTestFlightJoinUrl
    : kIosTestFlightAppUrl;

/// **纯函数**：iOS 上「前往下载」该落到哪里。
///
/// [releaseHtmlUrl] 是 GitHub release 网页（侧载用户的真实取包处，也是任何配置缺失
/// 时的兜底——它永远是个能打开的活链接）。
UpdateLanding iosUpdateLanding({
  required IosInstallSource source,
  required String releaseHtmlUrl,
}) {
  switch (source) {
    case IosInstallSource.appStore:
      final String? storeUrl = iosAppStoreUrl();
      if (storeUrl == null) {
        // 上架前 ID 未配置：宁可回发布页（活链接），也不给死的 `id` 链接。
        return UpdateLanding(
          url: releaseHtmlUrl,
          kind: UpdateLandingKind.releasePage,
        );
      }
      return UpdateLanding(url: storeUrl, kind: UpdateLandingKind.appStore);
    case IosInstallSource.testFlight:
      return UpdateLanding(
        url: iosTestFlightUrl(),
        kind: UpdateLandingKind.testFlight,
      );
    case IosInstallSource.sideload:
      return UpdateLanding(
        url: releaseHtmlUrl,
        kind: UpdateLandingKind.releasePage,
      );
  }
}

/// **纯函数**：把 native 回来的字符串映射成 [IosInstallSource]。
///
/// 认不出（null / 新值 / 通道异常）→ [IosInstallSource.sideload]，即保持改动前的
/// 「打开 GitHub 发布页」行为。fail-safe 方向选发布页而不是 TestFlight：发布页对
/// 任何一种 iOS 用户都至少是可读的信息，而 TestFlight 对侧载用户是死路。
IosInstallSource parseIosInstallSource(String? raw) {
  switch (raw) {
    case 'appStore':
      return IosInstallSource.appStore;
    case 'testFlight':
      return IosInstallSource.testFlight;
    default:
      return IosInstallSource.sideload;
  }
}

/// 运行期查询安装来源（结果进程内缓存——收据在 app 生命周期内不会变）。
///
/// 非 iOS 平台不该调用；真调了也返回 [IosInstallSource.sideload]（= 发布页，
/// 即桌面/安卓原有行为），不炸。
class IosInstallSourceResolver {
  IosInstallSourceResolver._();

  static IosInstallSource? _cached;

  static Future<IosInstallSource> resolve() async {
    final IosInstallSource? cached = _cached;
    if (cached != null) return cached;
    if (!Platform.isIOS) return IosInstallSource.sideload;
    IosInstallSource resolved;
    try {
      final String? raw =
          await FushiChannels.update.invokeMethod<String>('getInstallSource');
      resolved = parseIosInstallSource(raw);
    } catch (e) {
      // 通道缺失（老 native / 测试环境）→ 保持旧行为走发布页，不阻断更新提示。
      debugPrint('[UpdateChecker] iOS install source lookup failed: $e');
      resolved = IosInstallSource.sideload;
    }
    _cached = resolved;
    return resolved;
  }

  @visibleForTesting
  static void setForTest(IosInstallSource? source) => _cached = source;
}
