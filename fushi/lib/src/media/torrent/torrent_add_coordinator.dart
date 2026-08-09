import 'package:fushi/src/media/torrent/torrent_backend.dart';

/// Routes a provider-resolved torrent payload to the active download backend.
class TorrentAddCoordinator {
  const TorrentAddCoordinator(this.backend);

  final TorrentBackend backend;

  Future<bool> add(
    TorrentAddPayload payload, {
    required String category,
    bool sequential = false,
    bool firstLastPiecePrio = false,
  }) {
    return switch (payload) {
      TorrentMagnetPayload magnet => backend.addTorrent(
          magnet.magnetUri,
          category: category,
          sequential: sequential,
          firstLastPiecePrio: firstLastPiecePrio,
        ),
      TorrentMetainfoPayload metainfo => _addMetainfo(
          metainfo,
          category: category,
          sequential: sequential,
          firstLastPiecePrio: firstLastPiecePrio,
        ),
    };
  }

  Future<bool> _addMetainfo(
    TorrentMetainfoPayload payload, {
    required String category,
    required bool sequential,
    required bool firstLastPiecePrio,
  }) {
    final TorrentBackend current = backend;
    if (current is! TorrentMetainfoBackend) return Future<bool>.value(false);
    return current.addTorrentMetainfo(
      payload,
      category: category,
      sequential: sequential,
      firstLastPiecePrio: firstLastPiecePrio,
    );
  }
}
