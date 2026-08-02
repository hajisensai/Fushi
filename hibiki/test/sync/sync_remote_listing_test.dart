import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/sync_asset_store.dart';
import 'package:hibiki/src/sync/sync_file_ref.dart';
import 'package:hibiki/src/sync/sync_remote_listing.dart';

// 一次性远端列举快照（TODO-2656）。
//
// 这一层唯一的职责是：把「一次拿来的全部文件名」按文件夹归位，并给出与
// `SyncBackend.listSyncFiles` **完全同义**的三件套。它不做任何「变没变」的判断——
// 正因为不判断，就没有「判断错了会漏同步」这个风险类别。所以测试盯的是同义性和
// 归位的边界，而不是什么跳过策略。

void main() {
  group('三件套与逐本列举同义', () {
    test('按 canonical 前缀挑出 progress / statistics / audioBook', () {
      final RemoteListingBuilder b = RemoteListingBuilder();
      b.addFolder('Book A');
      // 无关文件**排在最前**：三件套必须靠前缀认出来，而不是靠位置蒙对。按顺序取
      // 第一个的实现会在这里立刻露馅。
      b.addEntry(parentName: 'Book A', name: 'Book A.epub', id: 'e1');
      b.addEntry(parentName: 'Book A', name: 'cover_1_6.jpg', id: 'c1');
      b.addEntry(parentName: 'Book A', name: 'tags.json', id: 't1');
      b.addEntry(
          parentName: 'Book A', name: 'audioBook_1_6_1000_12.0.json', id: 'a1');
      b.addEntry(
          parentName: 'Book A', name: 'statistics_1_6_1000.json', id: 's1');
      b.addEntry(
          parentName: 'Book A', name: 'progress_1_6_1000_0.5.json', id: 'p1');

      final SyncFileTrio trio = b.build().trioFor('Book A');
      expect(trio.progress?.id, 'p1');
      expect(trio.progress?.name, 'progress_1_6_1000_0.5.json');
      expect(trio.statistics?.id, 's1');
      expect(trio.audioBook?.id, 'a1');
    });

    test('远端没有这本书 → 空三件套（与列举一个不存在的文件夹同义）', () {
      final RemoteListingSnapshot s = RemoteListingBuilder().build();
      final SyncFileTrio trio = s.trioFor('Missing');
      expect(trio.progress, isNull);
      expect(trio.statistics, isNull);
      expect(trio.audioBook, isNull);
    });

    test('文件夹在但还空着 → 同样是空三件套，但与「不存在」可区分', () {
      final RemoteListingBuilder b = RemoteListingBuilder();
      b.addFolder('Empty Book');
      final RemoteListingSnapshot s = b.build();

      expect(s.trioFor('Empty Book').progress, isNull);
      expect(s.hasFolder('Empty Book'), isTrue);
      expect(s.hasFolder('Never Existed'), isFalse);
    });

    test('子文件夹不会被当成同步文件', () {
      final RemoteListingBuilder b = RemoteListingBuilder();
      b.addEntry(
        parentName: 'Book A',
        name: 'progress_stuff',
        id: 'dir1',
        isFolder: true,
      );
      expect(b.build().trioFor('Book A').progress, isNull);
    });
  });

  group('归位边界', () {
    test('直接躺在同步根下的文件被丢弃，不会算到任何一本书头上', () {
      // BUG-619 的 spill 残留：根下散落着 progress_*.json。把它归给某本书，那本书
      // 就会读到一份不属于它的进度。
      final RemoteListingBuilder b = RemoteListingBuilder();
      b.addFolder('Book A');
      b.addEntry(
          parentName: '', name: 'progress_1_6_9999_0.9.json', id: 'spill');
      final RemoteListingSnapshot s = b.build();

      expect(s.trioFor('Book A').progress, isNull);
      expect(s.folders.containsKey(''), isFalse);
    });

    test('空名字既不建文件夹也不收条目', () {
      final RemoteListingBuilder b = RemoteListingBuilder();
      b.addFolder('');
      b.addEntry(parentName: 'Book A', name: '', id: 'x');
      final RemoteListingSnapshot s = b.build();
      expect(s.folderCount, 0);
    });

    test('保留命名空间与书文件夹走同一张表，按名字各取各的', () {
      final RemoteListingBuilder b = RemoteListingBuilder();
      b.addFolder('__collections__');
      b.addEntry(
          parentName: '__collections__',
          name: 'collections-devA.json',
          id: 'c');
      b.addFolder('Book A');
      b.addEntry(
          parentName: 'Book A', name: 'progress_1_6_1_0.1.json', id: 'p');

      final RemoteListingSnapshot s = b.build();
      final List<AssetEntry> ns = s.entriesOf('__collections__');
      expect(ns.single.name, 'collections-devA.json');
      expect(s.trioFor('Book A').progress?.id, 'p');
      // 命名空间不存在时给空列表，与 ensureNamespace 后立刻列举同义。
      expect(s.entriesOf('__videos__'), isEmpty);
    });

    test('只认前缀，不认位置：非三件套文件在前也不会被误挑', () {
      final RemoteListingBuilder b = RemoteListingBuilder();
      b.addEntry(parentName: 'Book A', name: 'Book A.epub', id: 'e1');
      b.addEntry(parentName: 'Book A', name: 'cover_1_6.jpg', id: 'c1');
      final SyncFileTrio trio = b.build().trioFor('Book A');
      expect(trio.progress, isNull);
      expect(trio.statistics, isNull);
      expect(trio.audioBook, isNull);
    });

    test('同一文件夹下多个同前缀文件时取第一个——与 findSyncFileByPrefix 同律', () {
      final RemoteListingBuilder b = RemoteListingBuilder();
      b.addEntry(
          parentName: 'Book A', name: 'progress_1_6_100_0.1.json', id: 'first');
      b.addEntry(
          parentName: 'Book A',
          name: 'progress_1_6_200_0.2.json',
          id: 'second');
      expect(b.build().trioFor('Book A').progress?.id, 'first');
    });
  });
}
