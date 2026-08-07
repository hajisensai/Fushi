// 媒体统一路线 P3：MediaCoverService（三岛封面统一服务）。
//
// 覆盖三条 apply 路径的真实落盘 + 「同路径覆盖写后必须双键驱逐解码缓存」不变量
// （裸 FileImage 键 + resizedFileImage 的 ResizeImage 键，BUG-959 / 视频封面
// 旧缺陷：video_import_dialog 换封面只清 FileImage 键，走降采样渲染的卡片
// 重建仍命中旧解码），以及统一选图入口的平台分流委托（BUG-1074）。

import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/media.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/media_cover_service.dart';
import 'package:fushi/src/media/video/scraper/cover_meta_store.dart';
import 'package:fushi/src/media/video/scraper/scraper_types.dart';
import 'package:fushi/src/media/video/video_book_repository.dart';
import 'package:fushi/src/media/video/video_import_dialog.dart'
    show videoCoverFileName;
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/utils/cover_image.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;
import 'package:transparent_image/transparent_image.dart';

import '../helpers/test_platform_services.dart';

/// 把 [provider] 真实解码进 ImageCache（等待首帧完成），模拟卡片渲染过一次。
Future<void> resolveIntoCache(ImageProvider provider) async {
  final Completer<void> done = Completer<void>();
  final ImageStream stream = provider.resolve(ImageConfiguration.empty);
  late final ImageStreamListener listener;
  listener = ImageStreamListener(
    (ImageInfo info, bool _) {
      info.dispose();
      if (!done.isCompleted) done.complete();
    },
    onError: (Object error, StackTrace? _) {
      if (!done.isCompleted) done.completeError(error);
    },
  );
  stream.addListener(listener);
  await done.future;
  stream.removeListener(listener);
}

/// [path] 的裸 FileImage 键是否还在 ImageCache。
Future<bool> fileImageCached(String path) async {
  final Object key =
      await FileImage(File(path)).obtainKey(ImageConfiguration.empty);
  return PaintingBinding.instance.imageCache.containsKey(key);
}

/// [path] 的降采样（ResizeImage）键是否还在 ImageCache。
Future<bool> resizedImageCached(String path) async {
  final Object key =
      await resizedFileImage(File(path)).obtainKey(ImageConfiguration.empty);
  return PaintingBinding.instance.imageCache.containsKey(key);
}

/// 把 [path] 的两个键都真实解码进缓存并断言在场（驱逐断言的前置状态）。
Future<void> populateBothCoverKeys(String path) async {
  await resolveIntoCache(FileImage(File(path)));
  await resolveIntoCache(resizedFileImage(File(path)));
  expect(await fileImageCached(path), isTrue, reason: '前置：裸 FileImage 键已入缓存');
  expect(await resizedImageCached(path), isTrue,
      reason: '前置：ResizeImage 键已入缓存');
}

/// 断言 [path] 的两个键都已被驱逐。
Future<void> expectBothCoverKeysEvicted(String path) async {
  expect(await fileImageCached(path), isFalse,
      reason: '覆盖写后裸 FileImage 键必须被驱逐');
  expect(await resizedImageCached(path), isFalse,
      reason: '覆盖写后 ResizeImage（降采样）键必须被驱逐——旧缺陷只清 FileImage 键');
}

/// 写一个真实可解码的 1x1 PNG（内容取自 transparent_image）。
File writePng(Directory dir, String name) =>
    File(p.join(dir.path, name))..writeAsBytesSync(kTransparentImage);

/// 记录调用并返回固定图片路径的假 file_picker（桌面分流委托断言用）。
class _FakeFilePicker extends FilePicker {
  _FakeFilePicker(this.resultPath);

  final String resultPath;
  FileType? lastType;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    lastType = type;
    return FilePickerResult(<PlatformFile>[
      PlatformFile(name: p.basename(resultPath), size: 0, path: resultPath),
    ]);
  }
}

void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('hibiki_cover_service');
    PaintingBinding.instance.imageCache.clear();
  });

  tearDown(() {
    PaintingBinding.instance.imageCache.clear();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('applyCoverFile / applyCoverBytes 统一落盘收口（审计 §1-A）', () {
    test('applyCoverFile：原子落盘（无 .tmp 残留）+ 覆盖写后双键驱逐', () async {
      final String dest = p.join(tempDir.path, 'cover_dest.png');
      await MediaCoverService.applyCoverFile(
        source: writePng(tempDir, 'src_a.png'),
        destPath: dest,
      );
      expect(File(dest).existsSync(), isTrue);
      expect(File('$dest.tmp').existsSync(), isFalse, reason: '不得残留 .tmp');
      await populateBothCoverKeys(dest);

      // 覆盖写同一路径 → 双键必须被驱逐（写盘→驱逐的结构保证）。
      await MediaCoverService.applyCoverFile(
        source: writePng(tempDir, 'src_b.png'),
        destPath: dest,
      );
      await expectBothCoverKeysEvicted(dest);
      expect(File('$dest.tmp').existsSync(), isFalse);
    });

    test('applyCoverBytes：原子落盘 + 覆盖写后双键驱逐', () async {
      final String dest = p.join(tempDir.path, 'cover_bytes.png');
      await MediaCoverService.applyCoverBytes(
        bytes: kTransparentImage,
        destPath: dest,
      );
      expect(File(dest).readAsBytesSync(), kTransparentImage);
      expect(File('$dest.tmp').existsSync(), isFalse);
      await populateBothCoverKeys(dest);

      await MediaCoverService.applyCoverBytes(
        bytes: kTransparentImage,
        destPath: dest,
      );
      await expectBothCoverKeysEvicted(dest);
    });

    test('applyCoverFile：源缺失时抛出、不动旧封面、不留 .tmp', () async {
      final String dest = p.join(tempDir.path, 'cover_keep.png');
      await MediaCoverService.applyCoverBytes(
        bytes: kTransparentImage,
        destPath: dest,
      );

      await expectLater(
        MediaCoverService.applyCoverFile(
          source: File(p.join(tempDir.path, 'missing.png')),
          destPath: dest,
        ),
        throwsA(anything),
      );
      expect(File(dest).readAsBytesSync(), kTransparentImage,
          reason: '写盘失败必须不动旧封面');
      expect(File('$dest.tmp').existsSync(), isFalse, reason: '失败也不得残留 .tmp');
    });
  });

  group('pickCoverImage 统一选图入口（BUG-1074 分流委托）', () {
    test('桌面（Windows）走 file_picker 图片对话框，不触碰 image_picker 通道', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      const MethodChannel imagePickerChannel =
          MethodChannel('plugins.flutter.io/image_picker');
      bool imagePickerChannelCalled = false;
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        imagePickerChannel,
        (MethodCall call) async {
          imagePickerChannelCalled = true;
          return null;
        },
      );
      addTearDown(() => binding.defaultBinaryMessenger
          .setMockMethodCallHandler(imagePickerChannel, null));

      final _FakeFilePicker fake = _FakeFilePicker('C:/tmp/cover.png');
      FilePicker.platform = fake;

      final File? picked = await MediaCoverService.pickCoverImage();

      expect(picked, isNotNull);
      expect(picked!.path, 'C:/tmp/cover.png');
      expect(fake.lastType, FileType.image);
      expect(imagePickerChannelCalled, isFalse,
          reason: '桌面分支不得触碰 image_picker MethodChannel（BUG-1074 根因）');
    });
  });

  group('applyGameCover（game_covers/<id>.<ext>）', () {
    test('落盘到注入目录并归一扩展名', () async {
      final File source = writePng(tempDir, 'source.png');
      final Directory covers = Directory(p.join(tempDir.path, 'game_covers'));

      final String? saved = await MediaCoverService.applyGameCover(
        gameId: 'game_1',
        sourcePath: source.path,
        coverDirectory: covers,
      );

      expect(saved, p.join(covers.path, 'game_1.png'));
      expect(File(saved!).existsSync(), isTrue);
    });

    test('同路径覆盖写后双键驱逐（裸 FileImage + ResizeImage）', () async {
      final Directory covers = Directory(p.join(tempDir.path, 'game_covers'));
      final File first = writePng(tempDir, 'first.png');
      final String saved = (await MediaCoverService.applyGameCover(
        gameId: 'game_2',
        sourcePath: first.path,
        coverDirectory: covers,
      ))!;
      await populateBothCoverKeys(saved);

      final File second = writePng(tempDir, 'second.png');
      final String? again = await MediaCoverService.applyGameCover(
        gameId: 'game_2',
        sourcePath: second.path,
        coverDirectory: covers,
      );

      expect(again, saved, reason: '同扩展名换图落在同一路径（覆盖写）');
      await expectBothCoverKeysEvicted(saved);
    });

    test('源文件不可读时返回 null（不驱逐、不写盘）', () async {
      final Directory covers = Directory(p.join(tempDir.path, 'game_covers'));
      final String? saved = await MediaCoverService.applyGameCover(
        gameId: 'game_3',
        sourcePath: p.join(tempDir.path, 'missing.png'),
        coverDirectory: covers,
      );
      expect(saved, isNull);
    });
  });

  group('applyVideoCoverManual（video_covers/<uid>.jpg + manual 保护）', () {
    late FushiDatabase db;
    late VideoBookRepository repo;

    setUp(() async {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      repo = VideoBookRepository(db);
      await repo.saveVideoBook(VideoBooksCompanion(
        bookUid: const Value('video/test_ep'),
        title: const Value('测试视频'),
        videoPath: const Value('/tmp/test_ep.mkv'),
        importedAt: Value(DateTime.now().millisecondsSinceEpoch),
      ));
    });

    tearDown(() async {
      await db.close();
    });

    Future<VideoBookRow> row() async => (await repo.listAll())
        .firstWhere((VideoBookRow r) => r.bookUid == 'video/test_ep');

    test('拷盘 + 落库 coverPath + 记 CoverOrigin.manual', () async {
      final Directory covers = Directory(p.join(tempDir.path, 'video_covers'));
      final File picked = writePng(tempDir, 'picked.png');

      final String dest = await MediaCoverService.applyVideoCoverManual(
        repo: repo,
        bookUid: 'video/test_ep',
        pickedPath: picked.path,
        coversDirectory: covers,
      );

      expect(dest, p.join(covers.path, videoCoverFileName('video/test_ep')));
      expect(File(dest).existsSync(), isTrue);
      expect((await row()).coverPath, dest);
      final CoverMeta? meta = await CoverMetaStore(covers).get('video/test_ep');
      expect(meta?.origin, CoverOrigin.manual,
          reason: '手动封面必须记 manual，批量刮削永不覆盖');
    });

    test('同路径覆盖写后双键驱逐（修复：旧代码只清 FileImage 键）', () async {
      final Directory covers = Directory(p.join(tempDir.path, 'video_covers'));
      final String dest = await MediaCoverService.applyVideoCoverManual(
        repo: repo,
        bookUid: 'video/test_ep',
        pickedPath: writePng(tempDir, 'a.png').path,
        coversDirectory: covers,
      );
      await populateBothCoverKeys(dest);

      final String again = await MediaCoverService.applyVideoCoverManual(
        repo: repo,
        bookUid: 'video/test_ep',
        pickedPath: writePng(tempDir, 'b.png').path,
        coversDirectory: covers,
      );

      expect(again, dest, reason: '换封面落在同一路径（与自动截帧同名）');
      await expectBothCoverKeysEvicted(dest);
    });
  });

  group('applyBookCoverOverride（thumbnails/<hashCode> override）', () {
    late Directory storeDir;
    late FushiDatabase db;
    late AppModel appModel;

    setUp(() async {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      final PreferencesRepository prefs = PreferencesRepository(db);
      await prefs.loadFromDb();
      storeDir = Directory(p.join(tempDir.path, 'store'))
        ..createSync(recursive: true);
      appModel = AppModel(testPlatformServices())
        ..wireDatabaseForTesting(db)
        ..wireLocalAudioForTesting(
          prefsRepo: prefs,
          databaseDirectory: storeDir,
        );
    });

    tearDown(() async {
      await db.close();
    });

    MediaItem srtItem(String uid) {
      final ReaderHibikiSource source = ReaderHibikiSource.instance;
      return MediaItem(
        mediaIdentifier: ReaderHibikiSource.mediaIdentifierForSrtUid(uid),
        title: '字幕书',
        mediaTypeIdentifier: source.mediaType.uniqueKey,
        mediaSourceIdentifier: source.uniqueKey,
        position: 0,
        duration: 1,
        canDelete: false,
        canEdit: true,
      );
    }

    test('写 override → 同路径换图双键驱逐 → 清除删文件并再驱逐', () async {
      final ReaderHibikiSource source = ReaderHibikiSource.instance;
      final MediaItem item = srtItem('srtbook_svc_cover');
      final String filename = source.getOverrideThumbnailFilename(
        appModel: appModel,
        item: item,
      );

      await MediaCoverService.applyBookCoverOverride(
        appModel: appModel,
        mediaSource: source,
        item: item,
        file: writePng(tempDir, 'cover_a.png'),
        clearOverrideImage: false,
      );
      expect(File(filename).existsSync(), isTrue);
      await populateBothCoverKeys(filename);

      // 换图：override 文件名由 hashCode 派生，恒为同一路径（覆盖写）。
      await MediaCoverService.applyBookCoverOverride(
        appModel: appModel,
        mediaSource: source,
        item: item,
        file: writePng(tempDir, 'cover_b.png'),
        clearOverrideImage: false,
      );
      await expectBothCoverKeysEvicted(filename);

      // 清除：文件删掉，且缓存不得残留旧解码（否则回落源封面前还闪旧图）。
      await populateBothCoverKeys(filename);
      await MediaCoverService.applyBookCoverOverride(
        appModel: appModel,
        mediaSource: source,
        item: item,
        file: null,
        clearOverrideImage: true,
      );
      expect(File(filename).existsSync(), isFalse);
      await expectBothCoverKeysEvicted(filename);
    });
  });
}
