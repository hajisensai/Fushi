import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/media_source.dart';
import 'package:fushi/src/media/media_type.dart';
import 'package:fushi/src/media/metadata/book_metadata_scraper.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/media/types/reader_media_type.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/preferences_repository.dart';

import '../helpers/test_platform_services.dart';

/// 书的元数据刮削（路由 / 撤销 / 门面）测试共用的夹具：内存库 + 书族源注册 +
/// 离线 Bangumi + 假图片。

/// 只覆盖书架 / 刮削用到的 AppModel 面。
class BookMetaTestModel extends AppModel {
  BookMetaTestModel(this._db, this._prefs, this._thumbs)
    : super(testPlatformServices()) {
    mediaTypes = <String, MediaType>{
      ReaderMediaType.instance.uniqueKey: ReaderMediaType.instance,
    };
    mediaSources = <MediaType, Map<String, MediaSource>>{
      ReaderMediaType.instance: <String, MediaSource>{
        ReaderFushiSource.instance.uniqueKey: ReaderFushiSource.instance,
      },
    };
  }

  final FushiDatabase _db;
  final PreferencesRepository _prefs;
  final Directory _thumbs;

  /// 关掉的模块。
  final Set<ModuleId> disabled = <ModuleId>{};

  @override
  FushiDatabase get database => _db;

  @override
  PreferencesRepository get prefsRepo => _prefs;

  @override
  Directory get thumbnailsDirectory => _thumbs;

  @override
  bool get isMigrationReadonly => false;

  @override
  bool moduleEnabled(ModuleId module) => !disabled.contains(module);
}

/// 路由只用 `ref.read(appProvider)` 与刷新书架的 `invalidate`。
class BookMetaRef implements WidgetRef {
  BookMetaRef(this.model);

  final AppModel model;
  int invalidations = 0;

  @override
  T read<T>(ProviderListenable<T> provider) => model as T;

  @override
  void invalidate(ProviderOrFamily provider) => invalidations++;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('测试不该用到 ${invocation.memberName}');
}

/// 一张「完整可解码」的假 JPEG（过 `isDecodableImageBytes`：魔数 + EOI）；
/// [seed] 不同内容就不同。
List<int> fakeJpeg(int seed) => <int>[
  0xFF, 0xD8, 0xFF, 0xE0, //
  ...List<int>.filled(16, seed & 0xFF),
  0xFF, 0xD9,
];

/// 往书库插一本 EPUB，返回 bookKey。
Future<String> seedBook(
  FushiDatabase db,
  String bookKey, {
  String? author,
}) async {
  await db.insertEpubBook(
    EpubBooksCompanion.insert(
      bookKey: bookKey,
      title: bookKey,
      epubPath: '/x/$bookKey.epub',
      extractDir: '/x/$bookKey',
      chapterCount: 1,
      chaptersJson: '[]',
      importedAt: 1000,
      author: Value<String?>(author),
    ),
  );
  return bookKey;
}

/// 离线 Bangumi：`/v0/subjects/<id>` 回 [subjects] 里的条目（没有 → 404），搜索回
/// [searchHits]。
BookMetadataScraper offlineScraper({
  Map<String, Map<String, Object?>> subjects =
      const <String, Map<String, Object?>>{},
  List<Map<String, Object?>> searchHits = const <Map<String, Object?>>[],
}) => BookMetadataScraper(
  client: MockClient((http.Request req) async {
    final String path = req.url.path;
    if (path.contains('/search/subjects')) {
      return _json(<String, Object?>{'data': searchHits});
    }
    final String id = path.split('/').last;
    final Map<String, Object?>? subject = subjects[id];
    return subject == null ? http.Response('', 404) : _json(subject);
  }),
);

/// Bangumi 条目的最小 JSON。
Map<String, Object?> bangumiSubject(String id, String name, {String? cn}) =>
    <String, Object?>{
      'id': int.parse(id),
      'name': name,
      'name_cn': ?cn,
      'images': <String, Object?>{'large': 'https://img/$id.jpg'},
      'date': '2010-01-01',
    };

http.Response _json(Object body) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  200,
  headers: const <String, String>{'content-type': 'application/json'},
);

/// 下载桩：每个 URL 写一张不同的假图（URL 里的数字当种子）到 [dir]。
Future<File> Function(String url) fakeDownloader(Directory dir) =>
    (String url) async {
      final int seed = int.tryParse(RegExp(r'\d+').stringMatch(url) ?? '') ?? 7;
      final File f = File(
        p.join(dir.path, 'dl_${DateTime.now().microsecondsSinceEpoch}.jpg'),
      )..writeAsBytesSync(fakeJpeg(seed));
      return f;
    };
