import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/torrent/torrent_add_coordinator.dart';
import 'package:fushi/src/media/torrent/torrent_backend.dart';

void main() {
  test('routes magnets through the base backend contract', () async {
    final _FakeBackend backend = _FakeBackend();
    final bool ok = await TorrentAddCoordinator(backend).add(
      const TorrentMagnetPayload(
        magnetUri:
            'magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567',
        torrentId: '0123456789abcdef0123456789abcdef01234567',
      ),
      category: 'anime',
      sequential: true,
    );

    expect(ok, isTrue);
    expect(backend.added, startsWith('magnet:'));
    expect(backend.category, 'anime');
    expect(backend.sequential, isTrue);
  });

  test('requires explicit backend capability for metainfo bytes', () async {
    final TorrentMetainfoPayload payload = TorrentMetainfoPayload(
      bytes: Uint8List.fromList(<int>[1, 2, 3]),
      fileName: 'test.torrent',
      torrentId: '0123456789abcdef0123456789abcdef01234567',
    );

    expect(
      await TorrentAddCoordinator(_FakeBackend()).add(
        payload,
        category: 'anime',
      ),
      isFalse,
    );
    final _FakeMetainfoBackend capable = _FakeMetainfoBackend();
    expect(
      await TorrentAddCoordinator(capable).add(
        payload,
        category: 'anime',
        firstLastPiecePrio: true,
      ),
      isTrue,
    );
    expect(capable.received, same(payload));
    expect(capable.firstLastPiecePrio, isTrue);
  });
}

class _FakeBackend implements TorrentBackend {
  String? added;
  String? category;
  bool sequential = false;

  @override
  Future<bool> addTorrent(
    String magnetOrUrl, {
    required String category,
    bool sequential = false,
    bool firstLastPiecePrio = false,
  }) async {
    added = magnetOrUrl;
    this.category = category;
    this.sequential = sequential;
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeMetainfoBackend extends _FakeBackend
    implements TorrentMetainfoBackend {
  TorrentMetainfoPayload? received;
  bool firstLastPiecePrio = false;

  @override
  Future<bool> addTorrentMetainfo(
    TorrentMetainfoPayload payload, {
    required String category,
    bool sequential = false,
    bool firstLastPiecePrio = false,
  }) async {
    received = payload;
    this.firstLastPiecePrio = firstLastPiecePrio;
    return true;
  }
}
