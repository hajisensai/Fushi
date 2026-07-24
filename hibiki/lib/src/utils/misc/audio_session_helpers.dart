import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:hibiki/src/utils/misc/platform_utils.dart';

/// Result of [beginDuckingPlayback]: the configured [AudioSession] plus the
/// becoming-noisy subscription. The subscription is handed back so each caller
/// keeps owning its lifetime exactly as before this dedup (cancel the previous
/// one before replaying, cancel on dispose where the host has one).
typedef DuckingPlayback = ({
  AudioSession session,
  StreamSubscription<void> noisySubscription,
});

/// Shared audio-preview session setup used by the creator audio fields, the
/// audio recorder dialog and the play-audio quick action.
///
/// On platforms without native audio-session support ([supportsNativeAudio]
/// is false) this returns null and the caller plays without a session.
/// Otherwise it configures transient ducking playback and subscribes to the
/// becoming-noisy event (headphones unplugged): [onBecomingNoisy] runs first
/// (pause or stop, per caller), then the session is deactivated.
Future<DuckingPlayback?> beginDuckingPlayback({
  required Future<void> Function() onBecomingNoisy,
}) async {
  if (!supportsNativeAudio) {
    return null;
  }

  final AudioSession session = await AudioSession.instance;
  await session.configure(
    const AudioSessionConfiguration(
      avAudioSessionCategory: AVAudioSessionCategory.playback,
      avAudioSessionCategoryOptions: AVAudioSessionCategoryOptions.duckOthers,
      avAudioSessionMode: AVAudioSessionMode.defaultMode,
      avAudioSessionRouteSharingPolicy:
          AVAudioSessionRouteSharingPolicy.defaultPolicy,
      avAudioSessionSetActiveOptions: AVAudioSessionSetActiveOptions.none,
      androidAudioAttributes: AndroidAudioAttributes(
        contentType: AndroidAudioContentType.music,
        usage: AndroidAudioUsage.media,
      ),
      androidAudioFocusGainType: AndroidAudioFocusGainType.gainTransientMayDuck,
      androidWillPauseWhenDucked: true,
    ),
  );

  final StreamSubscription<void> noisySubscription =
      session.becomingNoisyEventStream.listen((_) async {
    await onBecomingNoisy();
    session.setActive(false);
  });

  return (session: session, noisySubscription: noisySubscription);
}
