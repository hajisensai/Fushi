import 'package:fushi_platform/fushi_platform.dart';

/// Generic, brand-only device label used when no meaningful hardware name is
/// available. Better than advertising "localhost".
///
/// 改名 Fushi 后本设备对外播报的品牌词。这是**运行期播报值**，不是持久化键，
/// 改它不破坏任何存量数据。
///
/// 注意存量已配对记录不会自动变：`fushi_paired_peers.device_name` 只在配对成功
/// 那一刻由 `FushiServerController._persistPairedPeer` 写入对方当时自报的字符串，
/// 之后没有任何刷新路径。所以对端升到 Fushi 之前（或升级后未重新配对前），host
/// 的已配对设备列表里仍会显示 `Hibiki · <model>` —— 那是配对当时的真实自报值，
/// 不是本常量的残留。
const String kGenericInterconnectDeviceName = 'Fushi';

/// Values that are never a meaningful, human-facing device name.
///
/// Android's `Platform.localHostname` is the constant "localhost" — the OS does
/// not expose a real hostname to apps — and loopback literals identify the
/// connection endpoint, not the device. A device that would advertise one of
/// these gets [kGenericInterconnectDeviceName] instead, so an interconnect peer
/// never sees "localhost" as another device's name in its paired-devices list
/// (TODO-1356).
bool isMeaninglessDeviceName(String value) {
  final String v = value.trim().toLowerCase();
  return v.isEmpty ||
      v == 'localhost' ||
      v == '127.0.0.1' ||
      v == '::1' ||
      v == '0.0.0.0';
}

/// The name this device advertises to interconnect peers — both when pairing as
/// a client (`/api/pair`, `/api/pair/v2`) and when hosting (`/api/ping` + the
/// LAN broadcast). It is sourced from [PlatformDeviceInfoService.deviceModel]
/// (the real hardware model on Android/iOS, the machine hostname on desktop)
/// rather than `Platform.localHostname` directly, which is the useless constant
/// "localhost" on Android and would otherwise be stored verbatim as the peer's
/// device name (TODO-1356). Never resolves to a "localhost"/loopback name.
Future<String> resolveInterconnectDeviceName(
  PlatformDeviceInfoService deviceInfo,
) async {
  try {
    final String? model = (await deviceInfo.deviceModel)?.trim();
    if (model != null && !isMeaninglessDeviceName(model)) {
      return '$kGenericInterconnectDeviceName · $model';
    }
  } catch (_) {
    // device_info_plus / Platform.localHostname can throw on some platforms;
    // fall back to the generic label rather than crashing pairing.
  }
  return kGenericInterconnectDeviceName;
}
