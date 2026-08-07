import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/video/video_book_repository.dart';
import 'package:fushi/src/storage/app_paths.dart';

/// TODO-1255：视频库本地封面全占位的自愈单测。
///
/// 场景：桌面自定义数据根迁移把 `<documents>/video_covers/*` 物理搬到新根，但历史
/// 迁移漏改 `video_books.cover_path`（epub/srt 都改了），旧行的封面绝对路径指向已空
/// 的旧 Documents → [File.existsSync] 为 false → 书架全占位。迁移侧已补 rebase，但
/// **已经迁移过的旧库**里的坏路径靠迁移修不了。[VideoBookRepository.listAll] 在列出时
/// 按文件名兜底回写到当前 `video_covers` 目录里已存在的同名封面（幂等、只指向真实文件）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late Directory docs; // 模拟平台 Documents 根（当前根）
  late HibikiDatabase db;

  setUp(() {
    AppPaths.debugResetDocumentsLayoutCache();
    tmp = Directory.systemTemp.createTempSync('hibiki_cover_repair_');
    docs = Directory(p.join(tmp.path, 'documents'))
      ..createSync(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async {
        if (call.method == 'getApplicationDocumentsDirectory') {
          return docs.path;
        }
        if (call.method == 'getTemporaryDirectory') {
          return p.join(tmp.path, 'systemp');
        }
        if (call.method == 'getApplicationSupportDirectory') {
          return p.join(tmp.path, 'support');
        }
        return null;
      },
    );
    final Directory dbDir = Directory(p.join(tmp.path, 'db'))
      ..createSync(recursive: true);
    db = HibikiDatabase(dbDir.path);
  });

  tearDown(() async {
    await db.close();
    AppPaths.debugDataRootReader = null;
    AppPaths.debugResetDocumentsLayoutCache();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('listForShelf 把指向旧空位置的封面自愈回写到当前 video_covers 里的同名文件', () async {
    // 当前根下有真实封面文件（迁移把它搬到这里）。BUG-1115：目录经 AppPaths 解析而不是
    // 硬拼 `<Documents>/video_covers`——默认 documents 根已是 `<Documents>/Hibiki/data`，
    // 夹具必须与产品侧自愈查的目录同源，否则测的是一个产品里不存在的位置。
    final Directory coversDir = await AppPaths.videoCoversDirectory()
      ..createSync(recursive: true);
    final String realCover = p.join(coversDir.path, 'video_Bk.jpg');
    File(realCover).writeAsBytesSync(<int>[1, 2, 3]);

    // DB 里存的是旧根的绝对路径（迁移漏改），文件在那里已不存在。
    final String staleCover =
        p.join(tmp.path, 'old_documents', 'video_covers', 'video_Bk.jpg');
    expect(File(staleCover).existsSync(), isFalse);
    await db.upsertVideoBook(VideoBooksCompanion.insert(
      bookUid: 'video/Bk',
      title: 'Bk',
      videoPath: p.join('E:', 'anime', 'Bk.mkv'),
      coverPath: Value(staleCover),
    ));

    final VideoBookRepository repo = VideoBookRepository(db);
    final List<VideoBookRow> rows = await repo.listForShelf();

    // 返回行已指向当前根下真实文件。
    expect(rows.single.coverPath, equals(realCover));
    // DB 已被持久回写（再查一次不再是旧路径）。
    final VideoBookRow reread = (await db.allVideoBooks()).single;
    expect(reread.coverPath, equals(realCover));
  });

  test('封面文件在当前根也不存在 → 不改写，保持原值（真删除的封面留占位）', () async {
    (await AppPaths.videoCoversDirectory()).createSync(recursive: true);
    final String staleCover =
        p.join(tmp.path, 'old_documents', 'video_covers', 'gone.jpg');
    await db.upsertVideoBook(VideoBooksCompanion.insert(
      bookUid: 'video/Gone',
      title: 'Gone',
      videoPath: p.join('E:', 'anime', 'Gone.mkv'),
      coverPath: Value(staleCover),
    ));

    final List<VideoBookRow> rows =
        await VideoBookRepository(db).listForShelf();
    expect(rows.single.coverPath, equals(staleCover));
  });

  test('封面文件本就存在于存储路径 → 原样返回，不触发写', () async {
    final Directory coversDir = await AppPaths.videoCoversDirectory()
      ..createSync(recursive: true);
    final String good = p.join(coversDir.path, 'video_Ok.jpg');
    File(good).writeAsBytesSync(<int>[9]);
    await db.upsertVideoBook(VideoBooksCompanion.insert(
      bookUid: 'video/Ok',
      title: 'Ok',
      videoPath: p.join('E:', 'anime', 'Ok.mkv'),
      coverPath: Value(good),
    ));

    final List<VideoBookRow> rows =
        await VideoBookRepository(db).listForShelf();
    expect(rows.single.coverPath, equals(good));
  });

  test('cover_path 为 null → 原样返回不报错', () async {
    await db.upsertVideoBook(VideoBooksCompanion.insert(
      bookUid: 'video/NoCover',
      title: 'NoCover',
      videoPath: p.join('E:', 'anime', 'NoCover.mkv'),
    ));

    final List<VideoBookRow> rows =
        await VideoBookRepository(db).listForShelf();
    expect(rows.single.coverPath, isNull);
  });
}
