import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hibiki/utils.dart';

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
  final bool? accepted = await showAppDialog<bool>(
    context: context,
    builder: (BuildContext dialogContext) => AlertDialog(
      title: Text(t.manga_google_lens_disclosure_title),
      content: Text(t.manga_google_lens_disclosure_body),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: Text(t.manga_google_lens_disclosure_decline),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: Text(t.manga_google_lens_disclosure_accept),
        ),
      ],
    ),
  );
  if (accepted != true) {
    return false;
  }
  await preferences.setInt(
    kGoogleLensDisclosurePreferenceKey,
    kGoogleLensDisclosureVersion,
  );
  return true;
}
