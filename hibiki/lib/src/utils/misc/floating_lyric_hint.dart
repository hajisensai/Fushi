import 'package:hibiki/i18n/strings.g.dart';

/// TODO-1227: ColorOS-based OEMs whose risk control ("permission monitoring")
/// can silently refuse the "draw over other apps" permission in system
/// settings. Matched against Android `Build.MANUFACTURER`, case-insensitive.
const Set<String> kColorOsManufacturers = <String>{
  'oppo',
  'realme',
  'oneplus',
};

/// Whether [manufacturer] (Android `Build.MANUFACTURER`) belongs to a
/// ColorOS OEM ([kColorOsManufacturers]); case-insensitive, `null`-safe.
bool isColorOsManufacturer(String? manufacturer) {
  if (manufacturer == null) return false;
  return kColorOsManufacturers.contains(manufacturer.trim().toLowerCase());
}

/// Picks the user-facing hint when toggling the floating-lyric window fails.
///
/// - Non-Android: the strip is a runner-owned window with no OS permission,
///   so failure means window creation failed — generic unavailable hint.
/// - Android on ColorOS OEMs: the OS may refuse to grant the overlay
///   permission at all, so show the workaround guidance (TODO-1227).
/// - Other Android: plain "grant the overlay permission" hint.
String floatingLyricFailureHint({
  required bool isAndroid,
  required String? manufacturer,
}) {
  if (!isAndroid) return t.floating_lyric_unavailable_hint;
  return isColorOsManufacturer(manufacturer)
      ? t.floating_lyric_permission_hint_coloros
      : t.floating_lyric_permission_hint;
}
