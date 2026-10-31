import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit/native_open_policy.dart';

void main() {
  test('explicit single Blu-ray Media retains its direct request origin', () {
    for (final String uri in <String>[
      'bd://menu',
      'bluray://menu',
      'bd://1',
      // DVD (stream_dvdnav.c is STREAM_ORIGIN_UNSAFE too): found by the DVD
      // menu integration test, wrapped in an m3u mpv refused `dvd://menu`.
      'dvd://menu',
      'dvd://0/D:/discs/show',
      'dvdnav://menu',
    ]) {
      expect(nativeOpenUsesDirectLoad(Media(uri)), isTrue, reason: uri);
    }
  });

  test(
    'explicit single audio CD Media in the app-built drive shape loads directly',
    () {
      // mpv's stream_cdda is STREAM_ORIGIN_UNSAFE: the music backend's m3u path
      // reported "No protocol handler found" for cdda://E: (music P5).
      for (final String uri in <String>[
        'cdda://E:',
        'cdda://d:',
        'cdda:///dev/sr0',
        'cdda:///dev/rdisk4',
      ]) {
        expect(nativeOpenUsesDirectLoad(Media(uri)), isTrue, reason: uri);
      }
    },
  );

  test('any other cdda shape keeps the origin check', () {
    for (final String uri in <String>[
      'cdda://',
      'cdda://E:/',
      r'cdda://E:\track01.cda',
      'cdda://EE:',
      'cdda:///dev/sr0/../../etc/passwd',
      'cdda:///dev/sr0?x=1',
      'cdda:///tmp/image.bin',
      'cdda://C:/Users/x/disc.cue',
      r'cdda://\\server\share',
      'https://example.test/cdda://E:',
    ]) {
      expect(nativeOpenUsesDirectLoad(Media(uri)), isFalse, reason: uri);
    }
  });

  test('one-entry disc Playlist never inherits single Media trust', () {
    for (final String uri in <String>[
      'bd://menu',
      'bluray://menu',
      'dvd://menu',
      'cdda://E:',
    ]) {
      expect(nativeOpenUsesDirectLoad(Playlist(<Media>[Media(uri)])), isFalse);
    }
  });

  test('mixed playlists cannot smuggle a disc through the fd fallback', () {
    for (final List<Media> entries in <List<Media>>[
      <Media>[Media('fd://7'), Media('bd://menu')],
      <Media>[Media('bluray://menu'), Media('fd://7')],
      <Media>[Media('https://example.test/video.mkv'), Media('bd://menu')],
      <Media>[Media('fd://7'), Media('cdda://E:')],
      <Media>[Media('cdda://E:'), Media('cdda://E:')],
    ]) {
      expect(nativeOpenUsesDirectLoad(Playlist(entries)), isFalse);
    }
  });

  test(
    'ordinary file, HTTP, EDL and external playlist origins are unchanged',
    () {
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
    },
  );

  test('fd Media and disc-free fd Playlist retain Android behavior', () {
    expect(nativeOpenUsesDirectLoad(Media('fd://7')), isTrue);
    expect(
      nativeOpenUsesDirectLoad(Playlist(<Media>[Media('fd://7')])),
      isTrue,
    );
    expect(
      nativeOpenUsesDirectLoad(
        Playlist(<Media>[
          Media('fd://7'),
          Media('https://example.test/video.mkv'),
        ]),
      ),
      isTrue,
    );
    expect(nativeOpenUsesDirectLoad(Playlist(const <Media>[])), isFalse);
  });
}
