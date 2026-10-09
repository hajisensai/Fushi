// Fushi overlay for media_kit 1.2.6. See the accompanying README.md.
// Keep the original media_kit MIT license supplied with this package.

import 'src/models/media/media.dart';
import 'src/models/playable.dart';
import 'src/models/playlist.dart';

/// Only an explicitly opened single disc is trusted to use mpv's unsafe-origin
/// disc protocol. Converting that request into a temporary m3u loses its origin
/// and mpv correctly refuses the URL. Never grant this trust to a Playlist.
///
/// Preserve the existing Android fd:// direct-load behavior except for mixed
/// fd/disc playlists, which must retain mpv's playlist-origin checks.
bool nativeOpenUsesDirectLoad(Playable playable) {
  if (playable is Media) {
    return _isDisc(playable.uri) || playable.uri.startsWith('fd://');
  }
  if (playable is Playlist) {
    if (playable.medias.any((Media media) => _isDisc(media.uri))) return false;
    return playable.medias.any((Media media) => media.uri.startsWith('fd://'));
  }
  return false;
}

bool _isDisc(String uri) => uri.startsWith('bd://') || uri.startsWith('bluray://');
