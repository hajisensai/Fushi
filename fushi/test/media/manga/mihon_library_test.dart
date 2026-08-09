import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/media/manga/mihon/mihon_library.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/src/media/manga/mihon/mihon_runtime.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  late FushiDatabase database;
  late MihonManager manager;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('hibiki-mihon-library-');
    database = FushiDatabase.forTesting(NativeDatabase.memory());
    manager = MihonManager(
      database: database,
      rootDirectory: root,
      runtime: _LibraryRuntime(),
    );
    await manager.initialise();
  });

  tearDown(() async {
    manager.dispose();
    await database.close();
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('add and select chapter reuse manga shelf identity and progress',
      () async {
    const MihonManga manga = MihonManga(
      url: '/series/fixture',
      title: 'Fixture series',
      author: 'Fixture author',
      coverUrl: 'https://example.test/cover',
    );
    const List<MihonChapter> chapters = <MihonChapter>[
      MihonChapter(
        url: '/chapter/2',
        name: 'Chapter 2',
        uploadedAt: 2,
        number: 2,
      ),
      MihonChapter(
        url: '/chapter/1',
        name: 'Chapter 1',
        uploadedAt: 1,
        number: 1,
      ),
    ];
    const MihonSourceContext context = MihonSourceContext(
      extension: MihonExtensionRef(
        packageName: 'org.example.fixture',
        apkPath: 'fixture.ext',
      ),
      source: MihonSource(
        extensionPackage: 'org.example.fixture',
        id: '9223372036854775807',
        name: 'Fixture',
        language: 'en',
        baseUrl: 'https://example.test',
      ),
      preferences: <MihonPreference>[],
    );

    final MihonLibraryService service = MihonLibraryService(manager);
    final EpubBookRow row = await service.add(
      context: context,
      manga: manga,
      chapters: chapters,
    );

    expect(row.bookKey, startsWith('mihon-'));
    expect(row.format, 'manga');
    expect(row.coverPath, 'cover.png');
    expect(
        File('${row.extractDir}${Platform.pathSeparator}cover.png')
            .existsSync(),
        isTrue);
    final MihonLibraryEntry entry =
        MihonLibraryEntry.tryParse(row.sourceMetadata)!;
    expect(entry.sourceId, '9223372036854775807');
    expect(MihonLibraryService.initialChapterIndex(entry), 1);

    final MihonLibraryEntry selected = await service.selectChapter(
      bookKey: row.bookKey,
      entry: entry,
      chapterIndex: 1,
    );
    expect(selected.currentChapter?.name, 'Chapter 1');
    final ReaderPosition? position =
        await ReaderPositionRepository(database).findByBookKey(row.bookKey);
    expect(position?.sectionIndex, 0);

    final EpubBookRow addedAgain = await service.add(
      context: context,
      manga: manga,
      chapters: chapters,
    );
    expect(addedAgain.bookKey, row.bookKey);
    expect(await database.getAllEpubBooks(), hasLength(1));

    final Directory chapterCache =
        service.chapterDirectory(row.bookKey, chapters.last);
    expect(
      p.relative(chapterCache.path, from: root.path),
      startsWith(p.join('reader-cache', 'chapters', row.bookKey)),
    );
    expect(
      service.chapterDirectory(row.bookKey, chapters.last).path,
      chapterCache.path,
      reason: 'preview and shelf launches reuse the same chapter cache',
    );
  });
}

class _LibraryRuntime extends Fake implements MihonRuntime {
  @override
  Future<Uint8List> fetchSourceImage(
    MihonExtensionRef extension,
    MihonSource source,
    String url, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  }) async =>
      Uint8List.fromList(
        <int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a],
      );

  @override
  Future<void> dispose() async {}
}
