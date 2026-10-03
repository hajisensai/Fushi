import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/video/bluray/aacs_configuration.dart';
import 'package:fushi_engine/media/video/bluray/aacs_content_decoder.dart';
import 'package:fushi_engine/media/video/bluray/aacs_media_session.dart';
import 'package:fushi_engine/media/video/bluray/aacs_stream_relay.dart';
import 'package:fushi_engine/media/video/bluray/bluray_encryption.dart';
import 'package:pointycastle/export.dart';

void main() {
  late Directory directory;
  late File file;
  late HttpClient client;
  late AacsStreamRelay relay;
  final key = Uint8List.fromList(List.generate(16, (i) => i));
  final vuk = Uint8List.fromList(List.generate(16, (i) => 100 + i));
  final expected = <int>[for (var i = 0; i < 4; i++) ..._plainUnit(i)];

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('aacs-relay-test-');
    file = File('${directory.path}/fixture.m2ts');
    await file.writeAsBytes([
      for (var i = 0; i < 4; i++) ..._encryptedUnit(key, i),
    ]);
    relay = await AacsStreamRelay.open(
      streamPath: file.path,
      unitKeyFile: _keyFile(key, vuk),
      volumeUniqueKey: vuk,
    );
    client = HttpClient();
  });
  tearDown(() async {
    client.close(force: true);
    await relay.close().timeout(const Duration(seconds: 5));
    await directory.delete(recursive: true);
  });

  Future<HttpClientResponse> request({
    String method = 'GET',
    String? range,
    String? url,
  }) async {
    final request = await client.openUrl(method, Uri.parse(url ?? relay.url));
    if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
    return request.close();
  }

  test(
    'full GET and nonaligned Range return decrypted bytes exactly',
    () async {
      for (final range in <String?>[
        null,
        'bytes=6137-12311',
        'bytes=6144-6144',
        'bytes=-31',
        'bytes=24570-',
        'bytes=24570-999999',
      ]) {
        final response = await request(range: range);
        expect(response.statusCode, range == null ? 200 : 206);
        final bytes = await response.expand((chunk) => chunk).toList();
        final (start, end) = switch (range) {
          null => (0, expected.length),
          'bytes=6137-12311' => (6137, 12312),
          'bytes=6144-6144' => (6144, 6145),
          'bytes=-31' => (expected.length - 31, expected.length),
          _ => (24570, expected.length),
        };
        expect(bytes, expected.sublist(start, end));
        expect(response.contentLength, end - start);
        expect(response.headers.value('accept-ranges'), 'bytes');
        if (range != null) {
          expect(
            response.headers.value('content-range'),
            'bytes $start-${end - 1}/${expected.length}',
          );
        }
      }
    },
  );

  test('HEAD reports lengths without emitting a body', () async {
    for (final range in <String?>[null, 'bytes=6120-6170']) {
      final response = await request(method: 'HEAD', range: range);
      expect(response.statusCode, range == null ? 200 : 206);
      expect(response.contentLength, range == null ? expected.length : 51);
      expect(await response.expand((chunk) => chunk).toList(), isEmpty);
    }
  });

  test(
    'session reuses disc configuration and relay, redacts JSON and drains close',
    () async {
      final streams = await Directory(
        '${directory.path}/BDMV/STREAM',
      ).create(recursive: true);
      final aacs = await Directory('${directory.path}/AACS').create();
      final keyBytes = _keyFile(key, vuk);
      await File('${aacs.path}/Unit_Key_RO.inf').writeAsBytes(keyBytes);
      final first = await file.copy('${streams.path}/00001.m2ts');
      final second = await file.copy('${streams.path}/00002.m2ts');
      final config = File('${directory.path}/keys.cfg');
      final hexKey = vuk
          .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
          .join();
      await config.writeAsString(
        '${sha1.convert(keyBytes)} = Test | V | $hexKey',
      );
      final oldOverride = aacsKeyDbPathOverride;
      aacsKeyDbPathOverride = config.path;
      final session = AacsMediaSession();
      addTearDown(() async {
        aacsKeyDbPathOverride = oldOverride;
        await session.close();
      });
      final firstUrl = await session.resolve(first.path);
      expect(await session.resolve(first.path), firstUrl);
      await config.delete();
      final secondUrl = await session.resolve(second.path);
      expect(secondUrl, isNot(firstUrl));
      expect(session.hasProtectedStreams, isTrue);
      final metadata = session.redact(jsonEncode({'filename': firstUrl}));
      expect(jsonDecode(metadata), {'filename': '[decrypted Blu-ray]'});
      final close = session.close();
      expect(identical(close, session.close()), isTrue);
      await close;
      await expectLater(session.resolve(first.path), throwsStateError);
      expect(
        redactAacsRelayUrls('late native log $secondUrl'),
        'late native log [decrypted Blu-ray]',
      );
      await first.delete();
      await second.delete();
    },
  );

  test(
    'store gate off: encrypted stream reports encrypted, never reads or fetches configuration',
    () async {
      // iOS 商店合规门（StoreRestrictedCapability.aacsDecryption）：关掉时行为与
      // 接入解密前一致——加密码流报 BlurayEncryptedStreamException，不读本地
      // KEYDB、不下载；未加密码流照常原样返回。
      final streams = await Directory(
        '${directory.path}/BDMV/STREAM',
      ).create(recursive: true);
      final aacs = await Directory('${directory.path}/AACS').create();
      final keyBytes = _keyFile(key, vuk);
      await File('${aacs.path}/Unit_Key_RO.inf').writeAsBytes(keyBytes);
      final encrypted = await file.copy('${streams.path}/00001.m2ts');
      final plain = File('${streams.path}/00002.m2ts');
      await plain.writeAsBytes(expected);
      final config = File('${directory.path}/keys.cfg');
      final hexKey = vuk
          .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
          .join();
      await config.writeAsString(
        '${sha1.convert(keyBytes)} = Test | V | $hexKey',
      );
      final oldOverride = aacsKeyDbPathOverride;
      final oldFactory = aacsHttpClientFactory;
      final oldAvailable = aacsDecryptionAvailable;
      // 配置文件是可用的：门要是漏了，下面就会解出 loopback URL 而不是抛异常。
      aacsKeyDbPathOverride = config.path;
      aacsHttpClientFactory = () async => throw StateError('must not fetch');
      aacsDecryptionAvailable = false;
      final session = AacsMediaSession();
      addTearDown(() async {
        aacsKeyDbPathOverride = oldOverride;
        aacsHttpClientFactory = oldFactory;
        aacsDecryptionAvailable = oldAvailable;
        await session.close();
      });

      await expectLater(
        session.resolve(encrypted.path),
        throwsA(
          isA<BlurayEncryptedStreamException>().having(
            (e) => e.streamPath,
            'streamPath',
            encrypted.path,
          ),
        ),
      );
      expect(session.hasProtectedStreams, isFalse);
      expect(await session.resolve(plain.path), plain.path);
    },
  );

  test('concurrent seeks have independent file positions', () async {
    await Future.wait(
      List.generate(8, (index) async {
        final start = index * 2900;
        final response = await request(range: 'bytes=$start-${start + 900}');
        expect(
          await response.expand((chunk) => chunk).toList(),
          expected.sublist(start, start + 901),
        );
      }),
    );
  });

  test(
    'corruption after startup terminates the response without ciphertext',
    () async {
      final output = await file.open(mode: FileMode.writeOnlyAppend);
      await output.setPosition(6144);
      await output.writeFrom(Uint8List(6144));
      await output.close();
      await expectLater(() async {
        final response = await request(range: 'bytes=6144-12287');
        await response.drain<void>();
      }(), throwsA(isA<HttpException>()));
    },
  );

  test(
    'invalid ranges, guessed routes and unsupported methods are rejected',
    () async {
      for (final range in [
        'bytes=99999-',
        'bytes=20-10',
        'bytes=-0',
        'bytes=-',
        'bytes=0-1,3-4',
        'bytes=999999999999999999999999-',
      ]) {
        final response = await request(range: range);
        expect(response.statusCode, 416);
        expect(
          response.headers.value('content-range'),
          'bytes */${expected.length}',
        );
        await response.drain<void>();
      }
      for (final url in [
        '${relay.url}?path=${file.path}',
        Uri.parse(relay.url).replace(path: '/stream.m2ts').toString(),
      ]) {
        final response = await request(url: url);
        expect(response.statusCode, 404);
        await response.drain<void>();
      }
      final response = await request(method: 'POST');
      expect(response.statusCode, 405);
      await response.drain<void>();
    },
  );

  test('wrong keys and incomplete stream fail during open', () async {
    await expectLater(
      AacsStreamRelay.open(
        streamPath: file.path,
        unitKeyFile: _keyFile(key, vuk),
        volumeUniqueKey: Uint8List(16),
      ),
      throwsStateError,
    );
    await file.writeAsBytes([1, 2, 3]);
    await expectLater(
      AacsStreamRelay.open(
        streamPath: file.path,
        unitKeyFile: _keyFile(key, vuk),
        volumeUniqueKey: vuk,
      ),
      throwsStateError,
    );
  });

  test(
    'decrypted range is pulled on demand and cancelling it closes the file',
    () async {
      // Players abandon range requests on every probe and seek. A reader that
      // keeps going after its consumer left reads the rest of the title for
      // nobody, and on an optical drive starves the live request: playback
      // stalls once the first buffer runs out.
      final output = await file.open(mode: FileMode.writeOnlyAppend);
      final unit = _encryptedUnit(key, 0);
      for (var i = 0; i < 256; i++) {
        await output.writeFrom(unit);
      }
      await output.close();
      final decoder = AacsContentDecoder.fromVolumeUniqueKey(
        unitKeyFile: _keyFile(key, vuk),
        volumeUniqueKey: vuk,
      );
      final length = await file.length();
      final chunks = <Uint8List>[];
      late final StreamSubscription<Uint8List> subscription;
      final firstChunk = Completer<void>();
      subscription =
          AacsStreamRelay.decryptedRange(
            file,
            decoder,
            6137,
            length - 1,
          ).listen((chunk) {
            chunks.add(chunk);
            subscription.pause();
            if (!firstChunk.isCompleted) firstChunk.complete();
          });
      await firstChunk.future;
      // Paused consumer: the generator must not read past the pending yield.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(chunks, hasLength(1));
      expect(chunks.single.sublist(0, 7), expected.sublist(6137, 6144));
      await subscription.cancel();
      if (Platform.isWindows) {
        // Windows refuses deleting a file while any handle is still open.
        await file.delete();
        await file.writeAsBytes(const <int>[]);
      }
    },
  );

  test(
    'decrypted range fails before emitting a unit it cannot decrypt',
    () async {
      final output = await file.open(mode: FileMode.writeOnlyAppend);
      await output.setPosition(6144);
      await output.writeFrom(Uint8List(6144));
      await output.close();
      final decoder = AacsContentDecoder.fromVolumeUniqueKey(
        unitKeyFile: _keyFile(key, vuk),
        volumeUniqueKey: vuk,
      );
      final emitted = <int>[];
      await expectLater(
        AacsStreamRelay.decryptedRange(
          file,
          decoder,
          0,
          expected.length - 1,
        ).forEach(emitted.addAll),
        throwsFormatException,
      );
      expect(emitted, isEmpty);
    },
  );

  test(
    'disconnect and shutdown release files and stop the listening socket',
    () async {
      // A large file keeps the response in flight after headers arrive.
      final output = await file.open(mode: FileMode.writeOnlyAppend);
      final unit = _encryptedUnit(key, 0);
      for (var i = 0; i < 4096; i++) {
        await output.writeFrom(unit);
      }
      await output.close();
      await relay.close();
      relay = await AacsStreamRelay.open(
        streamPath: file.path,
        unitKeyFile: _keyFile(key, vuk),
        volumeUniqueKey: vuk,
      );
      final disconnected = await request();
      final subscription = disconnected.listen((_) {}, onError: (Object _) {});
      await subscription.cancel();
      final active = await request();
      final activeSubscription = active.listen((_) {}, onError: (Object _) {});
      activeSubscription.pause();
      await relay.close().timeout(const Duration(seconds: 5));
      await relay.close();
      await activeSubscription.cancel();
      final fresh = HttpClient();
      try {
        await expectLater(
          fresh.getUrl(Uri.parse(relay.url)),
          throwsA(isA<SocketException>()),
        );
      } finally {
        fresh.close(force: true);
      }
      // Windows refuses deleting files while handles remain open.
      await file.delete();
    },
  );
}

Uint8List _keyFile(Uint8List key, Uint8List vuk) {
  final file = Uint8List(96);
  ByteData.sublistView(file)
    ..setUint32(0, 32)
    ..setUint16(32, 1);
  file[17] = 1;
  (AESEngine()..init(true, KeyParameter(vuk))).processBlock(key, 0, file, 80);
  return file;
}

Uint8List _plainUnit(int seed) {
  final unit = Uint8List.fromList(
    List.generate(6144, (i) => (i * 7 + seed) & 255),
  );
  for (var offset = 0; offset < unit.length; offset += 192) {
    unit[offset] &= 0x3f;
    unit[offset + 4] = 0x47;
  }
  return unit;
}

Uint8List _encryptedUnit(Uint8List key, int seed) {
  final unit = _plainUnit(seed);
  for (var offset = 0; offset < unit.length; offset += 192) {
    unit[offset] |= 0x40;
  }
  final blockKey = Uint8List(16);
  (AESEngine()..init(true, KeyParameter(key))).processBlock(
    unit,
    0,
    blockKey,
    0,
  );
  for (var i = 0; i < 16; i++) {
    blockKey[i] ^= unit[i];
  }
  final iv = Uint8List.fromList([
    0x0b,
    0xa0,
    0xf8,
    0xdd,
    0xfe,
    0xa6,
    0x1f,
    0xb3,
    0xd8,
    0xdf,
    0x9f,
    0x56,
    0x6a,
    0x05,
    0x0f,
    0x78,
  ]);
  final cipher = CBCBlockCipher(AESEngine())
    ..init(true, ParametersWithIV(KeyParameter(blockKey), iv));
  for (var offset = 16; offset < unit.length; offset += 16) {
    cipher.processBlock(unit, offset, unit, offset);
  }
  return unit;
}
