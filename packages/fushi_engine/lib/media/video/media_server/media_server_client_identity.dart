import 'package:fushi_platform/fushi_platform.dart';

import 'package:fushi_engine/sync/interconnect_device_name.dart'
    show isMeaninglessDeviceName;

/// 本应用在媒体服务器（Jellyfin / Emby 的 `MediaBrowser Client=`、Plex 的
/// `X-Plex-Product`）面前自报的产品名。改名 Fushi 前 Jellyfin / Emby 认证头写的是
/// 旧品牌 `Hibiki`（AL8qJr6yr-）。这是**运行期播报值**，不是持久化键：令牌按
/// DeviceId 归属，改它不会让已登录的服务器掉线。
const String kMediaServerClientProduct = 'Fushi';

/// 本机对媒体服务器的客户端身份：产品名 / 设备名 / 版本。服务器后台「设备」
/// 「活动」列表按它显示是谁在连，部分公益服还按 `Client` 做客户端白名单
/// （BUG-2848，那是服务器运营方的访问策略，本应用只报自己的真实名字）。
class MediaServerClientIdentity {
  const MediaServerClientIdentity({
    this.product = kMediaServerClientProduct,
    this.deviceName = kMediaServerClientProduct,
    this.version = '1.0',
  });

  final String product;

  /// 真实设备名（桌面 = 主机名，移动端 = 硬件型号，见 [resolveMediaServerClientIdentity]）；
  /// 拿不到有意义的名字时是产品名。
  final String deviceName;

  /// 应用版本（`PackageInfo.version`）。
  final String version;

  @override
  String toString() =>
      'MediaServerClientIdentity($product, $deviceName, $version)';
}

/// 进程级装配点：缺省是不带设备信息的产品名身份（测试 / CLI），主进程启动时
/// （`AppModel` 读完 PackageInfo 后）换成 [resolveMediaServerClientIdentity] 的结果。
MediaServerClientIdentity mediaServerClientIdentity =
    const MediaServerClientIdentity();

/// 把任意字符串收成能放进 HTTP 头、也能放进 `Key="value"` 引号里的值：只留可打印
/// ASCII（Dart `HttpHeaders` 遇到非 Latin-1 字符直接抛，中文主机名会让每个请求都
/// 失败），去掉 `"` 与 `\`、折叠空白；收完为空用 [fallback]。
String sanitizeMediaServerHeaderValue(String raw, {required String fallback}) {
  final String cleaned = raw
      .replaceAll(RegExp(r'[^\x20-\x7E]'), ' ')
      .replaceAll(RegExp(r'["\\]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return cleaned.isEmpty ? fallback : cleaned;
}

/// 按平台设备信息解出本机身份：设备名取 [PlatformDeviceInfoService.deviceModel]
/// （与互联播报同源：桌面是主机名，Android / iOS 是硬件型号；Android 的
/// `localhost` 这类无意义值回落产品名），版本取 [version]。
///
/// 设备信息插件在部分平台会抛：那只影响后台显示的设备名，回落产品名，不影响
/// 连接本身。
Future<MediaServerClientIdentity> resolveMediaServerClientIdentity(
  PlatformDeviceInfoService deviceInfo, {
  required String version,
}) async {
  String? model;
  try {
    model = (await deviceInfo.deviceModel)?.trim();
  } on Object {
    model = null;
  }
  final String device = model == null || isMeaninglessDeviceName(model)
      ? kMediaServerClientProduct
      : sanitizeMediaServerHeaderValue(
          model,
          fallback: kMediaServerClientProduct,
        );
  return MediaServerClientIdentity(
    deviceName: device,
    version: sanitizeMediaServerHeaderValue(version, fallback: '1.0'),
  );
}
