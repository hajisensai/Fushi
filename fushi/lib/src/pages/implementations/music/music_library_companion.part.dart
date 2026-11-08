part of 'music_library_page.dart';

/// Dual-screen companion, Library tab Main mode (S5): the music library
/// publishes the album card focused on top ([LibraryCompanionHook] owns the
/// claim and the throttled snapshot). The page has no in-place search (its
/// search is a pushed page), sort or filter, so none are offered.
///
/// The focused album is found from the focused node: album cards carry the
/// key `music-album-<albumUid>` (also what the page's tests find them by).
extension _MusicLibraryCompanion on _MusicLibraryPageState {
  static const String _albumKeyPrefix = 'music-album-';

  LibraryCompanionHook _createMusicCompanion() => LibraryCompanionHook(
    library: CompanionLibraryKind.music,
    snapshot: () => CompanionLibraryMainSnapshot(
      highlighted: _focusedAlbumItem(),
      searchable: false,
    ),
    onOpenHighlighted: () {
      if (_focusedAlbumItem() != null) activateLibraryCompanionFocus();
    },
  );

  CompanionLibraryItem? _focusedAlbumItem() {
    final MusicLibrarySnapshot? snap = _snapshot;
    final BuildContext? focused = FocusManager.instance.primaryFocus?.context;
    if (snap == null || focused == null || !mounted) return null;
    String? uid;
    bool inPage = false;
    focused.visitAncestorElements((Element element) {
      if (identical(element, context)) {
        inPage = true;
        return false;
      }
      final Key? key = element.widget.key;
      if (uid == null && key is ValueKey<String>) {
        uid = libraryCompanionFocusKey(key.value, _albumKeyPrefix);
      }
      return true;
    });
    // A focused node outside this page is not ours.
    final String? albumUid = inPage ? uid : null;
    final MusicAlbumRow? album = albumUid == null
        ? null
        : snap.albumByUid[albumUid];
    if (album == null) return null;
    final int tracks = snap.tracksOfAlbum(album.albumUid).length;
    final String? artist = album.albumArtistCredit?.trim();
    final String? cover = album.coverPath;
    return CompanionLibraryItem(
      ref: CompanionLibraryRef.musicAlbum(album.albumUid),
      kind: CompanionLibraryItemKind.musicAlbum,
      title: album.title,
      subtitle: artist == null || artist.isEmpty ? null : artist,
      count: tracks > 0 ? tracks : null,
      coverPath: cover == null || cover.isEmpty ? null : cover,
    );
  }
}
