import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider/path_provider.dart';

import 'package:hibiki/src/epub/epub_importer.dart';
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart';
import 'package:hibiki/src/pages/implementations/home_video_page.dart'
    show HomeVideoPage;
import 'package:hibiki/src/media/video/video_book_repository.dart';
import 'package:hibiki/src/media/video/video_import_dialog.dart'
    show singleVideoBookUid;
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/pages/implementations/tag_filter_sheet.dart'
    show filteredVideoBookUidsProvider;
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki_core/hibiki_core.dart' show VideoBooksCompanion;

import 'generate_test_epub.dart' show EpubGenerator;
import 'media_fixtures.dart';

/// Shared self-provisioning helpers so library-dependent integration tests are
/// hermetic on a fresh install.

Future<AppModel> readyAppModel(WidgetTester tester) async {
  final ProviderContainer container = ProviderScope.containerOf(
    tester.element(find.byType(MaterialApp).first),
  );
  final AppModel appModel = container.read(appProvider);
  for (int i = 0; i < 120 && !appModel.isInitialised; i++) {
    await tester.pump(const Duration(milliseconds: 500));
  }
  expect(appModel.isInitialised, isTrue,
      reason: 'AppModel must be initialised before seeding fixtures');
  return appModel;
}

Future<String> seedReaderBook(
  WidgetTester tester, {
  String fileName = 'test_library.epub',
}) async {
  final AppModel appModel = await readyAppModel(tester);
  final ProviderContainer container = ProviderScope.containerOf(
    tester.element(find.byType(MaterialApp).first),
  );

  final Uint8List bytes = EpubGenerator().generate();
  final String bookKey = await EpubImporter.import(
    db: appModel.database,
    bytes: bytes,
    fileName: fileName,
  );
  debugPrint('[fixture] Seeded reader book key=$bookKey ($fileName)');

  container.invalidate(hibikiBooksProvider(appModel.targetLanguage));

  final Finder bookEntries = find.byWidgetPredicate((Widget w) {
    final Key? key = w.key;
    return key is ValueKey<String> &&
        (key.value.startsWith('book_entry_') ||
            key.value.startsWith('srt_entry_'));
  });
  for (int i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    if (bookEntries.evaluate().isNotEmpty) {
      debugPrint('[fixture] Book entry visible after ${i * 500}ms');
      return bookKey;
    }
  }
  debugPrint(
      '[fixture] WARNING: seeded book key=$bookKey not visible after 20s');
  return bookKey;
}

Future<bool> seedDictionary(WidgetTester tester) async {
  final AppModel appModel = await readyAppModel(tester);
  if (_hasGeneratedDictionary(appModel)) {
    debugPrint('[fixture] Generated dictionary already installed');
    return true;
  }

  final Directory cacheDir = await getTemporaryDirectory();
  final File dictFile = File('${cacheDir.path}/test_dict.zip');
  if (!dictFile.existsSync()) {
    final File? source = await _findExternalDictionaryFixture();
    if (source == null) {
      await writeGeneratedDictionary(dictFile);
      debugPrint('[fixture] Generated dictionary fixture at ${dictFile.path}');
    } else {
      source.copySync(dictFile.path);
    }
  }

  final ValueNotifier<String> progress = ValueNotifier<String>('');
  bool ok = false;
  try {
    await appModel.importDictionary(
      file: dictFile,
      progressNotifier: progress,
      onImportSuccess: () => ok = true,
    );
  } catch (e, stack) {
    debugPrint('[fixture] Dictionary import failed: $e\n$stack');
    return _hasGeneratedDictionary(appModel);
  } finally {
    progress.dispose();
  }

  final bool installed = ok || _hasGeneratedDictionary(appModel);
  debugPrint('[fixture] Dictionary seed success=$installed');
  return installed;
}

Future<File> writeGeneratedDictionary(File file) async {
  final Map<String, dynamic> index = <String, dynamic>{
    'title': 'HibikiGeneratedTestDict',
    'format': 3,
    'revision': 'generated-test-1',
    'sequenced': false,
  };
  final List<List<dynamic>> termBank = <List<dynamic>>[
    <dynamic>[
      'testword',
      'testword',
      '',
      '',
      0,
      <String>['Generated dictionary entry used by comprehensive tests.'],
      0,
      '',
    ],
    <dynamic>[
      '\u732b',
      '\u306d\u3053',
      '',
      '',
      0,
      <String>['Generated Japanese lookup entry for comprehensive tests.'],
      1,
      '',
    ],
  ];

  final Archive archive = Archive()
    ..addFile(_jsonFile('index.json', index))
    ..addFile(_jsonFile('term_bank_1.json', termBank));
  final List<int> zipBytes = ZipEncoder().encode(archive)!;
  file.parent.createSync(recursive: true);
  await file.writeAsBytes(zipBytes, flush: true);
  return file;
}

Future<File?> _findExternalDictionaryFixture() async {
  final List<File> candidates = <File>[];
  if (!Platform.isWindows && !Platform.isMacOS && !Platform.isLinux) {
    final Directory? extDir = await getExternalStorageDirectory();
    if (extDir != null) {
      candidates.add(File('${extDir.path}/test_dict.zip'));
    }
  }
  candidates.add(File('/sdcard/Download/test_dict.zip'));

  for (final File file in candidates) {
    if (file.existsSync()) return file;
  }
  return null;
}

bool _hasGeneratedDictionary(AppModel appModel) {
  return appModel.dictionaries.any((dictionary) {
    return dictionary.name == 'HibikiGeneratedTestDict' ||
        dictionary.name == 'HibikiComprehensiveTestDictionary';
  });
}

ArchiveFile _jsonFile(String name, Object json) {
  final List<int> bytes = utf8.encode(jsonEncode(json));
  return ArchiveFile(name, bytes.length, bytes);
}

/// 落盘目录：`HIBIKI_TEST_ROOT/fixtures`（隔离测试根），未设时回退系统临时目录。
///
/// 与 `video_chapter_first_load_test.dart` 同款约定，保证音视频素材落进 e2e
/// 隔离根、可被 runner 取证 / 清理。
Future<Directory> _fixturesDir() async {
  const String testRoot = String.fromEnvironment('HIBIKI_TEST_ROOT');
  final Directory dir = testRoot.isEmpty
      ? await Directory.systemTemp.createTemp('hibiki_fixtures_')
      : Directory('$testRoot${Platform.pathSeparator}fixtures');
  await dir.create(recursive: true);
  return dir;
}

/// 程序化播种一本有声书（合成 EPUB + cue + 静音音频），返回 bookKey。
///
/// 流程：[buildSampleCues] → [buildAudiobookEpubBytes] → [EpubImporter.import]
/// 拿真实 bookKey → [generateSilentAudio] 落 fixtures → [AudiobookRepository]
/// 写 [Audiobook] 元数据 + [AudiobookRepository.saveCues] cue → invalidate 书架
/// provider → 轮询书卡出现（与 [seedReaderBook] 一致：轮询失败不抛、打 warning）。
///
/// 有声书是「EPUB + 挂载的 cue/音频」，故书架以普通 `book_entry_` 形态呈现
/// （与 [seedReaderBook] 同一 [hibikiBooksProvider] 列表）。
Future<String> seedAudiobook(
  WidgetTester tester, {
  String title = 'Hibiki Test Audiobook',
}) async {
  final AppModel appModel = await readyAppModel(tester);
  final ProviderContainer container = ProviderScope.containerOf(
    tester.element(find.byType(MaterialApp).first),
  );

  // 先用占位 bookKey 造 cue/EPUB；导入后拿到真实 bookKey 再回填 cue 的 bookKey。
  final List<AudioCue> seedCues =
      buildSampleCues(bookKey: 'pending', chapterHref: kFixtureChapterHref);
  final Uint8List epubBytes =
      await buildAudiobookEpubBytes(title: title, cues: seedCues);
  final String bookKey = await EpubImporter.import(
    db: appModel.database,
    bytes: epubBytes,
    fileName: '$title.epub',
  );
  debugPrint('[fixture] Seeded audiobook epub key=$bookKey ($title)');

  final Directory dir = await _fixturesDir();
  final String audioPath = '${dir.path}${Platform.pathSeparator}$bookKey.m4a';
  final File audioFile = await generateSilentAudio(outPath: audioPath);

  // 用真实 bookKey 重建 cue（chapterHref 与 EPUB 内 spine 一致）。
  final List<AudioCue> cues =
      buildSampleCues(bookKey: bookKey, chapterHref: kFixtureChapterHref);

  final AudiobookRepository repo = AudiobookRepository(appModel.database);
  final Audiobook audiobook = Audiobook()
    ..bookKey = bookKey
    ..audioRoot = null
    ..audioPaths = <String>[audioFile.path]
    ..alignmentFormat = 'srt'
    ..alignmentPath = audioPath;
  await repo.saveAudiobook(audiobook);
  await repo.saveCues(bookKey: bookKey, cues: cues);
  debugPrint('[fixture] Saved audiobook meta + ${cues.length} cues');

  container.invalidate(hibikiBooksProvider(appModel.targetLanguage));

  final Finder bookEntries = find.byWidgetPredicate((Widget w) {
    final Key? key = w.key;
    return key is ValueKey<String> &&
        (key.value.startsWith('book_entry_') ||
            key.value.startsWith('srt_entry_'));
  });
  for (int i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    if (bookEntries.evaluate().isNotEmpty) {
      debugPrint('[fixture] Audiobook entry visible after ${i * 500}ms');
      return bookKey;
    }
  }
  debugPrint(
      '[fixture] WARNING: seeded audiobook key=$bookKey not visible after 20s');
  return bookKey;
}

/// 程序化播种一个视频（ffmpeg 造 mp4），返回 bookUid。
///
/// 流程：[generateTestVideo] 落 fixtures → [singleVideoBookUid] 算 uid →
/// [VideoBookRepository.saveVideoBook] 写元数据 → invalidate（best-effort）→
/// 轮询视频卡出现（与 [seedReaderBook] 一致：轮询失败不抛、打 warning）。
///
/// 视频库列表是 [home_video_page] 页内 `repo.listAll()` 的 FutureBuilder（非
/// Riverpod 列表 provider），仅 `filteredVideoBookUidsProvider` 受 tag 影响；故
/// 视频卡通常在 e2e 打开视频页（`initState` 重新 `listAll`）后才出现，这里轮询
/// 仅作 best-effort，未见也只 warning 返回 uid，不阻断 seed。
Future<String> seedVideo(
  WidgetTester tester, {
  String title = 'Hibiki Test Video',
}) async {
  final AppModel appModel = await readyAppModel(tester);
  final ProviderContainer container = ProviderScope.containerOf(
    tester.element(find.byType(MaterialApp).first),
  );

  final Directory dir = await _fixturesDir();
  final String videoPath = '${dir.path}${Platform.pathSeparator}$title.mp4';
  final File videoFile = await generateTestVideo(outPath: videoPath);
  final String bookUid = singleVideoBookUid(videoFile.path);
  debugPrint('[fixture] Seeded video uid=$bookUid ($title)');

  final VideoBookRepository repo = VideoBookRepository(appModel.database);
  await repo.saveVideoBook(VideoBooksCompanion(
    bookUid: Value(bookUid),
    title: Value(title),
    videoPath: Value(videoFile.absolute.path),
  ));

  // 视频页用 initState 一次性 FutureBuilder（IndexedStack 保活），seed 晚于首次
  // 查询不会自动重查 → 经测试钩子 debugRefreshVideos 强制重查让视频出现；tag 筛选
  // provider 也刷一下（无害 best-effort）。
  container.invalidate(filteredVideoBookUidsProvider);
  HomeVideoPage.debugRefreshVideos?.call();
  await tester.pump();

  final Finder videoCard = find.byKey(ValueKey<String>('home_video_$bookUid'));
  for (int i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    if (videoCard.evaluate().isNotEmpty) {
      debugPrint('[fixture] Video card visible after ${i * 500}ms');
      return bookUid;
    }
  }
  debugPrint(
      '[fixture] WARNING: seeded video uid=$bookUid not visible after 20s '
      '(expected if video page not yet open)');
  return bookUid;
}
