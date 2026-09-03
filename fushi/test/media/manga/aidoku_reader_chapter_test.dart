import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/aidoku/aidoku_package_store.dart';
import 'package:fushi/src/media/manga/aidoku/aidoku_reader_chapter.dart';
import 'package:fushi/src/media/manga/aidoku/aidoku_runtime.dart';
import 'package:fushi/src/media/manga/mihon/mihon_reader_chapter.dart';

void main() {
  test('keeps page context separate from resolved image request headers', () {
    final AidokuImagePage page = AidokuImagePage.fromJson(
      <String, Object?>{
        'content': <String, Object?>{
          'Url': <Object?>[
            'https://cdn.example/page.jpg',
            <String, String>{'shuffled': '1'},
          ],
        },
        'request_url': 'https://images.example/page.jpg',
        'request_headers': <String, String>{
          'Referer': 'https://source.example/',
        },
      },
    );

    expect(page.url, 'https://images.example/page.jpg');
    expect(page.context, <String, String>{'shuffled': '1'});
    expect(page.headers, <String, String>{
      'Referer': 'https://source.example/',
    });
    expect(page.requestHeaders()['User-Agent'], contains('Mozilla/5.0'));
    expect(
      page.requestHeaders(referer: 'https://fallback.example/')['Referer'],
      'https://source.example/',
      reason: 'explicit Aidoku page headers override the manga fallback',
    );
    expect(page.identity, hasLength(64));
    final AidokuImagePage reordered = AidokuImagePage.fromJson(
      <String, Object?>{
        'content': <String, Object?>{
          'Url': <Object?>['https://cdn.example/page.jpg', null],
        },
        'request_url': 'https://images.example/page.jpg',
        'request_headers': <String, String>{
          'User-Agent': 'Fushi',
          'Referer': 'https://source.example/',
        },
      },
    );
    final AidokuImagePage sameHeadersDifferentOrder = AidokuImagePage.fromJson(
      <String, Object?>{
        'content': <String, Object?>{
          'Url': <Object?>['https://cdn.example/page.jpg', null],
        },
        'request_url': 'https://images.example/page.jpg',
        'request_headers': <String, String>{
          'Referer': 'https://source.example/',
          'User-Agent': 'Fushi',
        },
      },
    );
    expect(reordered.identity, sameHeadersDifferentOrder.identity);
  });

  test('percent-encodes Unicode Aidoku Referer URLs for dart:io', () {
    final AidokuImagePage page = AidokuImagePage.fromJson(
      const <String, Object?>{
        'content': <String, Object?>{
          'Url': <Object?>['https://sv1.freeimgmg.online/page.jpg', null],
        },
      },
    );

    expect(
      page.requestHeaders(
        referer: 'https://rawotaku.com/read/イジめてイジられて-raw/',
      )['Referer'],
      'https://rawotaku.com/read/'
      '%E3%82%A4%E3%82%B8%E3%82%81%E3%81%A6%E3%82%A4%E3%82%B8%E3%82%89%E3%82%8C%E3%81%A6-raw/',
    );
  });

  test('rejects non-HTTPS and unsupported Aidoku page payloads', () {
    expect(
      () => AidokuImagePage.fromJson(<String, Object?>{
        'content': <String, Object?>{
          'Url': <Object?>['http://cdn.example/page.jpg', null],
        },
      }),
      throwsA(isA<AidokuRuntimeException>()),
    );
    expect(
      () => AidokuImagePage.fromJson(<String, Object?>{
        'content': <String, Object?>{'Text': '<p>page</p>'},
      }),
      throwsA(isA<AidokuRuntimeException>()),
    );
  });

  test('Aidoku chapters use the shared online manga reader contract', () {
    final AidokuReaderChapter chapter = AidokuReaderChapter(
      package: AidokuInstalledPackage(
        id: 'ja.fixture',
        name: 'Fixture',
        version: 1,
        languages: const <String>['ja'],
        requiresWebView: false,
        packagePath: '/tmp/fixture.aix',
        installedAt: DateTime.utc(2026),
      ),
      manga: const <String, Object?>{
        'key': '/manga/',
        'title': 'Fixture manga',
        'authors': <Object?>['Author'],
      },
      chapter: const <String, Object?>{'key': '/chapter/1/'},
      pages: <AidokuImagePage>[
        AidokuImagePage.fromJson(const <String, Object?>{
          'content': <String, Object?>{
            'Url': <Object?>['https://cdn.example/page.jpg', null],
          },
        }),
      ],
    );

    expect(chapter, isA<OnlineMangaReaderChapter>());
    expect(chapter.title, 'Fixture manga');
    expect(chapter.author, 'Author');
    expect(chapter.pageCount, 1);
    expect(chapter.pageIdentities.single, hasLength(64));
    // Single-language manifest exposes its language for Lens OCR.
    expect(chapter.sourceLanguage, 'ja');
  });

  test('Aidoku multi-language manifest reports null source language', () {
    final AidokuReaderChapter chapter = AidokuReaderChapter(
      package: AidokuInstalledPackage(
        id: 'multi.fixture',
        name: 'Fixture',
        version: 1,
        languages: const <String>['en', 'ja'],
        requiresWebView: false,
        packagePath: '/tmp/fixture.aix',
        installedAt: DateTime.utc(2026),
      ),
      manga: const <String, Object?>{'key': '/manga/', 'title': 'Fixture'},
      chapter: const <String, Object?>{'key': '/chapter/1/'},
      pages: <AidokuImagePage>[
        AidokuImagePage.fromJson(const <String, Object?>{
          'content': <String, Object?>{
            'Url': <Object?>['https://cdn.example/page.jpg', null],
          },
        }),
      ],
    );
    expect(chapter.sourceLanguage, isNull);
  });
}
