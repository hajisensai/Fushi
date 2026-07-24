import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/scraper/collection_poster_store.dart';
import 'package:hibiki/src/media/video/video_storage.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  late CollectionPosterStore store;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('collection_poster_');
    store = CollectionPosterStore(tmp);
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('savePoster 原子落盘 collections/collection_<id>.jpg、不留 .tmp', () async {
    final String path = await store.savePoster(
      collectionId: 7,
      bytes: <int>[1, 2, 3],
    );
    expect(path, p.join(tmp.path, 'collections', 'collection_7.jpg'));
    expect(File(path).readAsBytesSync(), <int>[1, 2, 3]);
    expect(File('$path.tmp').existsSync(), isFalse);
    expect(await store.exists(7), isTrue);

    // 覆盖写：内容替换、仍无 .tmp 残留。
    await store.savePoster(collectionId: 7, bytes: <int>[9, 9]);
    expect(File(path).readAsBytesSync(), <int>[9, 9]);
    expect(File('$path.tmp').existsSync(), isFalse);
  });

  test('metaKey 形态：collection:<id>', () {
    expect(CollectionPosterStore.metaKey(42), 'collection:42');
  });

  test('remove：删文件与残留 .tmp；不存在为 no-op', () async {
    await store.savePoster(collectionId: 3, bytes: <int>[1]);
    await File('${store.fileFor(3).path}.tmp').writeAsBytes(<int>[0]);
    await store.remove(3);
    expect(await store.exists(3), isFalse);
    expect(File('${store.fileFor(3).path}.tmp').existsSync(), isFalse);
    await store.remove(999); // no-op 不抛。
  });

  test('gcOrphans：只删不在库的 collection_<id>.jpg，其余文件不碰', () async {
    await store.savePoster(collectionId: 1, bytes: <int>[1]);
    await store.savePoster(collectionId: 2, bytes: <int>[2]);
    // 非海报命名的文件与 .tmp 不参与 GC。
    final File stray = File(p.join(store.directory.path, 'notes.txt'));
    await stray.writeAsString('keep');
    final File tmpFile =
        File(p.join(store.directory.path, 'collection_9.jpg.tmp'));
    await tmpFile.writeAsBytes(<int>[0]);

    final List<int> removed =
        await store.gcOrphans(liveCollectionIds: <int>{1});
    expect(removed, <int>[2]);
    expect(await store.exists(1), isTrue);
    expect(await store.exists(2), isFalse);
    expect(stray.existsSync(), isTrue);
    expect(tmpFile.existsSync(), isTrue);
  });

  test('gcOrphans：目录不存在返回空', () async {
    expect(
      await CollectionPosterStore(Directory(p.join(tmp.path, 'nope')))
          .gcOrphans(liveCollectionIds: <int>{}),
      isEmpty,
    );
  });

  test('gcOrphanCovers（封面根 GC）不误删 collections/ 子目录里的合集海报', () async {
    // 封面根放一个孤儿封面 + collections/ 子目录放一张合集海报。
    final File orphanCover = File(p.join(tmp.path, 'orphan.jpg'));
    await orphanCover.writeAsBytes(<int>[1]);
    final String posterPath =
        await store.savePoster(collectionId: 5, bytes: <int>[2]);

    final int removed = await VideoStorage.gcOrphanCovers(
      referencedCoverPaths: const <String>[],
      coversDirectory: tmp,
    );
    expect(removed, 1, reason: '只删根目录孤儿封面');
    expect(orphanCover.existsSync(), isFalse);
    expect(File(posterPath).existsSync(), isTrue,
        reason: 'gcOrphanCovers 非递归且跳过目录项，合集海报不受波及');
  });
}
