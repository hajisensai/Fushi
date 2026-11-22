import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/manga/interconnect/interconnect_online_manga_host_reader.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_service.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi_core/fushi_core.dart';

/// BUG-4917 的互联 host 一侧：host 缓存最近几章的页表给对端逐页取图。桌面 sidecar
/// 一重启（装 / 更新 / 卸扩展），缓存里的取页引用整份作废；以前缓存原样留着，对端
/// 读这几章剩下的页一律失败，直到页表被 LRU 挤掉。
void main() {
  final OnlineMangaLibraryEntry entry = OnlineMangaLibraryEntry(
    runtime: OnlineMangaRuntimeKind.web,
    extensionPackage: 'example',
    sourceId: '1',
    series: const OnlineMangaSeries(
      key: '/series/1',
      title: 'Series',
      raw: <String, Object?>{'url': '/series/1', 'title': 'Series'},
    ),
    chapters: const <OnlineMangaChapter>[],
  );
  const OnlineMangaChapter chapter = OnlineMangaChapter(
    key: '/chapter/1',
    name: 'Chapter 1',
    raw: <String, Object?>{'url': '/chapter/1', 'name': 'Chapter 1'},
  );
  final String metadata = entry.encode();
  final Map<String, Object?> chapterJson = chapter.toJson();

  late FushiDatabase database;
  late Directory root;
  late _RestartingAdapter adapter;
  late InterconnectOnlineMangaHostReader reader;

  setUp(() async {
    database = FushiDatabase.forTesting(NativeDatabase.memory());
    root = await Directory.systemTemp.createTemp('fushi-host-reader-');
    adapter = _RestartingAdapter();
    final OnlineMangaLibraryService service = OnlineMangaLibraryService(
      database: database,
      rootDirectory: root,
      adapter: adapter,
    );
    reader = InterconnectOnlineMangaHostReader(
      (OnlineMangaRuntimeKind _) => service,
    );
  });

  tearDown(() async {
    await database.close();
    await root.delete(recursive: true);
  });

  Future<Uint8List> page(int index) => reader.chapterPage(
    bookKey: 'book',
    sourceMetadata: metadata,
    chapter: chapterJson,
    index: index,
  );

  Future<List<String?>> keys() => reader.chapterPageKeys(
    bookKey: 'book',
    sourceMetadata: metadata,
    chapter: chapterJson,
  );

  Future<int> count() async => (await keys()).length;

  test('页表缓存：同一章逐页取只解析一次', () async {
    expect(await count(), 3);
    expect(await page(0), _bytesFor(process: 1, index: 0));
    expect(await page(1), _bytesFor(process: 1, index: 1));
    expect(adapter.resolveCalls, 1);
  });

  test('sidecar 重启后缓存的页表换新引用，剩下的页照常取到', () async {
    expect(await page(0), _bytesFor(process: 1, index: 0));
    adapter.restart();
    expect(await page(1), _bytesFor(process: 2, index: 1));
    expect(await page(2), _bytesFor(process: 2, index: 2));
    expect(adapter.resolveCalls, 2, reason: '首次解析 + 重启后重解析一次');
  });

  test('重启后页数变了：这次按失败，缓存丢掉，对端重开按新页数取', () async {
    expect(await page(0), _bytesFor(process: 1, index: 0));
    adapter
      ..pageCount = 5
      ..restart();
    await expectLater(page(1), throwsA(isA<OnlineMangaUnavailable>()));
    expect(await count(), 5);
    expect(await page(4), _bytesFor(process: 2, index: 4));
  });

  test('页表报源端页身份，不随进程变（audit-035）', () async {
    final List<String?> before = await keys();
    expect(before, <String>[
      'https://cdn.example/v1/0.jpg',
      'https://cdn.example/v1/1.jpg',
      'https://cdn.example/v1/2.jpg',
    ]);
    adapter.restart();
    expect(await page(1), _bytesFor(process: 2, index: 1));
    expect(await keys(), before, reason: '重启只换取图引用，页身份不变');
  });

  test('重启后页数相同但源端换了页：按失败，缓存丢掉，对端按新页表重开（audit-035）', () async {
    expect(await page(0), _bytesFor(process: 1, index: 0));
    adapter
      ..version = 2
      ..restart();
    await expectLater(page(1), throwsA(isA<OnlineMangaUnavailable>()));
    expect(await keys(), <String>[
      'https://cdn.example/v2/0.jpg',
      'https://cdn.example/v2/1.jpg',
      'https://cdn.example/v2/2.jpg',
    ]);
    expect(await page(1), _bytesFor(process: 2, index: 1));
    expect(adapter.resolveCalls, 3, reason: '首次 + 重启后重解析 + 丢缓存后重开');
  });
}

Uint8List _bytesFor({required int process, required int index}) =>
    Uint8List.fromList(<int>[process, index]);

/// 页引用带发它的「进程号」，进程重启后旧引用报 [OnlineMangaPageRefExpired]
/// （与 MihonLibraryAdapter 对桌面 sidecar 的契约一致）。
class _RestartingAdapter extends Fake implements OnlineMangaRuntimeAdapter {
  int process = 1;
  int pageCount = 3;
  int resolveCalls = 0;

  /// 源端这一章的版本：变了 = 源端换了页图（页身份跟着变）。
  int version = 1;

  void restart() => process++;

  @override
  Future<List<OnlineMangaPageRef>> resolveChapterPages({
    required OnlineMangaLibraryEntry entry,
    required OnlineMangaChapter chapter,
  }) async {
    resolveCalls++;
    return <OnlineMangaPageRef>[
      for (int i = 0; i < pageCount; i++)
        HttpMangaPageRef(
          index: i,
          url: 'https://cdn.example/v$version/$i.jpg',
          referer: '',
          // 发引用的「进程号」借请求头带着；页身份只看源端地址。
          headers: <String, String>{'x-process': '$process'},
        ),
    ];
  }

  @override
  Future<Uint8List> fetchChapterPage(OnlineMangaPageRef page) async {
    final HttpMangaPageRef ref = page as HttpMangaPageRef;
    final int issuer = int.parse(ref.headers['x-process']!);
    if (issuer != process) {
      throw const OnlineMangaPageRefExpired('issued by a restarted process');
    }
    return _bytesFor(process: process, index: ref.index);
  }
}
