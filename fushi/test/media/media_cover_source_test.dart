import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart' show MediaKind;

import 'package:fushi/src/media/media_cover_source.dart';
import 'package:fushi/src/sync/remote_cover_image.dart';

class _FakeRemoteCoverFetcher implements RemoteCoverFetcher {
  @override
  Future<Uint8List> fetchRemoteCover(String coverUrl) async => Uint8List(0);

  @override
  String get coverCacheNamespace => 'fake';
}

void main() {
  test('remote cover wins over local path and keeps the stable cache key', () {
    final _FakeRemoteCoverFetcher fetcher = _FakeRemoteCoverFetcher();

    final ImageProvider? result = resolveMediaCoverImage(
      kind: MediaKind.video,
      localPath: r'C:\covers\episode.jpg',
      remoteUrl: 'https://peer.example/cover/episode',
      remoteFetcher: fetcher,
      remoteCacheKey: 'video-episode-42',
    );

    expect(result, isA<RemoteCoverImage>());
    final RemoteCoverImage image = result! as RemoteCoverImage;
    expect(image.coverUrl, 'https://peer.example/cover/episode');
    expect(image.fetcher, same(fetcher));
    expect(image.cacheKey, 'video-episode-42');
  });

  test('local cover is used when the remote client cannot fetch covers', () {
    const String path = r'C:\covers\episode.jpg';

    final ImageProvider? result = resolveMediaCoverImage(
      kind: MediaKind.video,
      localPath: path,
      remoteUrl: 'https://peer.example/cover/episode',
    );

    expect(result, isA<ResizeImage>());
    final ResizeImage resized = result! as ResizeImage;
    expect(resized.imageProvider, isA<FileImage>());
    expect((resized.imageProvider as FileImage).file.path, File(path).path);
  });

  test('missing cover returns null and fallback icon follows media kind', () {
    expect(
      resolveMediaCoverImage(kind: MediaKind.video),
      isNull,
    );
    expect(mediaCoverFallbackIcon(MediaKind.video), Icons.movie_outlined);
    expect(
      mediaCoverFallbackIcon(MediaKind.game),
      Icons.videogame_asset_outlined,
    );
    expect(mediaCoverFallbackIcon(MediaKind.epub), Icons.menu_book_outlined);
  });
}
