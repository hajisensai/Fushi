import 'package:fushi_platform/fushi_platform.dart';

/// Generic, brand-only device label used when no meaningful hardware name is
/// available. Better than advertising "localhost".
const String kGenericInterconnectDeviceName = 'Hibiki';

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
