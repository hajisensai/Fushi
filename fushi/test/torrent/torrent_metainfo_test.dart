import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/torrent/torrent_metainfo.dart';

void main() {
  group('inspectTorrentMetainfo', () {
    test('hashes the exact v1 info dictionary bytes', () {
      final Uint8List bytes = _v1Metainfo();
      final Uint8List rawInfo = Uint8List.fromList(
        utf8.encode(
          'd6:lengthi1e4:name4:test6:pieces20:aaaaaaaaaaaaaaaaaaaae',
        ),
      );
      final String expected = crypto.sha1.convert(rawInfo).toString();

      final InspectedTorrentMetainfo inspected = inspectTorrentMetainfo(
        bytes,
        expectedInfoHash: expected.toUpperCase(),
      );

      expect(inspected.v1InfoHash, expected);
      expect(inspected.v2InfoHash, isNull);
      expect(inspected.torrentId, expected);
      expect(inspected.toPayload(fileName: 'test.torrent').bytes, bytes);
    });

    test('uses truncated sha256 id for a pure v2 torrent', () {
      final Uint8List bytes = Uint8List.fromList(
        utf8.encode(
          'd4:infod9:file treede12:meta versioni2e4:name4:testee',
        ),
      );

      final InspectedTorrentMetainfo inspected = inspectTorrentMetainfo(bytes);

      expect(inspected.v1InfoHash, isNull);
      expect(inspected.v2InfoHash, hasLength(64));
      expect(inspected.torrentId, inspected.v2InfoHash!.substring(0, 40));
    });

    test('rejects a declared hash mismatch', () {
      expect(
        () => inspectTorrentMetainfo(
          _v1Metainfo(),
          expectedInfoHash: '0' * 40,
        ),
        throwsA(
          isA<TorrentMetainfoException>().having(
            (TorrentMetainfoException error) => error.code,
            'code',
            TorrentMetainfoErrorCode.hashMismatch,
          ),
        ),
      );
    });

    test('rejects trailing and truncated bencode', () {
      expect(
        () => inspectTorrentMetainfo(
          Uint8List.fromList(<int>[..._v1Metainfo(), 0]),
        ),
        throwsA(isA<TorrentMetainfoException>()),
      );
      expect(
        () => inspectTorrentMetainfo(
          Uint8List.sublistView(_v1Metainfo(), 0, _v1Metainfo().length - 1),
        ),
        throwsA(isA<TorrentMetainfoException>()),
      );
    });
  });
}

Uint8List _v1Metainfo() => Uint8List.fromList(
      utf8.encode(
        'd4:infod6:lengthi1e4:name4:test6:pieces20:aaaaaaaaaaaaaaaaaaaaee',
      ),
    );
