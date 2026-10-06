import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fushi/utils.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

const int kGoogleLensDisclosureVersion = 1;
const String kGoogleLensDisclosurePreferenceKey =
    'manga_google_lens_disclosure_version';

typedef GoogleLensDisclosureGate = Future<bool> Function(BuildContext context);

/// Device-local, versioned privacy gate for full-page Google Lens OCR.
///
/// SharedPreferences is intentional: Drift preferences participate in profile
/// snapshots and backup/sync, while consent must be collected independently on
/// every device that uploads page images.
Future<bool> ensureGoogleLensDisclosure(BuildContext context) async {
  final SharedPreferences preferences = await SharedPreferences.getInstance();
  if (preferences.getInt(kGoogleLensDisclosurePreferenceKey) ==
      kGoogleLensDisclosureVersion) {
    return true;
  }
  if (!context.mounted) {
    return false;
  }
  final bool accepted = await showFushiConfirmDialog(
    context: context,
    title: t.manga_google_lens_disclosure_title,
    message: t.manga_google_lens_disclosure_body,
    icon: FushiIcons.cloudUpload,
    cancelLabel: t.manga_google_lens_disclosure_decline,
    confirmLabel: t.manga_google_lens_disclosure_accept,
  );
  if (!accepted) {
    return false;
  }
  await preferences.setInt(
    kGoogleLensDisclosurePreferenceKey,
    kGoogleLensDisclosureVersion,
  );
  return true;
}
