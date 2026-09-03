import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/manga/aidoku/aidoku_repository_client.dart';
import 'package:fushi/src/media/manga/aidoku/aidoku_repository_store.dart';

void main() {
  late Directory root;
  late AidokuRepositoryStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fushi-aidoku-repos-');
    store = AidokuRepositoryStore(File('${root.path}/repositories.json'));
  });

  tearDown(() async {
    await root.delete(recursive: true);
  });

  AidokuRepositoryIndex index(String name) => AidokuRepositoryIndex(
        name: name,
        indexUri: Uri.parse('https://example.com/index.min.json'),
        sources: <AidokuRepositorySource>[
          AidokuRepositorySource(
            id: 'en.example',
            name: 'Example',
            version: 1,
            languages: const <String>['en'],
            downloadUri: Uri.parse('https://example.com/source.aix'),
          ),
        ],
      );

  test('persists, updates, and removes repositories by canonical URL',
      () async {
    await store.add(index('First name'));
    await store.add(index('Updated name'));

    final List<AidokuSavedRepository> saved = await store.list();
    expect(saved, hasLength(1));
    expect(saved.single.name, 'Updated name');
    expect(saved.single.indexUrl, 'https://example.com/index.min.json');

    await store.remove(saved.single);
    expect(await store.list(), isEmpty);
  });

  test('ignores a damaged repository metadata file', () async {
    await store.file.parent.create(recursive: true);
    await store.file.writeAsString('{not json');

    expect(await store.list(), isEmpty);
  });
}
