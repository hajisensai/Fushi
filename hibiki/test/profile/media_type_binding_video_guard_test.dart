import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-1063 / BUG-512 source-scan guard: the "media type bindings" settings
/// list (profile_management_page.dart) must include `video`, and the video
/// player must consume the `video` binding so the setting is not dead UI.
///
/// Root cause: video graduated from an experimental gate to a permanent home
/// tab, but the profile "Media Type Bindings" section hardcoded exactly four
/// rows (epub / srtbook / audiobook / lyrics) and never listed `video`. Users
/// therefore could not bind a profile to video playback, and the video page
/// never called `resolveProfileId(mediaType: 'video')`.
///
/// The binding store (`media_type_profiles` table via ProfileRepository) accepts
/// any String key, so no schema migration is needed — the fix is purely (1) add
/// the `video` binding row + `profile_media_video` i18n label, and (2) resolve &
/// apply the video binding when a video opens.
///
/// This scans the source instead of driving the settings widget (which needs the
/// full provider graph + DB) so the guard stays cheap and fails loudly if either
/// half regresses. Tests run with CWD = `hibiki/`.
void main() {
  final File bindingUi = File(
    'lib/src/pages/implementations/profile_management_page.dart',
  );
  final File videoPage = File(
    'lib/src/pages/implementations/video_hibiki_page.dart',
  );

  test('media-type binding UI lists video alongside the other media types', () {
    expect(bindingUi.existsSync(), isTrue,
        reason: 'TODO-1063 binding UI lives in this file');
    final String src = bindingUi.readAsStringSync();

    // All five bindable media-type keys must be present as binding rows.
    for (final String mediaType in <String>[
      'epub',
      'srtbook',
      'audiobook',
      'lyrics',
      'video',
    ]) {
      expect(
        src.contains('_buildMediaTypeRow(') && src.contains("'$mediaType'"),
        isTrue,
        reason:
            'binding row for "$mediaType" missing — video (TODO-1063) or a '
            'sibling type was dropped from the media-type binding list',
      );
    }

    // The video row must use the dedicated video label, not a placeholder.
    expect(
      src.contains('t.profile_media_video'),
      isTrue,
      reason: 'video binding row must use the profile_media_video i18n label',
    );
  });

  test('video player resolves & applies the video media-type binding', () {
    expect(videoPage.existsSync(), isTrue);
    final String src = videoPage.readAsStringSync();

    // Guard against dead UI: opening a video must resolve the 'video' binding.
    expect(
      src.contains('resolveProfileId(') && src.contains("mediaType: 'video'"),
      isTrue,
      reason:
          'video page must call resolveProfileId(mediaType: \'video\') so the '
          'media-type binding actually takes effect (else it is dead UI)',
    );
    expect(
      src.contains('_resolveAndApplyVideoProfile()'),
      isTrue,
      reason: 'video profile resolution entry point must be invoked on open',
    );
  });
}
