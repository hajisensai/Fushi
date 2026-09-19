import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/src/media/manga/mihon/mihon_runtime.dart';
import 'package:fushi/src/media/manga/mihon/mihon_web_url.dart';

/// 详情页「在网站打开」的地址解析：先问扩展（`getMangaUrl` / `getAnimeUrl`），
/// 扩展给不出就 `baseUrl + url`，两条路都没有才是 null。
void main() {
  const MihonExtensionRef extension = MihonExtensionRef(
    packageName: 'org.example.fixture',
    apkPath: 'fixture.apk',
  );
  MihonSourceContext context({String baseUrl = 'https://site.example'}) =>
      MihonSourceContext(
        extension: extension,
        source: MihonSource(
          extensionPackage: 'org.example.fixture',
          id: '1',
          name: 'Fixture',
          language: 'en',
          baseUrl: baseUrl,
        ),
        preferences: const <MihonPreference>[],
      );
  const MihonManga manga = MihonManga(url: '/manga/1', title: 'M');
  const MihonAnime anime = MihonAnime(url: '/anime/1', title: 'A');

  group('mihonWebUrlFallback', () {
    test('joins baseUrl and a relative url with exactly one slash', () {
      expect(
        mihonWebUrlFallback(baseUrl: 'https://s.example', url: '/m/1'),
        Uri.parse('https://s.example/m/1'),
      );
      expect(
        mihonWebUrlFallback(baseUrl: 'https://s.example/', url: '/m/1'),
        Uri.parse('https://s.example/m/1'),
      );
      expect(
        mihonWebUrlFallback(baseUrl: 'https://s.example', url: 'm/1'),
        Uri.parse('https://s.example/m/1'),
      );
    });

    test('an absolute url is used as-is regardless of baseUrl', () {
      expect(
        mihonWebUrlFallback(baseUrl: '', url: 'https://other.example/x'),
        Uri.parse('https://other.example/x'),
      );
    });

    test('no baseUrl and a relative url is null, not a bogus uri', () {
      expect(mihonWebUrlFallback(baseUrl: '', url: '/m/1'), isNull);
      expect(mihonWebUrlFallback(baseUrl: '   ', url: ''), isNull);
    });

    test('an empty url falls back to the site root', () {
      expect(
        mihonWebUrlFallback(baseUrl: 'https://s.example', url: ''),
        Uri.parse('https://s.example'),
      );
    });
  });

  group('mihonWebUrlOrNull', () {
    test('accepts only http(s) with a host', () {
      expect(mihonWebUrlOrNull('https://s.example/a'), isNotNull);
      expect(mihonWebUrlOrNull('http://s.example'), isNotNull);
      expect(mihonWebUrlOrNull(''), isNull);
      expect(mihonWebUrlOrNull('null'), isNull);
      expect(mihonWebUrlOrNull('/relative'), isNull);
      expect(mihonWebUrlOrNull('file:///etc/passwd'), isNull);
      expect(mihonWebUrlOrNull('javascript:alert(1)'), isNull);
      expect(mihonWebUrlOrNull(null), isNull);
    });
  });

  group('resolveMihonMangaWebUrl / resolveMihonAnimeWebUrl', () {
    test('prefers what the extension reports', () async {
      final _WebUrlRuntime runtime = _WebUrlRuntime(
        mangaUrl: 'https://site.example/series/one',
        animeUrl: 'https://site.example/watch/one',
      );
      expect(
        await resolveMihonMangaWebUrl(
          runtime: runtime,
          context: context(),
          manga: manga,
        ),
        Uri.parse('https://site.example/series/one'),
      );
      expect(
        await resolveMihonAnimeWebUrl(
          runtime: runtime,
          context: context(),
          anime: anime,
        ),
        Uri.parse('https://site.example/watch/one'),
      );
      expect(runtime.mangaRequests, <String>['/manga/1']);
      expect(runtime.animeRequests, <String>['/anime/1']);
    });

    test('falls back to baseUrl + url when the extension throws', () async {
      final _WebUrlRuntime runtime = _WebUrlRuntime(
        failure: StateError('NoSuchMethodError: getMangaUrl'),
      );
      expect(
        await resolveMihonMangaWebUrl(
          runtime: runtime,
          context: context(),
          manga: manga,
        ),
        Uri.parse('https://site.example/manga/1'),
      );
      expect(
        await resolveMihonAnimeWebUrl(
          runtime: runtime,
          context: context(),
          anime: anime,
        ),
        Uri.parse('https://site.example/anime/1'),
      );
    });

    test('falls back when the extension returns something unusable', () async {
      final _WebUrlRuntime runtime = _WebUrlRuntime(
        mangaUrl: '',
        animeUrl: 'null',
      );
      expect(
        await resolveMihonMangaWebUrl(
          runtime: runtime,
          context: context(),
          manga: manga,
        ),
        Uri.parse('https://site.example/manga/1'),
      );
      expect(
        await resolveMihonAnimeWebUrl(
          runtime: runtime,
          context: context(),
          anime: anime,
        ),
        Uri.parse('https://site.example/anime/1'),
      );
    });

    test(
      'a runtime without the capability goes straight to the join',
      () async {
        expect(
          await resolveMihonMangaWebUrl(
            runtime: Object(),
            context: context(),
            manga: manga,
          ),
          Uri.parse('https://site.example/manga/1'),
        );
      },
    );

    test(
      'nothing to open when neither the extension nor baseUrl help',
      () async {
        final _WebUrlRuntime runtime = _WebUrlRuntime(failure: StateError('x'));
        expect(
          await resolveMihonMangaWebUrl(
            runtime: runtime,
            context: context(baseUrl: ''),
            manga: manga,
          ),
          isNull,
        );
      },
    );
  });
}

class _WebUrlRuntime implements MihonWebUrlRuntime {
  _WebUrlRuntime({this.mangaUrl, this.animeUrl, this.failure});

  final String? mangaUrl;
  final String? animeUrl;
  final Error? failure;
  final List<String> mangaRequests = <String>[];
  final List<String> animeRequests = <String>[];

  @override
  Future<String> getMangaWebUrl(
    MihonExtensionRef extension,
    MihonSource source,
    MihonManga manga, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  }) async {
    mangaRequests.add(manga.url);
    if (failure != null) throw failure!;
    return mangaUrl ?? '';
  }

  @override
  Future<String> getAnimeWebUrl(
    MihonExtensionRef extension,
    MihonSource source,
    MihonAnime anime, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  }) async {
    animeRequests.add(anime.url);
    if (failure != null) throw failure!;
    return animeUrl ?? '';
  }
}
