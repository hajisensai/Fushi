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

/// mpv's Blu-ray (`bd`, `bluray`), DVD (`dvd`, `dvdnav`) and audio CD
/// (`cdda`) stream drivers.
bool _isDisc(String uri) =>
    uri.startsWith('bd://') ||
    uri.startsWith('bluray://') ||
    uri.startsWith('dvd://') ||
    uri.startsWith('dvdnav://') ||
    _isOwnCdda(uri);

/// Audio CD: only the exact `cdda://<drive>` shape the app builds from its own
/// drive list (Windows `E:`, Linux `/dev/sr0`, macOS `/dev/rdisk4`). mpv's
/// cdda stream takes the whole remainder as a device path, so anything else
/// (other paths, query strings, `..`) keeps mpv's origin check.
final RegExp _ownCdda = RegExp(r'^cdda://(?:[A-Za-z]:|/dev/[A-Za-z][A-Za-z0-9]*)$');

bool _isOwnCdda(String uri) => _ownCdda.hasMatch(uri);
