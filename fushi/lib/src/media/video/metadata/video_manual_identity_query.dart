/// Explicit source selection keeps numeric work titles separate from IDs.
library;

enum VideoManualIdentitySource { mal, tmdbMovie, tmdbTv }

String videoManualIdentityQuery(
    String input, VideoManualIdentitySource source) {
  final String query = input.trim();
  final String prefix = switch (source) {
    VideoManualIdentitySource.mal => 'mal',
    VideoManualIdentitySource.tmdbMovie => 'tmdb:movie',
    VideoManualIdentitySource.tmdbTv => 'tmdb:tv',
  };
  if (RegExp(r'^[0-9]+$').hasMatch(query) && (int.tryParse(query) ?? 0) > 0) {
    return '$prefix=$query';
  }
  final Uri? uri =
      Uri.tryParse(query.contains('://') ? query : 'https://$query');
  if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http')) {
    throw const FormatException('Invalid work ID');
  }
  final List<String> path = uri.pathSegments;
  final bool mal = source == VideoManualIdentitySource.mal;
  final String expectedHost = mal ? 'myanimelist.net' : 'themoviedb.org';
  final String expectedPath = switch (source) {
    VideoManualIdentitySource.mal => 'anime',
    VideoManualIdentitySource.tmdbMovie => 'movie',
    VideoManualIdentitySource.tmdbTv => 'tv',
  };
  if ((uri.host != expectedHost && uri.host != 'www.$expectedHost') ||
      path.length < 2 ||
      path.first != expectedPath) {
    throw const FormatException('Work link does not match selected source');
  }
  final String id = path[1].split('-').first;
  if (!RegExp(r'^[0-9]+$').hasMatch(id) || (int.tryParse(id) ?? 0) <= 0) {
    throw const FormatException('Invalid work ID');
  }
  return '$prefix=$id';
}
