// 入门预置卡组：清单解析（内置清单合法、坏清单整份拒掉）、按语言排序、下载（校验哈希、
// 失败 / 取消路径、已下好的包按哈希复用不再联网）。
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:fushi_engine/srs/starter/srs_starter_packs.dart';
import 'package:fushi_engine/utils/misc/resumable_downloader.dart';
import 'package:test/test.dart';

Map<String, Object?> _packJson({
  String id = 'demo',
  String language = 'ja',
  String url = 'https://example.com/demo.apkg',
  String sha256 =
      '0000000000000000000000000000000000000000000000000000000000000000',
}) => <String, Object?>{
  'id': id,
  'name': 'Demo',
  'language': language,
  'cardCount': 10,
  'deckName': 'Demo',
  'version': '1.0',
  'source': 'someone/demo',
  'homepage': 'https://example.com',
  'license': 'CC-BY-4.0',
  'url': url,
  'sizeBytes': 100,
  'sha256': sha256,
};

String _manifest(List<Map<String, Object?>> packs) =>
    jsonEncode(<String, Object?>{'version': 1, 'packs': packs});

SrsStarterPack _packFor(List<int> bytes, {String id = 'demo'}) =>
    SrsStarterPack(
      id: id,
      name: 'Demo',
      language: 'ja',
      cardCount: 1,
      deckName: 'Demo',
      version: '1',
      source: 'test',
      homepage: Uri.parse('https://example.com'),
      license: kSrsStarterLicenseUnspecified,
      url: Uri.parse('https://example.com/demo.apkg'),
      sizeBytes: bytes.length,
      sha256: crypto.sha256.convert(bytes).toString(),
    );

void main() {
  group('清单解析', () {
    test('内置清单合法，含 Kaishi 1.5k（日语、钉死版本与哈希）', () {
      final List<SrsStarterPack> packs = parseSrsStarterPackManifest(
        kSrsStarterPackManifestJson,
      );
      final SrsStarterPack kaishi = packs.singleWhere(
        (SrsStarterPack p) => p.id == 'kaishi-1.5k',
      );
      expect(kaishi.language, 'ja');
      expect(kaishi.cardCount, 1501);
      expect(kaishi.deckName, 'Kaishi 1.5k');
      expect(kaishi.license, kSrsStarterLicenseUnspecified);
      expect(kaishi.url.scheme, 'https');
      expect(kaishi.url.path, contains('v${kaishi.version}'));
      expect(kaishi.sha256, hasLength(64));
      expect(kaishi.sizeBytes, 108692963);
      expect(kSrsStarterPacks, hasLength(packs.length));
    });

    test('合法项逐字段读出；sha256 统一小写', () {
      final List<SrsStarterPack> packs = parseSrsStarterPackManifest(
        _manifest(<Map<String, Object?>>[_packJson(sha256: 'A' * 64)]),
      );
      expect(packs.single.sha256, 'a' * 64);
      expect(packs.single.license, 'CC-BY-4.0');
      expect(packs.single.homepage.host, 'example.com');
    });

    for (final (String name, String source) in <(String, String)>[
      ('坏 JSON', '{'),
      ('版本不认识', jsonEncode(<String, Object?>{'version': 2, 'packs': []})),
      ('packs 不是数组', jsonEncode(<String, Object?>{'version': 1, 'packs': 3})),
      (
        '非 https 地址',
        _manifest(<Map<String, Object?>>[
          _packJson(url: 'http://example.com/a.apkg'),
        ]),
      ),
      ('坏哈希', _manifest(<Map<String, Object?>>[_packJson(sha256: 'abc')])),
      ('坏语言', _manifest(<Map<String, Object?>>[_packJson(language: 'JA')])),
      ('id 重复', _manifest(<Map<String, Object?>>[_packJson(), _packJson()])),
      (
        '缺字段',
        _manifest(<Map<String, Object?>>[
          <String, Object?>{..._packJson()}..remove('deckName'),
        ]),
      ),
    ]) {
      test('整份拒掉：$name', () {
        expect(
          () => parseSrsStarterPackManifest(source),
          throwsA(isA<SrsStarterManifestException>()),
        );
      });
    }

    test('偏好语言排前，其余按语言再按名字', () {
      final List<SrsStarterPack> packs = parseSrsStarterPackManifest(
        _manifest(<Map<String, Object?>>[
          _packJson(id: 'a', language: 'en'),
          _packJson(id: 'b', language: 'ja'),
          _packJson(id: 'c', language: 'ko'),
        ]),
      );
      expect(
        sortSrsStarterPacks(
          packs,
          preferredLanguages: <String>['ko'],
        ).map((SrsStarterPack p) => p.language),
        <String>['ko', 'en', 'ja'],
      );
    });
  });

  group('下载', () {
    late Directory dir;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('srs_starter_test_');
    });
    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('下完校验通过：返回包文件、进度到满、不留 .part', () async {
      final List<int> bytes = utf8.encode('fake apkg bytes');
      final SrsStarterPack pack = _packFor(bytes);
      final List<int> progress = <int>[];
      final File file = await downloadSrsStarterPack(
        pack: pack,
        dir: dir,
        onProgress: (int received, int total) {
          expect(total, bytes.length);
          progress.add(received);
        },
        open: (Uri uri, Map<String, String> headers) async {
          expect(uri, pack.url);
          return ResumableDownloadResponse.bytes(statusCode: 200, body: bytes);
        },
      );
      expect(file.path, srsStarterPackFile(dir, pack).path);
      expect(await file.readAsBytes(), bytes);
      expect(progress.last, bytes.length);
      expect(await File('${file.path}.part').exists(), isFalse);
    });

    test('哈希不对：抛完整性异常，不留包也不留 .part', () async {
      final SrsStarterPack pack = _packFor(utf8.encode('expected'));
      await expectLater(
        downloadSrsStarterPack(
          pack: pack,
          dir: dir,
          open: (Uri _, Map<String, String> _) async =>
              ResumableDownloadResponse.bytes(
                statusCode: 200,
                body: utf8.encode('tampered'),
              ),
        ),
        throwsA(isA<ResumableDownloadIntegrityException>()),
      );
      final File target = srsStarterPackFile(dir, pack);
      expect(await target.exists(), isFalse);
      expect(await File('${target.path}.part').exists(), isFalse);
    });

    test('服务端报错：抛 HttpException', () async {
      final SrsStarterPack pack = _packFor(utf8.encode('x'));
      await expectLater(
        downloadSrsStarterPack(
          pack: pack,
          dir: dir,
          open: (Uri _, Map<String, String> _) async =>
              ResumableDownloadResponse.bytes(
                statusCode: 404,
                body: const <int>[],
              ),
        ),
        throwsA(isA<HttpException>()),
      );
      expect(await srsStarterPackFile(dir, pack).exists(), isFalse);
    });

    test('取消：抛 SrsStarterDownloadCancelled', () async {
      final SrsStarterPack pack = _packFor(utf8.encode('abcdef'));
      final SrsStarterDownloadCancelToken token =
          SrsStarterDownloadCancelToken();
      await expectLater(
        downloadSrsStarterPack(
          pack: pack,
          dir: dir,
          cancel: token,
          onProgress: (int received, int _) {
            if (received > 0) token.cancel();
          },
          open: (Uri _, Map<String, String> _) async =>
              ResumableDownloadResponse(
                statusCode: 200,
                headers: const <String, String>{},
                stream: Stream<List<int>>.fromIterable(<List<int>>[
                  utf8.encode('abc'),
                  utf8.encode('def'),
                ]),
              ),
        ),
        throwsA(isA<SrsStarterDownloadCancelled>()),
      );
      expect(await srsStarterPackFile(dir, pack).exists(), isFalse);
    });

    test('已下好且哈希对：直接复用，不联网；哈希不对：删掉重下', () async {
      final List<int> bytes = utf8.encode('cached');
      final SrsStarterPack pack = _packFor(bytes);
      final File target = srsStarterPackFile(dir, pack);
      await target.writeAsBytes(bytes);
      int opens = 0;
      Future<ResumableDownloadResponse> open(
        Uri _,
        Map<String, String> _,
      ) async {
        opens++;
        return ResumableDownloadResponse.bytes(statusCode: 200, body: bytes);
      }

      await downloadSrsStarterPack(pack: pack, dir: dir, open: open);
      expect(opens, 0);

      await target.writeAsBytes(utf8.encode('CACHED'));
      final File again = await downloadSrsStarterPack(
        pack: pack,
        dir: dir,
        open: open,
      );
      expect(opens, 1);
      expect(await again.readAsBytes(), bytes);
    });
  });
}
