import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/aidoku/aidoku_package_store.dart';
import 'package:fushi/src/media/manga/aidoku/aidoku_reader_chapter.dart';
import 'package:fushi/src/media/manga/aidoku/aidoku_runtime.dart';
import 'package:fushi/src/media/manga/mihon/mihon_reader_chapter.dart';

void main() {
  test('parses Aidoku URL pages and preserves request headers', () {
    final AidokuImagePage page = AidokuImagePage.fromJson(
      <String, Object?>{
        'content': <String, Object?>{
          'Url': <Object?>[
            'https://cdn.example/page.jpg',
            <String, String>{'Referer': 'https://source.example/'},
          ],
        },
      },
    );

    expect(page.url, 'https://cdn.example/page.jpg');
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
          'Url': <Object?>[
            'https://cdn.example/page.jpg',
            <String, String>{
              'User-Agent': 'Fushi',
              'Referer': 'https://source.example/',
            },
          ],
        },
      },
    );
    final AidokuImagePage sameHeadersDifferentOrder = AidokuImagePage.fromJson(
      <String, Object?>{
        'content': <String, Object?>{
          'Url': <Object?>[
            'https://cdn.example/page.jpg',
            <String, String>{
              'Referer': 'https://source.example/',
              'User-Agent': 'Fushi',
            },
          ],
        },
      },
    );
    expect(reordered.identity, sameHeadersDifferentOrder.identity);
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
  });
}
