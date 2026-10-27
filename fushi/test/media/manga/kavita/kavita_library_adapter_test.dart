import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fushi/src/media/kavita/kavita_server_config.dart';
import 'package:fushi/src/media/manga/kavita/kavita_library_adapter.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_service.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi_engine/media/kavita/kavita_api.dart';
import 'package:fushi_engine/media/kavita/kavita_models.dart';

const String _kApiKey = 'SECRETKEY-0123456789abcdef';

KavitaServerConfig _server({
  String id = 'srv-1',
  bool enabled = true,
  String apiKey = _kApiKey,
}) => KavitaServerConfig(
  id: id,
  name: 'Home',
  serverUrl: Uri.parse('https://kavita.test'),
  apiKey: apiKey,
  enabled: enabled,
);

KavitaSeries _series({int id = 42, int format = KavitaFormat.archive}) =>
    KavitaSeries.fromJson(<String, Object?>{
      'id': id,
      'name': 'Series $id',
      'libraryId': 1,
      'format': format,
      'pages': 100,
      'pagesRead': 0,
    });

final Map<String, Object?> _detailJson = <String, Object?>{
  'volumes': <Object?>[
    <String, Object?>{
      'id': 10,
      'name': '1',
      'minNumber': 1,
      'chapters': <Object?>[
        <String, Object?>{
          'id': 101,
          'range': '-100000',
          'minNumber': -100000,
          'sortOrder': 1,
          'pages': 20,
        },
      ],
    },
    <String, Object?>{
      'id': 11,
      'name': '-100000',
      'minNumber': -100000,
      'chapters': <Object?>[
        <String, Object?>{
          'id': 201,
          'range': '5',
          'minNumber': 5,
          'sortOrder': 5,
          'pages': 18,
        },
        <String, Object?>{
          'id': 202,
          'range': '6',
          'minNumber': 6,
          'sortOrder': 6,
          'pages': 19,
        },
      ],
    },
  ],
  'specials': <Object?>[
    <String, Object?>{
      'id': 301,
      'isSpecial': true,
      'title': 'Extra',
      'range': 'Extra',
      'sortOrder': 1000,
      'pages': 4,
    },
  ],
  // 与 volumes 里重复的章应被去重。
  'chapters': <Object?>[
    <String, Object?>{'id': 201, 'range': '5', 'sortOrder': 5},
  ],
};

class _Fixture {
  _Fixture({this.seriesFormat = KavitaFormat.archive, this.handler});

  final int seriesFormat;
  final Future<http.Response> Function(http.Request request)? handler;
  final List<Uri> requests = <Uri>[];

  late final MockClient client = MockClient((http.Request request) async {
    requests.add(request.url);
    final Future<http.Response> Function(http.Request)? custom = handler;
    if (custom != null) return custom(request);
    final String path = request.url.path;
    if (path == '/api/Plugin/authenticate') {
      return http.Response(jsonEncode(<String, Object?>{'token': 'jwt'}), 200);
    }
    if (path == '/api/Series/42') {
      return http.Response(
        jsonEncode(<String, Object?>{
          'id': 42,
          'name': 'Series 42',
          'localizedName': 'Localized 42',
          'libraryId': 1,
          'format': seriesFormat,
        }),
        200,
      );
    }
    if (path == '/api/Series/series-detail') {
      return http.Response(jsonEncode(_detailJson), 200);
    }
    if (path == '/api/Reader/chapter-info') {
      return http.Response(
        jsonEncode(<String, Object?>{
          'pages': 3,
          'seriesId': 42,
          'volumeId': 11,
          'libraryId': 1,
          'seriesFormat': 1,
        }),
        200,
      );
    }
    if (path == '/api/Reader/image') {
      final String page = request.url.queryParameters['page'] ?? '';
      return http.Response.bytes(<int>[0xff, 0xd8, 0xff, int.parse(page)], 200);
    }
    if (path == '/api/Image/series-cover') {
      return http.Response.bytes(<int>[
        0x89,
        0x50,
        0x4e,
        0x47,
        1,
        2,
        3,
        4,
      ], 200);
    }
    return http.Response('not found', 404);
  });

  late final KavitaApi api = KavitaApi(
    serverUrl: 'https://kavita.test',
    apiKey: _kApiKey,
    client: client,
  );

  KavitaLibraryAdapter adapter({List<KavitaServerConfig>? servers}) =>
      KavitaLibraryAdapter(
        servers: () => servers ?? <KavitaServerConfig>[_server()],
        apiFor: (KavitaServerConfig _) => api,
      );
}

OnlineMangaLibraryEntry _entry({String serverId = 'srv-1'}) =>
    KavitaLibraryAdapter.entryFor(
      server: _server(id: serverId),
      series: _series(),
    );

void _expectNoKey(OnlineMangaUnavailable error) {
  for (final String text in <String>[
    error.message,
    error.diagnostics,
    error.userMessage,
    error.toString(),
  ]) {
    expect(text, isNot(contains(_kApiKey)));
  }
}

void main() {
  group('OnlineMangaRuntimeKind.kavita', () {
    test('wire 值冻结为 kavita，且可往返', () {
      expect(OnlineMangaRuntimeKind.kavita.wireValue, 'kavita');
      expect(
        OnlineMangaRuntimeKind.fromWire('kavita'),
        OnlineMangaRuntimeKind.kavita,
      );
      // 既有值不受影响。
      expect(
        <String>[
          for (final OnlineMangaRuntimeKind kind
              in OnlineMangaRuntimeKind.values)
            kind.wireValue,
        ],
        <String>['mihon', 'aidoku', 'interconnect', 'web', 'kavita'],
      );
    });

    test('描述符往返保留 runtime，且不含 API key / 带 key 的 URL', () {
      final OnlineMangaLibraryEntry entry = _entry();
      final String encoded = entry.encode();
      expect(encoded, isNot(contains(_kApiKey)));
      expect(encoded, isNot(contains('apiKey')));
      final OnlineMangaLibraryEntry? parsed = OnlineMangaLibraryEntry.tryParse(
        encoded,
      );
      expect(parsed, isNotNull);
      expect(parsed!.runtime, OnlineMangaRuntimeKind.kavita);
      expect(parsed.extensionPackage, kKavitaMangaPackage);
      expect(parsed.sourceId, 'srv-1');
      expect(parsed.series.key, '42');
      expect(parsed.series.coverUrl, 'kavita-cover:42');
    });
  });

  group('书架键推导', () {
    test('只由服务器配置 id + seriesId 决定，稳定且与 bookKeyOf 一致', () {
      final String key = KavitaLibraryAdapter.localBookKeyFor(
        serverConfigId: 'srv-1',
        seriesId: 42,
      );
      expect(key, startsWith('kavita-'));
      expect(
        key,
        KavitaLibraryAdapter.localBookKeyFor(
          serverConfigId: 'srv-1',
          seriesId: 42,
        ),
      );
      expect(OnlineMangaLibraryService.bookKeyOf(_entry()), key);
      // 标题变化不影响身份。
      final OnlineMangaLibraryEntry renamed = _entry().copyWith(
        series: const OnlineMangaSeries(
          key: '42',
          title: 'Completely different title',
          raw: <String, Object?>{},
        ),
      );
      expect(OnlineMangaLibraryService.bookKeyOf(renamed), key);
    });

    test('不同服务器 / 不同系列不撞键', () {
      final String a = KavitaLibraryAdapter.localBookKeyFor(
        serverConfigId: 'srv-1',
        seriesId: 42,
      );
      expect(
        KavitaLibraryAdapter.localBookKeyFor(
          serverConfigId: 'srv-2',
          seriesId: 42,
        ),
        isNot(a),
      );
      expect(
        KavitaLibraryAdapter.localBookKeyFor(
          serverConfigId: 'srv-1',
          seriesId: 43,
        ),
        isNot(a),
      );
    });
  });

  group('KavitaMangaPageRef', () {
    test('JSON 往返，sourceUrl 恒 null（不泄露带 key 的图片 URL）', () {
      const KavitaMangaPageRef ref = KavitaMangaPageRef(
        index: 7,
        serverConfigId: 'srv-1',
        chapterId: 201,
        page: 7,
      );
      final Map<String, Object?> json =
          (jsonDecode(jsonEncode(ref.toJson())) as Map<Object?, Object?>)
              .cast<String, Object?>();
      final KavitaMangaPageRef? back = KavitaMangaPageRef.fromJson(json);
      expect(back, isNotNull);
      expect(back!.index, 7);
      expect(back.serverConfigId, 'srv-1');
      expect(back.chapterId, 201);
      expect(back.page, 7);
      expect(back.sourceUrl, isNull);
      expect(
        KavitaMangaPageRef.fromJson(const <String, Object?>{'index': 1}),
        isNull,
      );
    });
  });

  group('refresh', () {
    test('volumes / chapters / specials 摊平去重，最新在前', () async {
      final _Fixture fixture = _Fixture();
      final OnlineMangaRefreshResult result = await fixture.adapter().refresh(
        _entry(),
      );
      expect(result.series.key, '42');
      expect(result.series.title, 'Localized 42');
      expect(result.series.coverUrl, 'kavita-cover:42');
      expect(
        result.chapters.map((OnlineMangaChapter c) => c.key).toList(),
        <String>['301', '202', '201', '101'],
      );
      expect(
        result.chapters.map((OnlineMangaChapter c) => c.name).toList(),
        <String>['Extra', 'Ch. 6', 'Ch. 5', 'Vol. 1'],
      );
      expect(
        result.chapters.map((OnlineMangaChapter c) => c.number).toList(),
        <double?>[null, 6, 5, 1],
      );
      expect(result.chapters.last.raw['volumeId'], 10);
    });

    test('EPUB / PDF 系列不收，报 platformUnsupported', () async {
      for (final int format in <int>[KavitaFormat.epub, KavitaFormat.pdf]) {
        final _Fixture fixture = _Fixture(seriesFormat: format);
        await expectLater(
          fixture.adapter().refresh(_entry()),
          throwsA(
            isA<OnlineMangaUnavailable>().having(
              (OnlineMangaUnavailable e) => e.reason,
              'reason',
              OnlineMangaUnavailableReason.platformUnsupported,
            ),
          ),
        );
        expect(
          fixture.requests.any(
            (Uri u) => u.path == '/api/Series/series-detail',
          ),
          isFalse,
        );
      }
    });

    test('服务器被删 / 停用 / 没 key → sourceDisabled，且不发请求', () async {
      for (final List<KavitaServerConfig> servers in <List<KavitaServerConfig>>[
        <KavitaServerConfig>[],
        <KavitaServerConfig>[_server(enabled: false)],
        <KavitaServerConfig>[_server(apiKey: '')],
      ]) {
        final _Fixture fixture = _Fixture();
        await expectLater(
          fixture.adapter(servers: servers).refresh(_entry()),
          throwsA(
            isA<OnlineMangaUnavailable>().having(
              (OnlineMangaUnavailable e) => e.reason,
              'reason',
              OnlineMangaUnavailableReason.sourceDisabled,
            ),
          ),
        );
        expect(fixture.requests, isEmpty);
      }
    });
  });

  group('取页 / 封面', () {
    test('resolveChapterPages 按 chapter-info.pages 造引用', () async {
      final _Fixture fixture = _Fixture();
      final KavitaLibraryAdapter adapter = fixture.adapter();
      final List<OnlineMangaPageRef> pages = await adapter.resolveChapterPages(
        entry: _entry(),
        chapter: const OnlineMangaChapter(
          key: '201',
          name: 'Ch. 5',
          raw: <String, Object?>{},
        ),
      );
      expect(pages, hasLength(3));
      for (int i = 0; i < pages.length; i++) {
        final KavitaMangaPageRef ref = pages[i] as KavitaMangaPageRef;
        expect(ref.index, i);
        expect(ref.page, i);
        expect(ref.chapterId, 201);
        expect(ref.serverConfigId, 'srv-1');
      }
      final Uint8List bytes = await adapter.fetchChapterPage(pages[2]);
      expect(bytes, <int>[0xff, 0xd8, 0xff, 2]);
    });

    test('fetchCover 走 seriesId 取字节', () async {
      final _Fixture fixture = _Fixture();
      final List<int> bytes = await fixture.adapter().fetchCover(
        _entry(),
        'kavita-cover:42',
      );
      expect(bytes.take(4), <int>[0x89, 0x50, 0x4e, 0x47]);
      expect(fixture.requests.last.queryParameters['seriesId'], '42');
    });

    test('拒绝别的运行时的页引用', () async {
      final _Fixture fixture = _Fixture();
      await expectLater(
        fixture.adapter().fetchChapterPage(
          const InterconnectMangaPageRef(
            index: 0,
            bookKey: 'x',
            remoteIndex: 0,
          ),
        ),
        throwsArgumentError,
      );
    });
  });

  group('错误映射不泄露 API key', () {
    test('401 / 403 → runtimeFailure，文案不含 key', () async {
      for (final int status in <int>[401, 403]) {
        final _Fixture fixture = _Fixture(
          handler: (http.Request request) async => http.Response('', status),
        );
        try {
          await fixture.adapter().refresh(_entry());
          fail('expected OnlineMangaUnavailable');
        } on OnlineMangaUnavailable catch (error) {
          expect(error.reason, OnlineMangaUnavailableReason.runtimeFailure);
          expect(error.message, contains('$status'));
          _expectNoKey(error);
        }
      }
    });

    test('网络异常（URL 带 apiKey）被脱敏', () async {
      final _Fixture fixture = _Fixture(
        handler: (http.Request request) async =>
            throw http.ClientException('Connection refused', request.url),
      );
      try {
        await fixture.adapter().fetchChapterPage(
          const KavitaMangaPageRef(
            index: 0,
            serverConfigId: 'srv-1',
            chapterId: 201,
            page: 0,
          ),
        );
        fail('expected OnlineMangaUnavailable');
      } on OnlineMangaUnavailable catch (error) {
        expect(error.reason, OnlineMangaUnavailableReason.runtimeFailure);
        expect(error.stage, 'pages');
        _expectNoKey(error);
      }
    });

    test('5xx → runtimeFailure（可重试）', () async {
      final _Fixture fixture = _Fixture(
        handler: (http.Request request) async =>
            request.url.path == '/api/Plugin/authenticate'
            ? http.Response(jsonEncode(<String, Object?>{'token': 'j'}), 200)
            : http.Response('boom', 500),
      );
      try {
        await fixture.adapter().refresh(_entry());
        fail('expected OnlineMangaUnavailable');
      } on OnlineMangaUnavailable catch (error) {
        expect(error.reason, OnlineMangaUnavailableReason.runtimeFailure);
        expect(error.stage, 'details');
        _expectNoKey(error);
      }
    });

    test('redactKavitaErrorText 兜底替换 key 原文', () {
      final String text = redactKavitaErrorText(
        'weird error mentioning $_kApiKey and https://h/x?apiKey=$_kApiKey',
        _kApiKey,
      );
      expect(text, isNot(contains(_kApiKey)));
    });
  });
}
