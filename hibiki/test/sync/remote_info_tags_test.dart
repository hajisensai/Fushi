import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/app_model_library_host_service.dart';
import 'package:fushi/src/sync/hibiki_library_host_service.dart';
import 'package:fushi/src/sync/sync_asset_package_service.dart';
import 'package:fushi_core/fushi_core.dart';

/// TODO-1165：远端书/视频清单条目按 tag name 跨设备传递标签。
/// 覆盖 DTO round-trip、缺字段向后兼容、copyWith 保留，以及 host 端
/// listBooks/listVideos 从 DB 标签映射填充 tags。
void main() {
  HibikiDatabase openDb() {
    final HibikiDatabase db =
        HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    return db;
  }

  AppModelLibraryHostService buildSvc(HibikiDatabase db) =>
      AppModelLibraryHostService(
        db: db,
        dictionaryResourceRoot: Directory.systemTemp,
        packages: SyncAssetPackageService(db: db),
        refreshDictionaryCache: () async {},
        runExclusive: (Future<void> Function() body) => body(),
      );

  group('RemoteBookInfo tags', () {
    test('toJson / fromJson round-trip 保留 tags', () {
      const RemoteBookInfo info = RemoteBookInfo(
        title: 'Book',
        hasContent: true,
        bookKey: 'book-key',
        tags: <String>['日语', 'N1'],
      );
      final RemoteBookInfo back = RemoteBookInfo.fromJson(info.toJson());
      expect(back.tags, <String>['日语', 'N1']);
      expect(back.title, 'Book');
    });

    test('无 tags 的 toJson 不写 tags 键；fromJson 缺字段降级空列表', () {
      const RemoteBookInfo info =
          RemoteBookInfo(title: 'Book', hasContent: true);
      expect(info.toJson().containsKey('tags'), isFalse);
      // 模拟旧 host（无 tags 字段）响应。
      final RemoteBookInfo legacy = RemoteBookInfo.fromJson(<String, Object?>{
        'title': 'Legacy',
        'hasContent': true,
      });
      expect(legacy.tags, isEmpty);
    });

    test('copyWith 保留并可覆盖 tags', () {
      const RemoteBookInfo info = RemoteBookInfo(
        title: 'Book',
        hasContent: true,
        tags: <String>['a'],
      );
      expect(info.copyWith(hasEmbeddedCover: true).tags, <String>['a']);
      expect(info.copyWith(tags: <String>['b', 'c']).tags, <String>['b', 'c']);
    });
  });

  group('RemoteVideoInfo tags', () {
    test('toJson / fromJson round-trip 保留 tags', () {
      const RemoteVideoInfo info = RemoteVideoInfo(
        id: 'vid-1',
        title: 'Video',
        tags: <String>['アニメ', '日常'],
      );
      final RemoteVideoInfo back = RemoteVideoInfo.fromJson(info.toJson());
      expect(back.tags, <String>['アニメ', '日常']);
      expect(back.id, 'vid-1');
    });

    test('缺 tags 字段向后兼容为空列表', () {
      final RemoteVideoInfo legacy = RemoteVideoInfo.fromJson(<String, Object?>{
        'id': 'vid-2',
        'title': 'Legacy',
      });
      expect(legacy.tags, isEmpty);
    });
  });

  group('host listBooks/listVideos 填充 tags', () {
    test('listBooks 从 book_tag_mappings 填充书标签名', () async {
      final HibikiDatabase db = openDb();
      await db.insertEpubBook(EpubBooksCompanion.insert(
        bookKey: 'BookA',
        title: 'BookA',
        epubPath: '/tmp/BookA.epub',
        extractDir: '/tmp/BookA',
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: DateTime.now().millisecondsSinceEpoch,
      ));
      final int tagId = await db.getOrCreateTagByName('文学');
      await db.addTagToBook('BookA', tagId);

      final List<RemoteBookInfo> list = await buildSvc(db).listBooks();
      final RemoteBookInfo book =
          list.firstWhere((RemoteBookInfo b) => b.title == 'BookA');
      expect(book.tags, <String>['文学']);
    });

    test('listBooks 对无标签的书返回空 tags', () async {
      final HibikiDatabase db = openDb();
      await db.insertEpubBook(EpubBooksCompanion.insert(
        bookKey: 'Bare',
        title: 'Bare',
        epubPath: '/tmp/Bare.epub',
        extractDir: '/tmp/Bare',
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: DateTime.now().millisecondsSinceEpoch,
      ));
      final List<RemoteBookInfo> list = await buildSvc(db).listBooks();
      expect(list.single.tags, isEmpty);
    });

    test('listVideos 从 video_book_tag_mappings 填充视频标签名', () async {
      final HibikiDatabase db = openDb();
      await db.upsertVideoBook(VideoBooksCompanion.insert(
        bookUid: 'vid-uid',
        title: 'MyVideo',
        videoPath: '/tmp/v.mp4',
        importedAt: Value(DateTime.now().millisecondsSinceEpoch),
      ));
      final int tagId = await db.getOrCreateTagByName('アニメ');
      await db.addTagToVideoBook('vid-uid', tagId);

      final List<RemoteVideoInfo> list = await buildSvc(db).listVideos();
      final RemoteVideoInfo video =
          list.firstWhere((RemoteVideoInfo v) => v.id == 'vid-uid');
      expect(video.tags, <String>['アニメ']);
    });
  });
}
