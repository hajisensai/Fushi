import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/src/media/manga/mihon/mihon_runtime.dart';
import 'package:fushi/src/media/manga/mihon/quirks/comico_magazine_comic_quirk.dart';
import 'package:fushi_core/fushi_core.dart';

/// BUG-2514：Mihon 适配器在コミコ源章节阶段撞 "Not Found" 时换 quirk 路由；
/// quirk 产出的章带标记，取页与取字节都不再经扩展。其它源 / 其它错误原样抛。
void main() {
  const MihonSource comico = MihonSource(
    extensionPackage: 'eu.kanade.tachiyomi.extension.ja.comico',
    id: '1',
    name: 'コミコ',
    language: 'ja',
    baseUrl: 'https://comico.jp',
  );
  const MihonSource other = MihonSource(
    extensionPackage: 'org.example.other',
    id: '2',
    name: 'Other',
    language: 'ja',
    baseUrl: 'https://example.org',
  );
  const MihonExtensionRef extension = MihonExtensionRef(
    packageName: 'eu.kanade.tachiyomi.extension.ja.comico',
    apkPath: 'comico.apk',
  );

  OnlineMangaLibraryEntry entry(MihonSource source) => OnlineMangaLibraryEntry(
    runtime: OnlineMangaRuntimeKind.mihon,
    extensionPackage: source.extensionPackage,
    sourceId: source.id,
    series: const OnlineMangaSeries(
      key: '/comic/209156',
      title: '婚約者は、私の妹に恋をする【分冊版】',
      raw: <String, Object?>{'url': '/comic/209156', 'title': 'x'},
    ),
    chapters: const <OnlineMangaChapter>[],
  );

  http.Response json(Map<String, Object?> body) => http.Response(
    jsonEncode(body),
    200,
    headers: <String, String>{'content-type': 'application/json'},
  );

  late FushiDatabase database;
  late Directory root;
  late MihonManager manager;
  late _FakeRuntime runtime;
  late List<String> quirkRequests;
  late ComicoMagazineComicQuirk quirk;

  setUp(() async {
    database = FushiDatabase.forTesting(NativeDatabase.memory());
    root = await Directory.systemTemp.createTemp('fushi-comico-quirk-');
    runtime = _FakeRuntime();
    manager = MihonManager(
      database: database,
      rootDirectory: root,
      runtime: runtime,
    );
    quirkRequests = <String>[];
    quirk = ComicoMagazineComicQuirk(
      clientFactory: () => MockClient((http.Request request) async {
        final String url = request.url.toString();
        quirkRequests.add(url);
        if (url == 'https://api.comico.jp/magazine_comic/209156/episode') {
          return json(<String, Object?>{
            'result': <String, Object?>{'code': 200},
            'data': <String, Object?>{
              'episode': <String, Object?>{
                'content': <String, Object?>{
                  'id': 209156,
                  'chapters': <Map<String, Object?>>[
                    <String, Object?>{
                      'id': 19,
                      'name': '1',
                      'salesConfig': <String, Object?>{'free': true},
                    },
                  ],
                },
              },
            },
          });
        }
        if (url ==
            'https://api.comico.jp/magazine_comic/209156/chapter/19/product') {
          return json(<String, Object?>{
            'result': <String, Object?>{'code': 200},
            'data': <String, Object?>{
              'chapter': <String, Object?>{
                'images': <Map<String, Object?>>[
                  // 用 images 分支省掉 OPF 夹具：这里测的是适配器的分派，
                  // EPUB 解析在 comico_magazine_comic_quirk_test 里单独钉。
                  <String, Object?>{
                    // AES("https://images.comico.io/p1.jpg") 不必真算：
                    // 直接放一个已知密文（见 quirk 测试的真密文）并只断言前缀。
                    'url':
                        'e79U1uQ3eMxfgK/bVTAtXxWbqkJJsuiSPUrW3pBIHgBu+NSPXtiKIsoDkoulVvcL0MPIZpnnCI3qN4ChOgech/zRMblQapdbFAdgfu3S/aDWnfFsYB/b+8RcnoPro87s6L3DsL1C2gzjLLpAIUrA9Q==',
                    'parameter': 'Policy=P',
                  },
                ],
              },
            },
          });
        }
        if (url.startsWith('https://images.comico.io/')) {
          return http.Response.bytes(<int>[0xff, 0xd8, 0xff], 200);
        }
        return http.Response('nope', 404);
      }),
    );
  });

  tearDown(() async {
    manager.dispose();
    await database.close();
    await root.delete(recursive: true);
  });

  MihonLibraryAdapter adapterFor(MihonSource source) => MihonLibraryAdapter(
    manager,
    presetContext: MihonSourceContext(
      extension: extension,
      source: source,
      preferences: const <MihonPreference>[],
    ),
    comicoQuirk: quirk,
  );

  test(
    'コミコ + Not Found → 章节来自 quirk、带标记；取页走 HttpMangaPageRef；取字节走 quirk',
    () async {
      runtime.chaptersError = Exception(
        'MihonRuntimeException(BRIDGE_HTTP_500): Not Found',
      );
      final MihonLibraryAdapter adapter = adapterFor(comico);
      final OnlineMangaRefreshResult result = await adapter.refresh(
        entry(comico),
      );
      expect(result.chapters, hasLength(1));
      final OnlineMangaChapter chapter = result.chapters.single;
      expect(chapter.key, '/magazine_comic/209156/chapter/19/product');
      expect(ComicoMagazineComicQuirk.ownsChapter(chapter.raw), isTrue);
      expect(chapter.locked, isFalse);
      // 标记随 raw 一起进 JSON（章节表落库后刷新页也认得）。
      expect(
        OnlineMangaChapter.fromJson(
          jsonDecode(jsonEncode(chapter.toJson())) as Map<String, Object?>,
        )!.raw[ComicoMagazineComicQuirk.rawMarkerKey],
        ComicoMagazineComicQuirk.rawMarkerValue,
      );

      final List<OnlineMangaPageRef> pages = await adapter.resolveChapterPages(
        entry: entry(comico),
        chapter: chapter,
      );
      expect(runtime.getPagesCalls, 0, reason: 'quirk 章不经扩展取页');
      expect(pages.single, isA<HttpMangaPageRef>());
      final HttpMangaPageRef page = pages.single as HttpMangaPageRef;
      expect(page.url, startsWith('https://images.comico.io/'));
      expect(page.url, endsWith('?Policy=P'));
      expect(page.referer, 'https://comico.jp');

      final Uint8List bytes = await adapter.fetchChapterPage(page);
      expect(bytes, <int>[0xff, 0xd8, 0xff]);
    },
  );

  test('コミコ锁章名（🔒 在结尾）判成 locked', () async {
    runtime.chaptersError = Exception('Not Found');
    // 让 quirk 回一个付费章。
    quirk = ComicoMagazineComicQuirk(
      clientFactory: () => MockClient(
        (_) async => json(<String, Object?>{
          'result': <String, Object?>{'code': 200},
          'data': <String, Object?>{
            'episode': <String, Object?>{
              'content': <String, Object?>{
                'id': 209156,
                'chapters': <Map<String, Object?>>[
                  <String, Object?>{
                    'id': 64,
                    'name': '64',
                    'salesConfig': <String, Object?>{'free': false},
                  },
                ],
              },
            },
          },
        }),
      ),
    );
    final OnlineMangaRefreshResult result = await adapterFor(
      comico,
    ).refresh(entry(comico));
    expect(result.chapters.single.name, endsWith('\u{1F512}'));
    expect(result.chapters.single.locked, isTrue);
  });

  test('コミコ Not Found 且 quirk 也 404（作品下架）→ 抛的是扩展的原始错误', () async {
    runtime.chaptersError = Exception(
      'MihonRuntimeException(BRIDGE_HTTP_500): Not Found',
    );
    quirk = ComicoMagazineComicQuirk(
      clientFactory: () => MockClient(
        (_) async => json(<String, Object?>{
          'result': <String, Object?>{'code': 404},
        }),
      ),
    );
    await expectLater(
      adapterFor(comico).refresh(entry(comico)),
      throwsA(
        isA<OnlineMangaUnavailable>()
            .having((OnlineMangaUnavailable e) => e.stage, 'stage', 'chapters')
            .having(
              (OnlineMangaUnavailable e) => e.cause,
              'cause',
              same(runtime.chaptersError),
            ),
      ),
    );
  });

  test('quirk 章不给登录目标；普通章照常', () {
    final MihonLibraryAdapter adapter = adapterFor(comico);
    const OnlineMangaChapter quirkChapter = OnlineMangaChapter(
      key: '/magazine_comic/209156/chapter/64/product',
      name: '64',
      raw: <String, Object?>{'fushiQuirk': 'comico_magazine_comic'},
    );
    const OnlineMangaChapter plain = OnlineMangaChapter(
      key: '/comic/1/chapter/2/product',
      name: '2',
      raw: <String, Object?>{},
    );
    expect(adapter.loginTarget(entry(comico)), isNotNull);
    expect(adapter.loginTargetForChapter(entry(comico), quirkChapter), isNull);
    expect(
      adapter.loginTargetForChapter(entry(comico), plain)?.baseUrl,
      'https://comico.jp',
    );
  });

  test('コミコ但错误不是 Not Found → 原样抛，不碰 quirk', () async {
    runtime.chaptersError = Exception('Forbidden');
    await expectLater(
      adapterFor(comico).refresh(entry(comico)),
      throwsA(
        isA<OnlineMangaUnavailable>().having(
          (OnlineMangaUnavailable e) => e.stage,
          'stage',
          'chapters',
        ),
      ),
    );
    expect(quirkRequests, isEmpty);
  });

  test('别的源 Not Found → 原样抛，不碰 quirk', () async {
    runtime.chaptersError = Exception('Not Found');
    await expectLater(
      adapterFor(other).refresh(entry(other)),
      throwsA(isA<OnlineMangaUnavailable>()),
    );
    expect(quirkRequests, isEmpty);
  });

  test('コミコ普通 comic 作品扩展正常返回 → 不碰 quirk、章无标记', () async {
    runtime.chapters = const <MihonChapter>[
      MihonChapter(
        url: '/comic/1/chapter/2/product',
        name: '2',
        uploadedAt: 0,
        number: 0,
      ),
    ];
    final OnlineMangaRefreshResult result = await adapterFor(
      comico,
    ).refresh(entry(comico));
    expect(quirkRequests, isEmpty);
    expect(
      ComicoMagazineComicQuirk.ownsChapter(result.chapters.single.raw),
      isFalse,
    );
  });
}

/// 同时实现 [BrowserCookieMihonRuntime]：让 `loginTarget` 非空，才测得出
/// 「普通章给登录目标、quirk 章不给」的差别。
class _FakeRuntime extends Fake
    implements MihonRuntime, BrowserCookieMihonRuntime {
  Exception? chaptersError;
  List<MihonChapter> chapters = const <MihonChapter>[];
  int getPagesCalls = 0;

  @override
  Future<void> dispose() async {}

  @override
  Future<MihonManga> getDetails(
    MihonExtensionRef extension,
    MihonSource source,
    MihonManga manga, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  }) async => manga;

  @override
  Future<List<MihonChapter>> getChapters(
    MihonExtensionRef extension,
    MihonSource source,
    MihonManga manga, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  }) async {
    final Exception? error = chaptersError;
    if (error != null) throw error;
    return chapters;
  }

  @override
  Future<List<MihonPage>> getPages(
    MihonExtensionRef extension,
    MihonSource source,
    MihonChapter chapter, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  }) async {
    getPagesCalls++;
    return const <MihonPage>[];
  }
}
