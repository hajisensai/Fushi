import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/manga/aidoku/aidoku_package_store.dart';
import 'package:fushi/src/media/manga/aidoku/aidoku_runtime.dart';
import 'package:fushi/src/media/manga/mihon/manga_page_provider.dart';
import 'package:fushi/src/media/manga/mihon/mihon_reader_chapter.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/net/app_http.dart';

const int _maximumAidokuImageBytes = 100 * 1024 * 1024;
const String kAidokuBrowserUserAgent =
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
    'AppleWebKit/537.36 (KHTML, like Gecko) '
    'Chrome/131.0 Safari/537.36';

class AidokuImagePage {
  const AidokuImagePage({
    required this.url,
    required this.headers,
    required this.context,
  });

  factory AidokuImagePage.fromJson(Map<String, Object?> json) {
    final Object? content = json['content'];
    if (content is! Map<Object?, Object?>) {
      throw const AidokuRuntimeException(
        'UNSUPPORTED_PAGE',
        'Aidoku returned a page without image content',
      );
    }
    final Object? urlValue = content['Url'];
    if (urlValue is! List<Object?> || urlValue.isEmpty) {
      throw const AidokuRuntimeException(
        'UNSUPPORTED_PAGE',
        'This Aidoku page type is not supported by the manga reader',
      );
    }
    final String originalUrl = urlValue.first?.toString().trim() ?? '';
    final String resolvedUrl = json['request_url']?.toString().trim() ?? '';
    final String url = resolvedUrl.isNotEmpty ? resolvedUrl : originalUrl;
    if (Uri.tryParse(url)?.isScheme('https') != true) {
      throw const AidokuRuntimeException(
        'INVALID_PAGE_URL',
        'Aidoku image pages must use HTTPS',
      );
    }
    final Object? context = urlValue.length > 1 ? urlValue[1] : null;
    final Object? requestHeaders = json['request_headers'];
    return AidokuImagePage(
      url: url,
      headers: requestHeaders is Map<Object?, Object?>
          ? requestHeaders.map(
              (Object? key, Object? value) =>
                  MapEntry<String, String>(key.toString(), value.toString()),
            )
          : const <String, String>{},
      context: context is Map<Object?, Object?>
          ? context.map(
              (Object? key, Object? value) =>
                  MapEntry<String, String>(key.toString(), value.toString()),
            )
          : const <String, String>{},
    );
  }

  final String url;
  final Map<String, String> headers;
  final Map<String, String> context;

  Map<String, String> requestHeaders({String? referer}) {
    final Map<String, String> resolved = <String, String>{
      'User-Agent': kAidokuBrowserUserAgent,
      if (referer != null) 'Referer': referer,
      ...headers,
    };
    return resolved.map(
      (String name, String value) => MapEntry<String, String>(
        name,
        _normalizeAidokuRequestHeader(name, value),
      ),
    );
  }

  String get identity {
    final List<String> keys = headers.keys.toList()..sort();
    final Map<String, String> stableHeaders = <String, String>{
      for (final String key in keys) key: headers[key]!,
    };
    return sha256
        .convert(utf8.encode('$url\u001f${jsonEncode(stableHeaders)}'))
        .toString();
  }
}

String _normalizeAidokuRequestHeader(String name, String value) {
  switch (name.toLowerCase()) {
    case 'referer':
    case 'origin':
      final Uri? uri = Uri.tryParse(value);
      if (uri != null && (uri.isScheme('http') || uri.isScheme('https'))) {
        // dart:io rejects non-Latin-1 header values before sending a request.
        // Uri.toString percent-encodes Unicode path/query components while
        // preserving an already valid HTTP URL.
        return uri.toString();
      }
  }
  return value;
}

class AidokuReaderChapter extends OnlineMangaReaderChapter {
  AidokuReaderChapter({
    required this.package,
    required this.manga,
    required this.chapter,
    required this.pages,
  }) : managedDirectory = Directory(
          p.join(
            p.dirname(package.packagePath),
            '.reader-cache',
            sha256
                .convert(
                  utf8.encode(
                    '${package.id}\u001f${manga['key']}\u001f${chapter['key']}',
                  ),
                )
                .toString(),
          ),
        );

  final AidokuInstalledPackage package;
  final Map<String, Object?> manga;
  final Map<String, Object?> chapter;
  final List<AidokuImagePage> pages;

  @override
  final Directory managedDirectory;

  @override
  bool get persistProgress => false;

  @override
  int? get initialPage => null;

  @override
  String get title => manga['title']?.toString() ?? package.name;

  @override
  String? get sourceLanguage {
    // Aidoku manifest 是语言列表；只有单语言源能给出确定答案。
    return package.languages.length == 1 ? package.languages.single : null;
  }

  @override
  String? get author {
    final List<Object?> authors =
        manga['authors'] as List<Object?>? ?? const <Object?>[];
    return authors.isEmpty ? null : authors.join(', ');
  }

  @override
  int get pageCount => pages.length;

  @override
  List<String> get pageIdentities => pages
      .map((AidokuImagePage page) => page.identity)
      .toList(growable: false);

  @override
  String get identityFileName => '.aidoku-chapter.json';

  @override
  Future<MangaReaderSession> openPageSession() => AidokuMangaPageProvider(
        pages: pages,
        cacheRoot: Directory(
          p.join(p.dirname(package.packagePath), '.page-cache'),
        ),
        referer: _httpsUrl(manga['url']),
      ).open();
}

String? _httpsUrl(Object? value) {
  final String candidate = value?.toString().trim() ?? '';
  return Uri.tryParse(candidate)?.isScheme('https') == true ? candidate : null;
}

class AidokuMangaPageProvider implements MangaPageProvider {
  const AidokuMangaPageProvider({
    required this.pages,
    required this.cacheRoot,
    this.referer,
  });

  final List<AidokuImagePage> pages;
  final Directory cacheRoot;
  final String? referer;

  @override
  Future<MangaReaderSession> open() async {
    await cacheRoot.create(recursive: true);
    return _AidokuMangaReaderSession(
      pages: pages,
      cacheRoot: cacheRoot,
      client: createAppHttpIoClient(),
      referer: referer,
    );
  }
}

class _AidokuMangaReaderSession implements MangaReaderSession {
  _AidokuMangaReaderSession({
    required this.pages,
    required this.cacheRoot,
    required this.client,
    required this.referer,
  });

  final List<AidokuImagePage> pages;
  final Directory cacheRoot;
  final http.Client client;
  final String? referer;
  final Map<int, Future<File>> _inFlight = <int, Future<File>>{};
  bool _closed = false;

  @override
  int get pageCount => pages.length;

  @override
  Future<MangaPageBytes> page(int index) async {
    final File file = await _file(index);
    final Uint8List bytes = await file.readAsBytes();
    final ({int width, int height})? dimensions =
        await mangaImageDimensions(bytes);
    return MangaPageBytes(
      bytes: bytes,
      contentType: mangaImageContentType(bytes),
      width: dimensions?.width,
      height: dimensions?.height,
    );
  }

  @override
  Future<File?> localFile(int index) => _file(index);

  @override
  String cacheIdentity(int index) => _page(index).identity;

  @override
  Future<void> prefetchAround(int index) async {
    final List<Future<File>> work = <Future<File>>[];
    for (int candidate = index - 2; candidate <= index + 2; candidate++) {
      if (candidate >= 0 && candidate < pages.length && candidate != index) {
        work.add(_file(candidate));
      }
    }
    await Future.wait<File>(work);
  }

  AidokuImagePage _page(int index) {
    if (_closed) {
      throw const AidokuRuntimeException(
        'SESSION_CLOSED',
        'The Aidoku reader session is closed',
      );
    }
    if (index < 0 || index >= pages.length) {
      throw RangeError.index(index, pages, 'index');
    }
    return pages[index];
  }

  Future<File> _file(int index) {
    _page(index);
    return _inFlight.putIfAbsent(index, () async {
      try {
        final AidokuImagePage page = pages[index];
        final File target =
            File(p.join(cacheRoot.path, '${page.identity}.img'));
        if (await target.exists() && await target.length() > 0) return target;
        final http.Request request = http.Request('GET', Uri.parse(page.url));
        request.headers.addAll(page.requestHeaders(referer: referer));
        final http.StreamedResponse response = await client.send(request);
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw AidokuRuntimeException(
            'IMAGE_HTTP_${response.statusCode}',
            'Aidoku image request returned HTTP ${response.statusCode}',
          );
        }
        final BytesBuilder bytes = BytesBuilder(copy: false);
        int length = 0;
        await for (final List<int> chunk in response.stream) {
          length += chunk.length;
          if (length > _maximumAidokuImageBytes) {
            throw const AidokuRuntimeException(
              'IMAGE_TOO_LARGE',
              'Aidoku image exceeded the 100 MiB limit',
            );
          }
          bytes.add(chunk);
        }
        if (length == 0) {
          throw const AidokuRuntimeException(
            'IMAGE_EMPTY',
            'Aidoku image response was empty',
          );
        }
        final File staged = File('${target.path}.tmp');
        await staged.writeAsBytes(bytes.takeBytes(), flush: true);
        await staged.rename(target.path);
        return target;
      } on Object catch (error, stack) {
        ErrorLogService.instance.log(
          'AidokuReader.image[$index] ${pages[index].url}',
          error,
          stack,
        );
        rethrow;
      } finally {
        _inFlight.remove(index);
      }
    });
  }

  @override
  Future<void> close() async {
    _closed = true;
    client.close();
  }
}
