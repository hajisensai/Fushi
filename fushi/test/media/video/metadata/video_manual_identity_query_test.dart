import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/metadata/video_manual_identity_query.dart';

void main() {
  test('selected source qualifies numeric work IDs', () {
    expect(videoManualIdentityQuery('42', VideoManualIdentitySource.mal),
        'mal=42');
    expect(videoManualIdentityQuery('42', VideoManualIdentitySource.tmdbMovie),
        'tmdb:movie=42');
    expect(videoManualIdentityQuery('42', VideoManualIdentitySource.tmdbTv),
        'tmdb:tv=42');
  });

  test('official links are normalized without losing TMDB namespace', () {
    expect(
        videoManualIdentityQuery('https://myanimelist.net/anime/1/Cowboy_Bebop',
            VideoManualIdentitySource.mal),
        'mal=1');
    expect(
        videoManualIdentityQuery('https://www.themoviedb.org/movie/42-title',
            VideoManualIdentitySource.tmdbMovie),
        'tmdb:movie=42');
    expect(
        videoManualIdentityQuery(
            'themoviedb.org/tv/42-title', VideoManualIdentitySource.tmdbTv),
        'tmdb:tv=42');
  });

  test('rejects invalid IDs, source mismatch and non-official hosts', () {
    for (final String query in <String>[
      '0',
      '-42',
      'title',
      'https://myanimelist.net.evil.test/anime/42'
    ]) {
      expect(
          () => videoManualIdentityQuery(query, VideoManualIdentitySource.mal),
          throwsFormatException);
    }
    expect(
        () => videoManualIdentityQuery('https://themoviedb.org/movie/42',
            VideoManualIdentitySource.tmdbTv),
        throwsFormatException);
  });
}
