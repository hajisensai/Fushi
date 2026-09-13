import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/src/media/manga/mihon/quirks/comico_magazine_comic_quirk.dart';

/// BUG-2514：コミコ `magazine_comic` 作品的章节 / 页表补丁。密文与 OPF 结构取自
/// 2026-09-13 对作品 209156 免费章 19 的真实探针，不是自造的。
void main() {
  // product.data.chapter.epub.chapterEpubIncludedFile.url 原样。
  const String kIncludedUrlCipher =
      'e79U1uQ3eMxfgK/bVTAtXxWbqkJJsuiSPUrW3pBIHgBu+NSPXtiKIsoDkoulVvcL0MPIZpnnCI3qN4ChOgech/zRMblQapdbFAdgfu3S/aDWnfFsYB/b+8RcnoPro87s6L3DsL1C2gzjLLpAIUrA9Q==';
  const String kIncludedUrlPlain =
      'https://images.comico.io/magazine_comic/content/onetimeurl/ja/156/209156/19/1699025131525.epub/unzip/files/';
  const String kBaseUrl = 'https://comico.jp';
  const String kParameter = 'Policy=P&Signature=S&Key-Pair-Id=K';

  test('decrypt：AES-256-CBC 零 IV PKCS7，切掉 #<epochMs> 尾巴（真密文）', () {
    expect(
      ComicoMagazineComicQuirk.decrypt(kIncludedUrlCipher),
      kIncludedUrlPlain,
    );
  });

  test('apiHeaders 与扩展逐字一致：check-sum = sha256(WEB_KEY + 0.0.0.0 + 秒)', () {
    final ComicoMagazineComicQuirk quirk = ComicoMagazineComicQuirk(
      now: () => DateTime.fromMillisecondsSinceEpoch(1700000000123),
    );
    final Map<String, String> headers = quirk.apiHeaders(
      baseUrl: kBaseUrl,
      language: 'ja',
    );
    expect(headers['X-comico-request-time'], '1700000000');
    // python: hashlib.sha256(b"9241d2f090d01716feac20ae08ba791a0.0.0.01700000000")
    expect(
      headers['X-comico-check-sum'],
      'd6c671cba123e6a77c4cc85aa11ee21c78dc9607b552ff7a055faa5c9a9f07e4',
    );
    expect(headers['X-comico-client-platform'], 'web');
    expect(headers['X-comico-client-immutable-uid'], '0.0.0.0');
    expect(headers['Accept-Language'], 'ja');
    expect(headers['Origin'], kBaseUrl);
    expect(headers['Referer'], '$kBaseUrl/');
  });

  test('contentIdOf / matches / isNotFound / ownsChapter', () {
    expect(ComicoMagazineComicQuirk.contentIdOf('/comic/209156'), 209156);
    expect(
      ComicoMagazineComicQuirk.contentIdOf(
        '/magazine_comic/209156/chapter/19/product',
      ),
      209156,
    );
    expect(ComicoMagazineComicQuirk.contentIdOf('/manga/abc'), isNull);
    expect(
      ComicoMagazineComicQuirk.matches(
        const MihonSource(
          extensionPackage: 'p',
          id: '1',
          name: 'コミコ',
          language: 'ja',
          baseUrl: 'https://comico.jp',
        ),
      ),
      isTrue,
    );
    expect(
      ComicoMagazineComicQuirk.matches(
        const MihonSource(
          extensionPackage: 'p',
          id: '1',
          name: 'x',
          language: 'ja',
          baseUrl: 'https://mangadex.org',
        ),
      ),
      isFalse,
    );
    expect(
      ComicoMagazineComicQuirk.isNotFound(
        Exception('MihonRuntimeException(BRIDGE_HTTP_500): Not Found'),
      ),
      isTrue,
    );
    expect(
      ComicoMagazineComicQuirk.isNotFound(Exception('Forbidden')),
      isFalse,
    );
    expect(
      ComicoMagazineComicQuirk.ownsChapter(<String, Object?>{
        'fushiQuirk': 'comico_magazine_comic',
      }),
      isTrue,
    );
    expect(ComicoMagazineComicQuirk.ownsChapter(<String, Object?>{}), isFalse);
  });

  group('chapters', () {
    test(
      '走 /magazine_comic/<id>/episode；新→旧；锁章加 🔒 后缀；URL 带 product',
      () async {
        final List<Uri> seen = <Uri>[];
        final ComicoMagazineComicQuirk quirk = ComicoMagazineComicQuirk(
          clientFactory: () => MockClient((http.Request request) async {
            seen.add(request.url);
            expect(request.headers['X-comico-check-sum'], hasLength(64));
            return http.Response(
              jsonEncode(<String, Object?>{
                'result': <String, Object?>{'code': 200},
                'data': <String, Object?>{
                  'episode': <String, Object?>{
                    'content': <String, Object?>{
                      'type': 'magazine_comic',
                      'id': 209156,
                      'chapters': <Map<String, Object?>>[
                        <String, Object?>{
                          'id': 19,
                          'name': '1',
                          'publishedAt': '2023-11-09T03:00:00Z',
                          'salesConfig': <String, Object?>{'free': true},
                          'hasTrial': false,
                          'activity': <String, Object?>{
                            'rented': false,
                            'unlocked': false,
                          },
                        },
                        <String, Object?>{
                          'id': 64,
                          'name': '分冊版　64',
                          'publishedAt': '2026-02-27T15:00:00Z',
                          'salesConfig': <String, Object?>{'free': false},
                          'hasTrial': false,
                          'activity': <String, Object?>{
                            'rented': false,
                            'unlocked': false,
                          },
                        },
                      ],
                    },
                  },
                },
              }),
              200,
              headers: <String, String>{'content-type': 'application/json'},
            );
          }),
        );
        final List<MihonChapter> chapters = await quirk.chapters(
          contentId: 209156,
          baseUrl: kBaseUrl,
          language: 'ja',
        );
        expect(
          seen.single.toString(),
          'https://api.comico.jp/magazine_comic/209156/episode',
        );
        expect(chapters.map((MihonChapter c) => c.url), <String>[
          '/magazine_comic/209156/chapter/64/product',
          '/magazine_comic/209156/chapter/19/product',
        ]);
        expect(chapters.first.name, '分冊版　64 \u{1F512}');
        expect(chapters.last.name, '1');
        expect(
          chapters.last.uploadedAt,
          DateTime.utc(2023, 11, 9, 3).millisecondsSinceEpoch,
        );
      },
    );

    test('result.code != 200 → ComicoQuirkException', () async {
      final ComicoMagazineComicQuirk quirk = ComicoMagazineComicQuirk(
        clientFactory: () => MockClient(
          (_) async => http.Response(
            jsonEncode(<String, Object?>{
              'result': <String, Object?>{'code': 404},
            }),
            200,
          ),
        ),
      );
      await expectLater(
        quirk.chapters(contentId: 1, baseUrl: kBaseUrl, language: 'ja'),
        throwsA(isA<ComicoQuirkException>()),
      );
    });
  });

  group('pageUrls', () {
    /// 与真实 standard.opf 同构：xhtml 项带 fallback 指向图片；再放一个没有
    /// fallback 的 xhtml 走「拉 xhtml 取 <image xlink:href>」分支；`linear="no"`
    /// 的跳过。
    const String kOpf = '''<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="unique-id">
<manifest>
<item media-type="application/xhtml+xml" id="toc" href="navigation-documents.xhtml" properties="nav"/>
<item media-type="text/css" id="style" href="style/fixed-layout-jp.css"/>
<item media-type="image/jpeg" id="cover" href="image/cover.jpg" properties="cover-image"/>
<item media-type="image/jpeg" id="i-001" href="image/i-001.jpg"/>
<item media-type="image/jpeg" id="i-002" href="image/i-002.jpg"/>
<item media-type="application/xhtml+xml" id="p-cover" href="xhtml/p-cover.xhtml" properties="svg" fallback="cover"/>
<item media-type="application/xhtml+xml" id="p-001" href="xhtml/p-001.xhtml" properties="svg" fallback="i-001"/>
<item media-type="application/xhtml+xml" id="p-002" href="xhtml/p-002.xhtml" properties="svg"/>
</manifest>
<spine page-progression-direction="rtl">
<itemref linear="yes" idref="p-cover" properties="rendition:page-spread-center"/>
<itemref linear="no" idref="toc"/>
<itemref linear="yes" idref="p-001" properties="page-spread-left"/>
<itemref linear="yes" idref="p-002" properties="page-spread-right"/>
</spine>
</package>''';
    const String kXhtml = '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="ja">
<head><meta charset="UTF-8"/><title>2</title></head>
<body><div class="main">
<svg xmlns="http://www.w3.org/2000/svg" version="1.1" xmlns:xlink="http://www.w3.org/1999/xlink" width="100%" height="100%" viewBox="0 0 1440 2048">
<image width="1440" height="2048" xlink:href="../image/i-002.jpg"/>
</svg>
</div></body></html>''';

    http.Response productResponse({bool withEpub = true}) => http.Response(
      jsonEncode(<String, Object?>{
        'result': <String, Object?>{'code': 200},
        'data': <String, Object?>{
          'chapter': <String, Object?>{
            if (withEpub)
              'epub': <String, Object?>{
                'url': 'ignored',
                'decryptKey': 'ignored',
                'chapterEpubIncludedFile': <String, Object?>{
                  'url': kIncludedUrlCipher,
                  'parameter': kParameter,
                  'm2Parameter': <String, Object?>{
                    'optimize': '/dims/optimize',
                  },
                  'rootPath': 'item/',
                  'rootFileName': 'standard.opf',
                },
              },
          },
        },
      }),
      200,
    );

    test(
      'product → 预解压 EPUB：按 spine 序、fallback 直取图、无 fallback 拉 xhtml、跳 linear=no',
      () async {
        final List<String> seen = <String>[];
        final ComicoMagazineComicQuirk quirk = ComicoMagazineComicQuirk(
          clientFactory: () => MockClient((http.Request request) async {
            final String url = request.url.toString();
            seen.add(url);
            if (url.startsWith('https://api.comico.jp/')) {
              return productResponse();
            }
            if (url == '${kIncludedUrlPlain}item/standard.opf?$kParameter') {
              return http.Response(kOpf, 200);
            }
            if (url ==
                '${kIncludedUrlPlain}item/xhtml/p-002.xhtml?$kParameter') {
              return http.Response(kXhtml, 200);
            }
            return http.Response('nope', 404);
          }),
        );
        final List<String> pages = await quirk.pageUrls(
          chapterUrl: '/magazine_comic/209156/chapter/19/product',
          baseUrl: kBaseUrl,
          language: 'ja',
        );
        expect(pages, <String>[
          '${kIncludedUrlPlain}item/image/cover.jpg?$kParameter',
          '${kIncludedUrlPlain}item/image/i-001.jpg?$kParameter',
          '${kIncludedUrlPlain}item/image/i-002.jpg?$kParameter',
        ]);
        // 有 fallback 的 xhtml 一次都不拉；没 fallback 的拉一次。
        expect(seen.where((String u) => u.contains('p-001.xhtml')), isEmpty);
        expect(
          seen.where((String u) => u.contains('p-002.xhtml')),
          hasLength(1),
        );
        // 不追加 /dims/optimize。
        expect(pages.any((String u) => u.contains('optimize')), isFalse);
      },
    );

    test('付费未解锁：product 没有 epub → ComicoQuirkException', () async {
      final ComicoMagazineComicQuirk quirk = ComicoMagazineComicQuirk(
        clientFactory: () =>
            MockClient((_) async => productResponse(withEpub: false)),
      );
      await expectLater(
        quirk.pageUrls(
          chapterUrl: '/magazine_comic/209156/chapter/64/product',
          baseUrl: kBaseUrl,
          language: 'ja',
        ),
        throwsA(isA<ComicoQuirkException>()),
      );
    });
  });

  test('fetchImage：带 Accept/Referer，200 回字节，非 200 抛', () async {
    final ComicoMagazineComicQuirk quirk = ComicoMagazineComicQuirk(
      clientFactory: () => MockClient((http.Request request) async {
        expect(request.headers['Referer'], '$kBaseUrl/');
        expect(request.headers['Accept'], contains('image/'));
        if (request.url.path.endsWith('ok.jpg')) {
          return http.Response.bytes(<int>[0xff, 0xd8, 0xff], 200);
        }
        return http.Response('MissingKey', 403);
      }),
    );
    final Uint8List bytes = await quirk.fetchImage(
      'https://images.comico.io/x/ok.jpg?Policy=P',
      baseUrl: kBaseUrl,
    );
    expect(bytes, <int>[0xff, 0xd8, 0xff]);
    await expectLater(
      quirk.fetchImage(
        'https://images.comico.io/x/nope.jpg',
        baseUrl: kBaseUrl,
      ),
      throwsA(isA<ComicoQuirkException>()),
    );
  });
}
