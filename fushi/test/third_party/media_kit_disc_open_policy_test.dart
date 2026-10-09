import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit/native_open_policy.dart';

void main() {
  test('explicit single Blu-ray Media retains its direct request origin', () {
    for (final String uri in <String>['bd://menu', 'bluray://menu', 'bd://1']) {
      expect(nativeOpenUsesDirectLoad(Media(uri)), isTrue, reason: uri);
    }
  });

  test('one-entry disc Playlist never inherits single Media trust', () {
    for (final String uri in <String>['bd://menu', 'bluray://menu']) {
      expect(nativeOpenUsesDirectLoad(Playlist(<Media>[Media(uri)])), isFalse);
    }
  });

  test('mixed playlists cannot smuggle a disc through the fd fallback', () {
    for (final List<Media> entries in <List<Media>>[
      <Media>[Media('fd://7'), Media('bd://menu')],
      <Media>[Media('bluray://menu'), Media('fd://7')],
      <Media>[Media('https://example.test/video.mkv'), Media('bd://menu')],
    ]) {
      expect(nativeOpenUsesDirectLoad(Playlist(entries)), isFalse);
    }
  });

  test('ordinary file, HTTP, EDL and external playlist origins are unchanged', () {
    for (final String uri in <String>[
      '/movies/movie.mkv',
      'file:///movies/movie.mkv',
      'https://example.test/video.mkv',
      'https://example.test/bd://menu',
      'edl://%18%/movies/movie.mkv,0,1;',
      'file:///movies/disc.m3u',
      'file:///movies/bd://menu.m3u',
    ]) {
      expect(nativeOpenUsesDirectLoad(Media(uri)), isFalse, reason: uri);
    }
  });

  test('fd Media and disc-free fd Playlist retain Android behavior', () {
    expect(nativeOpenUsesDirectLoad(Media('fd://7')), isTrue);
    expect(nativeOpenUsesDirectLoad(Playlist(<Media>[Media('fd://7')])), isTrue);
    expect(nativeOpenUsesDirectLoad(Playlist(<Media>[
      Media('fd://7'), Media('https://example.test/video.mkv'),
    ])), isTrue);
    expect(nativeOpenUsesDirectLoad(Playlist(const <Media>[])), isFalse);
  });
}
